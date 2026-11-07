# spec — cachebench (load generator for labs/serving/direct-vs-cache, issue #75)

One Go binary, run on an EC2 client in ap-northeast-2. It drives three systems — ClickHouse Cloud
(HTTPS), ElastiCache for Valkey (TLS), DynamoDB — closed-loop, and writes one JSON line per run.
**There is no local run**: the stack exists only in AWS. Done = it builds for `linux/arm64`,
`go vet` is clean, unit tests for the pure parts pass.

## allowed

Only `labs/serving/direct-vs-cache/cachebench/` (new files). Do not touch `queries/s3_tiles.json`
or anything outside this directory. Do not write README/docs claims.

## Module

- `go.mod` module `cachebench`, `go 1.27`. Dependencies, resolved with `go get <mod>@latest` (record
  the resolved versions as they land in go.mod; do not hand-write versions):
  `github.com/redis/go-redis/v9` (Valkey speaks the Redis protocol),
  `github.com/aws/aws-sdk-go-v2/config`, `github.com/aws/aws-sdk-go-v2/service/dynamodb`.
  ClickHouse over plain `net/http` (no driver). Latency percentiles from a sorted slice of
  per-request microseconds (no histogram library).
- `queries/s3_tiles.json` embedded with `//go:embed`: array of `{id, raw, agg}` SQL strings.

## Configuration (environment)

| Var | Meaning |
|---|---|
| `CH_URL` | `https://<host>:8443` |
| `CH_USER`, `CH_PASSWORD` | basic auth |
| `CH_DB` | default `cachelab` |
| `VK_ADDR` | `host:6379`; `VK_TLS=1` → TLS (default on); `VK_PASSWORD` optional (AUTH token) |
| `AWS_REGION` | DynamoDB region (default `ap-northeast-2`); credentials from the default chain (instance role) |
| `DDB_KV_TABLE`, `DDB_ASIDE_TABLE` | table names; hash key attribute `pk` (S) in both |

## ClickHouse client

`POST $CH_URL/?database=$CH_DB&default_format=JSONCompact&log_comment=<run_id>[&extra settings]`,
query text in the body, basic auth. One `http.Client` with a `Transport` whose
`MaxIdleConnsPerHost` and `MaxConnsPerHost` = concurrency, keep-alive on, timeout 30 s.
Success = HTTP 200; on failure classify by header `X-ClickHouse-Exception-Code` (e.g. `ch_202`),
else `ch_http_<status>`, else `ch_net`. Response body bytes are the "answer" (what a cache stores).

Per-arm extra settings: `ch`, `ch-agg`, the backend of the aside arms → `use_query_cache=0`.
`ch-qc` → `use_query_cache=1&query_cache_ttl=<ttl>&query_cache_nondeterministic_function_handling=save`
(the S3 tiles call `now()`; the default `throw` would fail them).

## Subcommands

### `floor --conc N --duration D --out FILE --run-id ID`
For each system in order `ch` (`SELECT 1`), `vk` (`PING`), `ddb` (`GetItem` on `pk="floor#missing"`
in `DDB_KV_TABLE`, eventually consistent): run closed-loop for D and append one result line
(`scenario: "floor"`, `arm: ch|vk|ddb`).

### `load-kv --target vk|ddb --out FILE --run-id ID`
Stream `SELECT user_id, events, revenue, toUnixTimestamp(last_ts) FROM cachelab.user_stats FINAL FORMAT TabSeparated`
(read the body line by line, do not buffer it all).
- `vk`: `HSET user:<id> events <e> revenue <r> last_ts <t>` in pipelines of 1000, 8 pipelines in flight.
  After: `INFO memory` → `used_memory`, and `DBSIZE`.
- `ddb`: `BatchWriteItem` of 25 items `{pk: "u#<id>", events N, revenue N, last_ts N}`, 32 in flight,
  re-send `UnprocessedItems` with backoff until empty.
Result line: rows, seconds, rows/s, errors by class, and `vk_used_memory` / `vk_dbsize` for vk.

### `run --scenario s1|s2|s3 --arm ARM --conc N --duration D --warmup W --ttl T --run-id ID --out FILE`
Closed loop: N workers, each issues requests back to back for W (not recorded) then D (recorded).
Scenario-specific flags: s1 `--space K --zipf S`; s2 `--users U --dist zipf|uniform --zipf S`;
s3 `--ingest-rows R --zipf S`. Defaults: W 10s, D 60s, T 60, K 10000, S 1.1, U 1000000, R 10000.
Draws use `math/rand/v2`-style seeded generators per worker (seed = run-id hash + worker index);
Zipf over `[0, n)` with `rand.NewZipf(r, s, 1, n-1)` (needs s > 1; reject otherwise).

Arms per scenario (reject other combinations):

| Scenario | Arms |
|---|---|
| s1 | `ch`, `ch-qc`, `vk-aside`, `ddb-aside` |
| s2 | `ch`, `ch-agg`, `vk-kv`, `ddb-kv`, `vk-aside`, `ddb-aside` |
| s3 | `ch`, `ch-qc`, `ch-agg`, `vk-aside`, `ddb-aside` |

**Cache-aside** (`vk-aside`, `ddb-aside`), inline (the latency includes the set on a miss):
- `vk-aside`: `GET <key>` → hit: answer. Miss: ClickHouse → `SET <key> <body> EX <ttl>` → answer.
- `ddb-aside`: `GetItem {pk: <key>}` (eventually consistent) → hit only if the item exists **and**
  its `exp` (N, unix seconds) > now (DynamoDB TTL deletion lags, so expiry is checked on read).
  Miss: ClickHouse → `PutItem {pk: <key>, body: B(<body>), exp: now+ttl}` → answer. If the body is
  larger than 390 KiB, skip the put and count `ddb_item_too_large` (DynamoDB item limit 400 KB).
  Put errors count as `cache_put_errors`, the request still succeeds.
- The backend query of an aside arm is the `ch` query of s1/s3, and the `ch-agg` query of s2.
- No single-flight: concurrent misses of one key all go to ClickHouse (that is what S3 measures).

**s1 — ad-hoc aggregation.** At start read `base = SELECT toUnixTimestamp(min(ts)) FROM cachelab.events`.
Query index `k` ~ Zipf over `[0, K)`. Map `k` deterministically (PRNG seeded with `k` only) to:
dim ∈ `campaign_id | country | device | event_type | toStartOfHour(ts)`;
country filter: none (p=0.5) or one of the 20 codes in `../sql/20-load.sql` (copy the list);
device: none (p=0.5) or `mobile|desktop|tablet`; event_type: none (p=0.5) or one of
`impression|click|view|add_to_cart|purchase`; start = `base + h*3600`, h ∈ [0, 720);
length ∈ {1h, 24h, 7d, 30d}, end clipped to `base + 30d`. SQL:
```
SELECT <dim> AS k, count() AS c, sum(revenue) AS r, uniq(user_id) AS u
FROM cachelab.events
WHERE ts >= toDateTime(<start>) AND ts < toDateTime(<end>) [AND country = '<c>'] [AND device = '<d>'] [AND event_type = '<e>']
GROUP BY k ORDER BY c DESC LIMIT 100
```
Cache key `s1:` + first 16 hex of sha1(SQL). Also report `distinct_keys` (distinct k drawn).
Unit test: same k → same SQL; ≥ 98.5% distinct SQL for 10,000 consecutive k (measured 98.96%: clipping the end at base + 30 d merges some 7 d and 30 d windows).

**s2 — point lookup.** `id` ~ Zipf over `[0, U)` or uniform.
- `ch`: `SELECT count() AS events, sum(revenue) AS revenue, toUnixTimestamp(max(ts)) AS last_ts FROM cachelab.events WHERE user_id = <id>`
- `ch-agg`: `SELECT sum(events) AS events, sum(revenue) AS revenue, toUnixTimestamp(max(last_ts)) AS last_ts FROM cachelab.user_stats WHERE user_id = <id>`
- `vk-kv`: `HGETALL user:<id>`; `ddb-kv`: `GetItem {pk: "u#<id>"}` eventually consistent. Empty = `kv_miss` counter (not an error).
- aside key `s2:<id>`.

**s3 — hot dashboard + freshness.** Tile `i` ~ Zipf over the 12 tiles (`--zipf`, default 1.1). Arms
`ch`/`ch-qc` and the aside backends run `raw`, `ch-agg` runs `agg`. Aside key `s3:<tile id>`.
Ingest goroutine for warmup + duration: every 1 s (ticker) run, with `log_comment=<run_id>-ingest`,
```
INSERT INTO cachelab.events SELECT now() AS ts, toUInt32(rand(1) % 1000000), toUInt16(rand(2) % 1000),
 ['KR','US','JP','CN','TW','SG','VN','TH','ID','MY','PH','IN','AU','GB','DE','FR','CA','BR','MX','ES'][1 + rand(3) % 20],
 ['mobile','desktop','tablet'][1 + rand(4) % 3], ['impression','click','view','add_to_cart','purchase'][1 + rand(5) % 5],
 (rand(6) % 10000) / 100 FROM numbers(<R>)
```
count ingest batches and errors. **Staleness** per answer: parse the JSONCompact body
(`meta` names, `data` rows), take the max of column `newest` (numbers may arrive as JSON strings
— accept both), staleness = answer-receive unix time − newest, in seconds (float). Unit test the parser
on a captured-looking body for both forms.

## Result line (JSON, one per run, appended to `--out`; also printed to stdout)

`run_id, scenario, arm, conc, warmup_s, duration_s, ttl_s, space, zipf, dist, users, ingest_rows,
started_at (UTC RFC3339), ended_at, requests, ok, errors {class: count}, qps (ok/duration),
lat_ms {mean, p50, p90, p95, p99, p999, max}` (successful requests only),
`hits, misses, hit_ratio` (aside arms; kv arms report `kv_miss`),
`backend_calls` (requests that reached ClickHouse), `backend_per_s` (array, one count per second
of the recorded window), `backend_peak_per_s`, `cache_put_errors, ddb_item_too_large`,
`result_bytes {p50, max}`, `staleness_s {p50, p99, max}` (s3), `ingest {batches, errors}` (s3),
`distinct_keys` (s1), `client {go_version, gomaxprocs, hostname}`.

After the recorded window, wait 10 s and query ClickHouse (with `log_comment` of its own `<run_id>-stats`):
```
SELECT count() AS queries, round(avg(query_duration_ms),2) AS avg_ms, quantile(0.99)(query_duration_ms) AS p99_ms,
 sum(read_rows) AS read_rows, sum(read_bytes) AS read_bytes,
 countIf(query_cache_usage = 'Read') AS qc_read, countIf(query_cache_usage = 'Write') AS qc_write,
 sum(ProfileEvents['OSCPUVirtualTimeMicroseconds']) AS cpu_us, uniqExact(hostname) AS replicas
FROM clusterAllReplicas(default, system.query_log)
WHERE event_date >= today() - 1 AND log_comment = '<run_id>' AND type = 'QueryFinish'
```
and store it as `server {…}` (on failure store `server_error`). Run id: `--run-id` or
`<scenario>-<arm>-c<N>-<UTC yyyymmddThhmmssZ>`.

## verify (paste the output of each)

```
cd labs/serving/direct-vs-cache/cachebench
go vet ./...
go test ./...
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o bin/cachebench-linux-arm64 .
go run . run --help; go run . floor --help; go run . load-kv --help
go run . run --scenario s1 --arm vk-kv 2>&1 | head -2   # must reject the combination, non-zero exit
```
Add `bin/` to a `.gitignore` in this directory. Report: files, commands + output, what was not run
(everything that needs the AWS stack), gaps in this spec.
