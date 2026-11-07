package main

import (
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"slices"
	"strconv"
)

// quantile returns the p-quantile (0..1) of an ascending slice (nearest rank).
func quantile[T cmp.Ordered](sorted []T, p float64) T {
	var zero T
	if len(sorted) == 0 {
		return zero
	}
	i := int(math.Ceil(p*float64(len(sorted)))) - 1
	return sorted[min(max(i, 0), len(sorted)-1)]
}

type LatMS struct {
	Mean float64 `json:"mean"`
	P50  float64 `json:"p50"`
	P90  float64 `json:"p90"`
	P95  float64 `json:"p95"`
	P99  float64 `json:"p99"`
	P999 float64 `json:"p999"`
	Max  float64 `json:"max"`
}

// summarize turns per-request microseconds into millisecond percentiles.
func summarize(us []int64) LatMS {
	if len(us) == 0 {
		return LatMS{}
	}
	s := slices.Clone(us)
	slices.Sort(s)
	var sum float64
	for _, v := range s {
		sum += float64(v)
	}
	ms := func(v int64) float64 { return float64(v) / 1000 }
	return LatMS{
		Mean: sum / float64(len(s)) / 1000,
		P50:  ms(quantile(s, .5)), P90: ms(quantile(s, .9)), P95: ms(quantile(s, .95)),
		P99: ms(quantile(s, .99)), P999: ms(quantile(s, .999)), Max: ms(s[len(s)-1]),
	}
}

type Bytes struct {
	P50 int `json:"p50"`
	Max int `json:"max"`
}

func summarizeBytes(v []int) *Bytes {
	if len(v) == 0 {
		return nil
	}
	s := slices.Clone(v)
	slices.Sort(s)
	return &Bytes{P50: quantile(s, .5), Max: s[len(s)-1]}
}

type Stale struct {
	P50 float64 `json:"p50"`
	P99 float64 `json:"p99"`
	Max float64 `json:"max"`
}

func summarizeStale(v []float64) *Stale {
	if len(v) == 0 {
		return nil
	}
	s := slices.Clone(v)
	slices.Sort(s)
	return &Stale{P50: quantile(s, .5), P99: quantile(s, .99), Max: s[len(s)-1]}
}

// parseNewest reads a JSONCompact body and returns the max of column "newest".
// Numbers may arrive as JSON numbers or as strings (UInt64 quoting).
func parseNewest(body []byte) (float64, error) {
	var d struct {
		Meta []struct {
			Name string `json:"name"`
		} `json:"meta"`
		Data [][]any `json:"data"`
	}
	if err := json.Unmarshal(body, &d); err != nil {
		return 0, err
	}
	idx := -1
	for i, m := range d.Meta {
		if m.Name == "newest" {
			idx = i
		}
	}
	if idx < 0 {
		return 0, errors.New("no column named newest")
	}
	best, found := 0.0, false
	for _, row := range d.Data {
		if idx >= len(row) {
			continue
		}
		var f float64
		switch x := row[idx].(type) {
		case float64:
			f = x
		case string:
			v, err := strconv.ParseFloat(x, 64)
			if err != nil {
				return 0, err
			}
			f = v
		default:
			continue // null
		}
		if !found || f > best {
			best, found = f, true
		}
	}
	if !found {
		return 0, errors.New("no rows with newest")
	}
	return best, nil
}

// emit prints v as one JSON line and appends it to out (if set).
func emit(out string, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	fmt.Println(string(b))
	if out == "" {
		return nil
	}
	f, err := os.OpenFile(out, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(append(b, '\n'))
	return err
}
