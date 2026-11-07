package main

import (
	"context"
	"math"
	"math/rand/v2"
	"sync"
	"time"
)

type opFn func(ctx context.Context) ([]byte, error)

// worker holds per-goroutine state; merged after the loop (no locks on the hot path).
type worker struct {
	rng *rand.Rand
	rec bool // current request started inside the recorded window
	sec int  // second index inside the recorded window

	req, hits, misses, kvMiss, backend, putErr, tooLarge, staleParseErr int
	lat                                                                 []int64
	sizes                                                               []int
	stale                                                               []float64
	errs                                                                map[string]int
	perSec                                                              []int
	keys                                                                map[uint64]struct{}
}

func (w *worker) backendCall() {
	if w.rec {
		w.backend++
		w.perSec[w.sec]++
	}
}

type loopCfg struct {
	conc      int
	warm, dur time.Duration
	seed      uint64
	stale     bool                      // compute staleness from the answer's "newest" column
	sidecar   func(ctx context.Context) // runs for warm+dur (s3 ingest)
}

type agg struct {
	worker
	started, ended time.Time
}

func runLoop(cfg loopCfg, mk func(w *worker) opFn) *agg {
	secs := max(int(math.Ceil(cfg.dur.Seconds())), 1)
	start := time.Now()
	recStart := start.Add(cfg.warm)
	end := recStart.Add(cfg.dur)

	ctx, cancel := context.WithDeadline(context.Background(), end)
	defer cancel()
	var side sync.WaitGroup
	if cfg.sidecar != nil {
		side.Add(1)
		go func() { defer side.Done(); cfg.sidecar(ctx) }()
	}

	ws := make([]*worker, cfg.conc)
	var wg sync.WaitGroup
	for i := range ws {
		w := &worker{rng: newRNG(cfg.seed, i), errs: map[string]int{}, perSec: make([]int, secs), keys: map[uint64]struct{}{}}
		ws[i] = w
		wg.Add(1)
		go func() {
			defer wg.Done()
			op := mk(w)
			for {
				now := time.Now()
				if !now.Before(end) {
					return
				}
				w.rec = !now.Before(recStart)
				if w.rec {
					w.sec = min(int(now.Sub(recStart)/time.Second), secs-1)
				}
				octx, c := context.WithTimeout(context.Background(), 35*time.Second)
				body, err := op(octx)
				fin := time.Now()
				c()
				if err != nil {
					if w.rec {
						w.req++
						w.errs[classOf(err)]++
					}
					time.Sleep(10 * time.Millisecond)
					continue
				}
				if !w.rec {
					continue
				}
				w.req++
				w.lat = append(w.lat, fin.Sub(now).Microseconds())
				w.sizes = append(w.sizes, len(body))
				if cfg.stale {
					if n, err := parseNewest(body); err != nil {
						w.staleParseErr++
					} else {
						w.stale = append(w.stale, float64(fin.UnixNano())/1e9-n)
					}
				}
			}
		}()
	}
	wg.Wait()
	cancel()
	side.Wait()

	a := &agg{started: recStart, ended: time.Now()}
	a.errs = map[string]int{}
	a.perSec = make([]int, secs)
	a.keys = map[uint64]struct{}{}
	for _, w := range ws {
		a.req += w.req
		a.hits += w.hits
		a.misses += w.misses
		a.kvMiss += w.kvMiss
		a.backend += w.backend
		a.putErr += w.putErr
		a.tooLarge += w.tooLarge
		a.staleParseErr += w.staleParseErr
		a.lat = append(a.lat, w.lat...)
		a.sizes = append(a.sizes, w.sizes...)
		a.stale = append(a.stale, w.stale...)
		for k, v := range w.errs {
			a.errs[k] += v
		}
		for i, v := range w.perSec {
			a.perSec[i] += v
		}
		for k := range w.keys {
			a.keys[k] = struct{}{}
		}
	}
	return a
}
