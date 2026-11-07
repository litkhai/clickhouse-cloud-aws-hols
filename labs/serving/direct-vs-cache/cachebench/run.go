package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"sync/atomic"
	"time"
)

type Result struct {
	RunID            string         `json:"run_id"`
	Scenario         string         `json:"scenario"`
	Arm              string         `json:"arm"`
	Conc             int            `json:"conc"`
	WarmupS          float64        `json:"warmup_s"`
	DurationS        float64        `json:"duration_s"`
	TTLS             int            `json:"ttl_s,omitempty"`
	Space            int            `json:"space,omitempty"`
	Zipf             float64        `json:"zipf,omitempty"`
	Dist             string         `json:"dist,omitempty"`
	Users            int            `json:"users,omitempty"`
	IngestRows       int            `json:"ingest_rows,omitempty"`
	StartedAt        string         `json:"started_at"`
	EndedAt          string         `json:"ended_at"`
	Requests         int            `json:"requests"`
	OK               int            `json:"ok"`
	Errors           map[string]int `json:"errors"`
	QPS              float64        `json:"qps"`
	LatMS            LatMS          `json:"lat_ms"`
	Hits             *int           `json:"hits,omitempty"`
	Misses           *int           `json:"misses,omitempty"`
	HitRatio         *float64       `json:"hit_ratio,omitempty"`
	KVMiss           *int           `json:"kv_miss,omitempty"`
	BackendCalls     *int           `json:"backend_calls,omitempty"`
	BackendPerS      []int          `json:"backend_per_s,omitempty"`
	BackendPeak      *int           `json:"backend_peak_per_s,omitempty"`
	PutErrors        int            `json:"cache_put_errors"`
	TooLarge         int            `json:"ddb_item_too_large"`
	ResultBytes      *Bytes         `json:"result_bytes,omitempty"`
	Staleness        *Stale         `json:"staleness_s,omitempty"`
	StaleParseErrors int            `json:"staleness_parse_errors,omitempty"`
	Ingest           map[string]int `json:"ingest,omitempty"`
	DistinctKeys     *int           `json:"distinct_keys,omitempty"`
	Server           map[string]any `json:"server,omitempty"`
	ServerError      string         `json:"server_error,omitempty"`
	Client           map[string]any `json:"client"`
}

func clientInfo() map[string]any {
	h, _ := os.Hostname()
	return map[string]any{"go_version": runtime.Version(), "gomaxprocs": runtime.GOMAXPROCS(0), "hostname": h}
}

func defaultRunID(scn, arm string, conc int) string {
	return fmt.Sprintf("%s-%s-c%d-%s", scn, arm, conc, time.Now().UTC().Format("20060102T150405Z"))
}

func (a *agg) fill(r *Result, dur time.Duration) {
	r.StartedAt = a.started.UTC().Format(time.RFC3339)
	r.EndedAt = a.ended.UTC().Format(time.RFC3339)
	r.Requests = a.req
	r.OK = len(a.lat)
	r.Errors = a.errs
	r.QPS = float64(r.OK) / dur.Seconds()
	r.LatMS = summarize(a.lat)
	r.ResultBytes = summarizeBytes(a.sizes)
	r.PutErrors = a.putErr
	r.TooLarge = a.tooLarge
	r.Client = clientInfo()
}

func cmdRun(args []string) int {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	scn := fs.String("scenario", "", "s1|s2|s3")
	arm := fs.String("arm", "", "arm (s1: ch,ch-qc,vk-aside,ddb-aside; s2: ch,ch-agg,vk-kv,ddb-kv,vk-aside,ddb-aside; s3: ch,ch-qc,ch-agg,vk-aside,ddb-aside)")
	conc := fs.Int("conc", 16, "closed-loop workers")
	dur := fs.Duration("duration", 60*time.Second, "recorded window")
	warm := fs.Duration("warmup", 10*time.Second, "warmup (not recorded)")
	tmo := fs.Duration("timeout", reqTimeout, "per-request timeout (a timed-out request counts as an error)")
	ttl := fs.Int("ttl", 60, "cache TTL in seconds")
	runID := fs.String("run-id", "", "run id (default <scenario>-<arm>-c<N>-<utc time>)")
	out := fs.String("out", "", "append the result line to this file")
	space := fs.Int("space", 10000, "s1: number of distinct queries K")
	zipf := fs.Float64("zipf", 1.1, "Zipf exponent (> 1)")
	users := fs.Int("users", 1000000, "s2: number of users U")
	dist := fs.String("dist", "zipf", "s2: zipf|uniform")
	ingest := fs.Int("ingest-rows", 10000, "s3: rows per 1 s ingest batch")
	if code, done := parseFlags(fs, args); done {
		return code
	}
	if *tmo <= 0 {
		return fail("--timeout must be > 0")
	}
	reqTimeout = *tmo
	if armsByScenario[*scn] == nil {
		return fail("--scenario must be one of s1, s2, s3 (got %q)", *scn)
	}
	if !validArm(*scn, *arm) {
		return fail("arm %q is not valid for scenario %s (valid: %v)", *arm, *scn, armsByScenario[*scn])
	}
	if *zipf <= 1 {
		return fail("--zipf must be > 1 (got %v)", *zipf)
	}
	if *dist != "zipf" && *dist != "uniform" {
		return fail("--dist must be zipf or uniform")
	}
	if *conc < 1 || *space < 2 || *users < 2 || *dur <= 0 {
		return fail("--conc >= 1, --space >= 2, --users >= 2, --duration > 0 required")
	}
	if *runID == "" {
		*runID = defaultRunID(*scn, *arm, *conc)
	}

	ch, err := newCH(*conc + 2)
	if err != nil {
		return fail("%v", err)
	}
	var cache Cache
	var kv KV
	switch *arm {
	case "vk-aside", "vk-kv":
		v, err := newVK(*conc)
		if err != nil {
			return fail("%v", err)
		}
		cache, kv = v, v
	case "ddb-aside", "ddb-kv":
		d, err := newDDB()
		if err != nil {
			return fail("%v", err)
		}
		cache, kv = d, d
	}

	ctx := context.Background()
	sc := &scnCfg{scn: *scn, space: *space, users: *users, dist: *dist, zipf: *zipf}
	switch *scn {
	case "s1":
		b, err := ch.Query(ctx, "SELECT toUnixTimestamp(min(ts)) AS base FROM cachelab.events", *runID+"-base", nil)
		if err != nil {
			return fail("reading base timestamp: %v", err)
		}
		row, err := firstRow(b)
		if err != nil {
			return fail("reading base timestamp: %v", err)
		}
		sc.base, _ = strconv.ParseInt(fmt.Sprint(row["base"]), 10, 64)
		if v, ok := row["base"].(float64); ok {
			sc.base = int64(v)
		}
	case "s3":
		if sc.tiles, err = loadTiles(); err != nil {
			return fail("tiles: %v", err)
		}
	}

	ttlD := time.Duration(*ttl) * time.Second
	extra := extraFor(*arm, *ttl)
	agge := useAgg(*scn, *arm)
	aside, isKVArm := isAside(*arm), isKV(*arm)

	mk := func(w *worker) opFn {
		draw := sc.drawer(w.rng)
		backend := func(ctx context.Context, rq request) ([]byte, error) {
			w.backendCall()
			sql := rq.raw
			if agge {
				sql = rq.agg
			}
			return ch.Query(ctx, sql, *runID, extra)
		}
		return func(ctx context.Context) ([]byte, error) {
			rq := draw()
			if w.rec && *scn == "s1" {
				w.keys[rq.id] = struct{}{}
			}
			switch {
			case isKVArm:
				b, ok, err := kv.Lookup(ctx, rq.id)
				if err == nil && !ok && w.rec {
					w.kvMiss++
				}
				return b, err
			case aside:
				b, ok, err := cache.Get(ctx, rq.key)
				if err != nil {
					return nil, err
				}
				if ok {
					if w.rec {
						w.hits++
					}
					return b, nil
				}
				if w.rec {
					w.misses++
				}
				b, err = backend(ctx, rq)
				if err != nil {
					return nil, err
				}
				if perr := cache.Put(ctx, rq.key, b, ttlD); perr != nil && w.rec {
					if perr == errTooLarge {
						w.tooLarge++
					} else {
						w.putErr++
					}
				}
				return b, nil
			default:
				return backend(ctx, rq)
			}
		}
	}

	cfg := loopCfg{conc: *conc, warm: *warm, dur: *dur, seed: seedFor(*runID), stale: *scn == "s3"}
	var batches, ingErrs atomic.Int64
	if *scn == "s3" {
		cfg.sidecar = func(ctx context.Context) {
			tk := time.NewTicker(time.Second)
			defer tk.Stop()
			sql := ingestSQL(*ingest)
			for {
				select {
				case <-ctx.Done():
					return
				case <-tk.C:
					ictx, c := context.WithTimeout(ctx, 30*time.Second)
					_, err := ch.Query(ictx, sql, *runID+"-ingest", nil)
					c()
					if err != nil && ctx.Err() == nil {
						ingErrs.Add(1)
					} else if err == nil {
						batches.Add(1)
					}
				}
			}
		}
	}

	fmt.Fprintf(os.Stderr, "run %s: warmup %s, recording %s, conc %d\n", *runID, *warm, *dur, *conc)
	a := runLoop(cfg, mk)

	r := &Result{RunID: *runID, Scenario: *scn, Arm: *arm, Conc: *conc,
		WarmupS: warm.Seconds(), DurationS: dur.Seconds(), TTLS: *ttl}
	switch *scn {
	case "s1":
		r.Space, r.Zipf = *space, *zipf
		n := len(a.keys)
		r.DistinctKeys = &n
	case "s2":
		r.Users, r.Dist = *users, *dist
		if *dist == "zipf" {
			r.Zipf = *zipf
		}
	case "s3":
		r.Zipf, r.IngestRows = *zipf, *ingest
		r.Ingest = map[string]int{"batches": int(batches.Load()), "errors": int(ingErrs.Load())}
		r.Staleness = summarizeStale(a.stale)
		r.StaleParseErrors = a.staleParseErr
	}
	a.fill(r, *dur)
	if aside {
		h, m := a.hits, a.misses
		r.Hits, r.Misses = &h, &m
		if h+m > 0 {
			hr := float64(h) / float64(h+m)
			r.HitRatio = &hr
		}
	}
	if isKVArm {
		km := a.kvMiss
		r.KVMiss = &km
	} else {
		bc := a.backend
		r.BackendCalls = &bc
		r.BackendPerS = a.perSec
		pk := 0
		for _, v := range a.perSec {
			pk = max(pk, v)
		}
		r.BackendPeak = &pk
	}

	time.Sleep(10 * time.Second)
	for attempt := 1; attempt <= 3; attempt++ {
		r.Server, r.ServerError = serverStats(ctx, ch, *runID)
		if r.ServerError == "" {
			break
		}
		time.Sleep(5 * time.Second)
	}

	if err := emit(*out, r); err != nil {
		return fail("writing result: %v", err)
	}
	return 0
}

func serverStats(ctx context.Context, ch *CH, runID string) (map[string]any, string) {
	sql := fmt.Sprintf(`SELECT count() AS queries, round(avg(query_duration_ms),2) AS avg_ms, quantile(0.99)(query_duration_ms) AS p99_ms,
 sum(read_rows) AS read_rows, sum(read_bytes) AS read_bytes,
 countIf(query_cache_usage = 'Read') AS qc_read, countIf(query_cache_usage = 'Write') AS qc_write,
 sum(ProfileEvents['OSCPUVirtualTimeMicroseconds']) AS cpu_us, uniqExact(hostname) AS replicas
FROM clusterAllReplicas(default, system.query_log)
WHERE event_date >= today() - 1 AND log_comment = '%s' AND type = 'QueryFinish'
 SETTINGS max_execution_time = 30, skip_unavailable_shards = 1`, runID)
	b, err := ch.Query(ctx, sql, runID+"-stats", nil)
	if err != nil {
		return nil, err.Error()
	}
	m, err := firstRow(b)
	if err != nil {
		return nil, err.Error()
	}
	return m, ""
}

// ---- floor ----

type FloorResult struct {
	RunID     string         `json:"run_id"`
	Scenario  string         `json:"scenario"`
	Arm       string         `json:"arm"`
	Conc      int            `json:"conc"`
	DurationS float64        `json:"duration_s"`
	StartedAt string         `json:"started_at"`
	EndedAt   string         `json:"ended_at"`
	Requests  int            `json:"requests"`
	OK        int            `json:"ok"`
	Errors    map[string]int `json:"errors"`
	QPS       float64        `json:"qps"`
	LatMS     LatMS          `json:"lat_ms"`
	Client    map[string]any `json:"client"`
}

func cmdFloor(args []string) int {
	fs := flag.NewFlagSet("floor", flag.ContinueOnError)
	conc := fs.Int("conc", 16, "closed-loop workers")
	dur := fs.Duration("duration", 10*time.Second, "duration per system")
	out := fs.String("out", "", "append result lines to this file")
	runID := fs.String("run-id", "", "run id (default floor-c<N>-<utc time>)")
	if code, done := parseFlags(fs, args); done {
		return code
	}
	if *conc < 1 || *dur <= 0 {
		return fail("--conc >= 1 and --duration > 0 required")
	}
	if *runID == "" {
		*runID = defaultRunID("floor", "all", *conc)
	}
	ch, err := newCH(*conc)
	if err != nil {
		return fail("%v", err)
	}
	v, err := newVK(*conc)
	if err != nil {
		return fail("%v", err)
	}
	d, err := newDDB()
	if err != nil {
		return fail("%v", err)
	}
	ops := []struct {
		arm string
		op  opFn
	}{
		{"ch", func(ctx context.Context) ([]byte, error) { return ch.Query(ctx, "SELECT 1", *runID, nil) }},
		{"vk", func(ctx context.Context) ([]byte, error) {
			if err := v.c.Ping(ctx).Err(); err != nil {
				return nil, v.wrap(err)
			}
			return nil, nil
		}},
		{"ddb", func(ctx context.Context) ([]byte, error) {
			_, err := d.getItem(ctx, d.kvT, "floor#missing")
			return nil, err
		}},
	}
	for _, o := range ops {
		a := runLoop(loopCfg{conc: *conc, dur: *dur, seed: seedFor(*runID)}, func(*worker) opFn { return o.op })
		r := FloorResult{RunID: *runID, Scenario: "floor", Arm: o.arm, Conc: *conc, DurationS: dur.Seconds(),
			StartedAt: a.started.UTC().Format(time.RFC3339), EndedAt: a.ended.UTC().Format(time.RFC3339),
			Requests: a.req, OK: len(a.lat), Errors: a.errs, QPS: float64(len(a.lat)) / dur.Seconds(),
			LatMS: summarize(a.lat), Client: clientInfo()}
		if err := emit(*out, r); err != nil {
			return fail("writing result: %v", err)
		}
	}
	return 0
}
