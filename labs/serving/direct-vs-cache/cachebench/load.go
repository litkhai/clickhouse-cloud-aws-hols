package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

const loadSQL = "SELECT user_id, events, revenue, toUnixTimestamp(last_ts) FROM cachelab.user_stats FINAL FORMAT TabSeparated"

type LoadResult struct {
	RunID     string         `json:"run_id"`
	Scenario  string         `json:"scenario"`
	Arm       string         `json:"arm"`
	Rows      int            `json:"rows"`
	Seconds   float64        `json:"seconds"`
	RowsPerS  float64        `json:"rows_per_s"`
	Errors    map[string]int `json:"errors"`
	VKMemory  *int64         `json:"vk_used_memory,omitempty"`
	VKDBSize  *int64         `json:"vk_dbsize,omitempty"`
	StartedAt string         `json:"started_at"`
	Client    map[string]any `json:"client"`
}

type errCount struct {
	mu sync.Mutex
	m  map[string]int
}

func (e *errCount) add(class string, n int) {
	e.mu.Lock()
	e.m[class] += n
	e.mu.Unlock()
}

// row is one TSV line: user_id, events, revenue, last_ts.
type row [4]string

func cmdLoadKV(args []string) int {
	fs := flag.NewFlagSet("load-kv", flag.ContinueOnError)
	target := fs.String("target", "", "vk|ddb")
	out := fs.String("out", "", "append the result line to this file")
	runID := fs.String("run-id", "", "run id")
	if code, done := parseFlags(fs, args); done {
		return code
	}
	if *target != "vk" && *target != "ddb" {
		return fail("--target must be vk or ddb (got %q)", *target)
	}
	if *runID == "" {
		*runID = defaultRunID("load-kv", *target, 0)
	}
	ch, err := newCH(2)
	if err != nil {
		return fail("%v", err)
	}
	ctx := context.Background()
	var write func(batch []row) error
	var inflight, batchSize int
	var v *vk
	errs := &errCount{m: map[string]int{}}
	if *target == "vk" {
		if v, err = newVK(8); err != nil {
			return fail("%v", err)
		}
		inflight, batchSize = 8, 1000
		write = func(b []row) error {
			p := v.c.Pipeline()
			for _, r := range b {
				p.HSet(ctx, "user:"+r[0], "events", r[1], "revenue", r[2], "last_ts", r[3])
			}
			_, err := p.Exec(ctx)
			return err
		}
	} else {
		d, err := newDDB()
		if err != nil {
			return fail("%v", err)
		}
		inflight, batchSize = 32, 25
		write = func(b []row) error { return d.batchWrite(ctx, b) }
	}

	body, err := ch.Stream(ctx, loadSQL, *runID+"-load")
	if err != nil {
		return fail("reading user_stats: %v", err)
	}
	defer body.Close()

	start := time.Now()
	sem := make(chan struct{}, inflight)
	var wg sync.WaitGroup
	flush := func(b []row) {
		sem <- struct{}{}
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			if err := write(b); err != nil {
				errs.add(errClass(*target), len(b))
			}
		}()
	}
	rd := bufio.NewReaderSize(body, 1<<20)
	rows := 0
	batch := make([]row, 0, batchSize)
	for {
		line, err := rd.ReadString('\n')
		if line = strings.TrimRight(line, "\n"); line != "" {
			f := strings.Split(line, "\t")
			if len(f) == 4 {
				batch = append(batch, row{f[0], f[1], f[2], f[3]})
				rows++
				if len(batch) == batchSize {
					flush(batch)
					batch = make([]row, 0, batchSize)
				}
			}
		}
		if err != nil {
			if err != io.EOF {
				errs.add("ch_stream", 1)
			}
			break
		}
	}
	if len(batch) > 0 {
		flush(batch)
	}
	wg.Wait()
	secs := time.Since(start).Seconds()

	r := LoadResult{RunID: *runID, Scenario: "load-kv", Arm: *target, Rows: rows, Seconds: secs,
		RowsPerS: float64(rows) / secs, Errors: errs.m, StartedAt: start.UTC().Format(time.RFC3339), Client: clientInfo()}
	if v != nil {
		if info, err := v.c.Info(ctx, "memory").Result(); err == nil {
			for _, l := range strings.Split(info, "\n") {
				if s, ok := strings.CutPrefix(strings.TrimSpace(l), "used_memory:"); ok {
					n, _ := strconv.ParseInt(s, 10, 64)
					r.VKMemory = &n
				}
			}
		} else {
			errs.add("vk_info", 1)
		}
		if n, err := v.c.DBSize(ctx).Result(); err == nil {
			r.VKDBSize = &n
		} else {
			errs.add("vk_dbsize", 1)
		}
	}
	if err := emit(*out, r); err != nil {
		return fail("writing result: %v", err)
	}
	return 0
}

func errClass(target string) string {
	if target == "vk" {
		return "vk_err"
	}
	return "ddb_err"
}

// batchWrite sends up to 25 items and re-sends UnprocessedItems with backoff until empty.
func (d *ddb) batchWrite(ctx context.Context, b []row) error {
	reqs := make([]types.WriteRequest, 0, len(b))
	for _, r := range b {
		reqs = append(reqs, types.WriteRequest{PutRequest: &types.PutRequest{Item: map[string]types.AttributeValue{
			"pk":      &types.AttributeValueMemberS{Value: "u#" + r[0]},
			"events":  &types.AttributeValueMemberN{Value: r[1]},
			"revenue": &types.AttributeValueMemberN{Value: r[2]},
			"last_ts": &types.AttributeValueMemberN{Value: r[3]},
		}}})
	}
	pending := map[string][]types.WriteRequest{d.kvT: reqs}
	backoff := 50 * time.Millisecond
	for attempt := 0; len(pending) > 0; attempt++ {
		if attempt >= 15 {
			return fmt.Errorf("unprocessed items remain after %d attempts", attempt)
		}
		if attempt > 0 {
			time.Sleep(backoff)
			backoff = min(backoff*2, 5*time.Second)
		}
		out, err := d.c.BatchWriteItem(ctx, &dynamodb.BatchWriteItemInput{RequestItems: pending})
		if err != nil {
			return err
		}
		pending = out.UnprocessedItems
	}
	return nil
}
