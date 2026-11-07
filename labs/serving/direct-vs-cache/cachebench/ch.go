package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// classErr carries an error class (the key in the result's errors map).
type classErr struct {
	class string
	err   error
}

func (e *classErr) Error() string { return e.class + ": " + e.err.Error() }
func (e *classErr) Unwrap() error { return e.err }

func classOf(err error) string {
	var ce *classErr
	if errors.As(err, &ce) {
		return ce.class
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	return "other"
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// needEnv returns an error naming every unset variable.
func needEnv(names ...string) error {
	var missing []string
	for _, n := range names {
		if os.Getenv(n) == "" {
			missing = append(missing, n)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing environment variables: %s", strings.Join(missing, ", "))
	}
	return nil
}

type CH struct {
	url, user, pass, db string
	hc, stream          *http.Client // stream has no overall timeout (bulk reads)
}

func newCH(conc int) (*CH, error) {
	if err := needEnv("CH_URL", "CH_USER", "CH_PASSWORD"); err != nil {
		return nil, err
	}
	tr := &http.Transport{
		MaxIdleConnsPerHost: conc, MaxConnsPerHost: conc,
		IdleConnTimeout: 90 * time.Second, ForceAttemptHTTP2: false,
	}
	return &CH{
		url: strings.TrimRight(os.Getenv("CH_URL"), "/"), user: os.Getenv("CH_USER"),
		pass: os.Getenv("CH_PASSWORD"), db: getenv("CH_DB", "cachelab"),
		hc:     &http.Client{Transport: tr, Timeout: 30 * time.Second},
		stream: &http.Client{Transport: tr},
	}, nil
}

func (c *CH) do(ctx context.Context, hc *http.Client, sql, comment string, extra url.Values) (*http.Response, error) {
	q := url.Values{}
	q.Set("database", c.db)
	q.Set("default_format", "JSONCompact")
	q.Set("log_comment", comment)
	for k, v := range extra {
		q[k] = v
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url+"/?"+q.Encode(), strings.NewReader(sql))
	if err != nil {
		return nil, err
	}
	req.SetBasicAuth(c.user, c.pass)
	resp, err := hc.Do(req)
	if err != nil {
		return nil, &classErr{"ch_net", err}
	}
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 300))
		resp.Body.Close()
		class := fmt.Sprintf("ch_http_%d", resp.StatusCode)
		if code := resp.Header.Get("X-ClickHouse-Exception-Code"); code != "" {
			class = "ch_" + code
		}
		return nil, &classErr{class, errors.New(strings.TrimSpace(string(msg)))}
	}
	return resp, nil
}

// Query runs sql and returns the whole response body.
func (c *CH) Query(ctx context.Context, sql, comment string, extra url.Values) ([]byte, error) {
	resp, err := c.do(ctx, c.hc, sql, comment, extra)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, &classErr{"ch_net", err}
	}
	return b, nil
}

// Stream runs sql and returns the open body; the caller closes it.
func (c *CH) Stream(ctx context.Context, sql, comment string) (io.ReadCloser, error) {
	resp, err := c.do(ctx, c.stream, sql, comment, nil)
	if err != nil {
		return nil, err
	}
	return resp.Body, nil
}

// firstRow decodes a JSONCompact body and returns its first row as name -> value.
func firstRow(body []byte) (map[string]any, error) {
	var d struct {
		Meta []struct {
			Name string `json:"name"`
		} `json:"meta"`
		Data [][]any `json:"data"`
	}
	if err := json.NewDecoder(bytes.NewReader(body)).Decode(&d); err != nil {
		return nil, err
	}
	if len(d.Data) == 0 {
		return nil, errors.New("no rows")
	}
	m := map[string]any{}
	for i, c := range d.Meta {
		m[c.Name] = d.Data[0][i]
	}
	return m, nil
}

func extraFor(arm string, ttl int) url.Values {
	v := url.Values{}
	if arm == "ch-qc" {
		v.Set("use_query_cache", "1")
		v.Set("query_cache_ttl", fmt.Sprint(ttl))
		v.Set("query_cache_nondeterministic_function_handling", "save")
	} else {
		v.Set("use_query_cache", "0")
	}
	return v
}
