# ClickHouse Cloud on every request, or a cache in front? — Valkey (ElastiCache) and DynamoDB

> **Not run yet.** Written 2026-11-07 for [#75](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/75).
> Checked so far: `terraform validate` (AWS provider 5.100.0), `bash -n` on every script, `go vet` / `go test` /
> `go build` of `cachebench`. Nothing here has run against AWS or ClickHouse Cloud; every expectation below is a
> hypothesis until `RESULTS.md` exists.
>
> **아직 실행 안 함.** 2026-11-07 [#75](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/75)용으로 작성.
> 지금까지 확인한 것: `terraform validate`(AWS provider 5.100.0), 모든 스크립트 `bash -n`, `cachebench`의
> `go vet` / `go test` / `go build`. AWS나 ClickHouse Cloud에서 실행한 것은 없고, 아래 예상은 `RESULTS.md`가
> 생기기 전까지 가설입니다.

[English](#english) | [한국어](#한국어)

## English

A common question from teams serving analytics to many users: *should every request run its
aggregation on ClickHouse Cloud, or should results be cached in Redis-compatible storage?* The
honest answer depends on the shape of the requests, so this lab measures three shapes side by side
with the client, the caches and the ClickHouse Cloud service all in one region.

```
            ap-northeast-2 (one AZ for the client and Valkey)
 ┌──────────────────────────────────────────────────────────────────────┐
 │  EC2 c7g.2xlarge ── cachebench (Go, closed loop, N workers)          │
 │     │ TLS 6379            │ HTTPS (gateway endpoint)   │ HTTPS 8443  │
 │     ▼                     ▼                            ▼             │
 │  ElastiCache for Valkey   DynamoDB on-demand        ClickHouse Cloud │
 │  1 × cache.r7g.large      kv + aside tables         (existing service)│
 └──────────────────────────────────────────────────────────────────────┘
```

### What is compared

| Arm | Read path |
|---|---|
| `ch` | every request → ClickHouse over HTTPS, `use_query_cache=0` |
| `ch-qc` | ClickHouse's own query cache, `use_query_cache=1`, same TTL as the external caches |
| `ch-agg` | ClickHouse on tables pre-aggregated by materialized views (`user_stats`, `events_1m`) |
| `vk-aside` | Valkey cache-aside: `GET` → miss → ClickHouse → `SET EX ttl` |
| `ddb-aside` | DynamoDB cache-aside: `GetItem` → expired? (checked on read) → miss → ClickHouse → `PutItem` |
| `vk-kv`, `ddb-kv` | Valkey / DynamoDB as the serving store, loaded from ClickHouse; ClickHouse not on the read path |

### Scenarios

| | Requests | Arms | Knobs | Main readings |
|---|---|---|---|---|
| Floor | `SELECT 1`, `PING`, `GetItem` on a missing key | ch, vk, ddb | conc 1, 16 | the latency no design goes below |
| S1 ad-hoc | group by one of 5 dimensions, up to 3 filters, a time range (1 h – 30 d) over 100M rows | ch, ch-qc, vk-aside, ddb-aside | query space 100 / 10k / 1M (Zipf 1.1), conc 8 / 32 / 128 | hit ratio, p50/p99, QPS, queries still reaching ClickHouse |
| S2 point | one user's totals out of 1M users (Zipf) | ch (projection), ch-agg, vk-kv, ddb-kv, vk-aside, ddb-aside | conc 8 / 32 / 128 / 512 | p99, p99.9, the concurrency where errors start |
| S3 dashboard | 12 fixed tiles (`queries/s3_tiles.json`) while 10k rows/s are inserted | ch, ch-qc, ch-agg, vk-aside, ddb-aside | TTL 5 / 60 s, conc 32 / 128 | load on ClickHouse, staleness (now − newest row in the answer), request peak per second at TTL expiry |

Every ClickHouse request carries the run id as `log_comment`; after each run `cachebench` reads
`system.query_log` across all replicas (count, avg/p99 duration, rows and bytes read, query-cache
reads and writes, CPU). Result lines: `results/<stamp>/*.jsonl`, tables: `40-report.py`.

### Hypotheses (to be checked by the run)

- S1: a cache only helps as far as the same query repeats. With a large query space the hit ratio
  stays low and the aside arms cost an extra round trip per miss, plus cache memory.
- S2: Valkey's and DynamoDB's single-key reads are below ClickHouse's per-query floor; ClickHouse
  on a pre-aggregated table narrows the gap and needs no second system.
- S3: the query cache and the external caches cut load on ClickHouse by about the hit ratio and add
  staleness up to the TTL; without single-flight, every expiry sends a burst of identical queries.

### Fairness notes

- One region; client and Valkey in one AZ. ClickHouse Cloud through its public endpoint (no
  PrivateLink), DynamoDB through a gateway endpoint. TLS on all three.
- Cache-aside writes inline: a miss's latency includes the `SET` / `PutItem`.
- DynamoDB's TTL deletes expired items in the background with a delay (AWS: typically within a
  few days), so `ddb-aside` treats an item whose `exp` has passed as a miss.
- DynamoDB items are limited to 400 KB; S1 answers carry `LIMIT 100`, and a larger body is not
  cached (`ddb_item_too_large`).
- The ClickHouse query cache lives in each replica; with several replicas behind the endpoint the
  hit ratio of `ch-qc` is per replica (`server.replicas`, `qc_read` show it).
- `ch-qc` sets `query_cache_nondeterministic_function_handling=save`: the S3 tiles call `now()`,
  which the default (`throw`) refuses to cache.
- Results depend on the service size (memory per replica, replicas): the run records it.

### Run

Needs: AWS credentials for ap-northeast-2, Terraform ≥ 1.5, the AWS CLI with the Session Manager
permission to `send-command`, `clickhouse` (client), Go ≥ 1.27, a ClickHouse Cloud service in
the same region.

```bash
cp terraform.tfvars.example terraform.tfvars   # owner, ttl
cat > ch.env <<'EOF'                           # gitignored; or CH_ENV_FILE=<your file>
CH_HOST=<service>.ap-northeast-2.aws.clickhouse.cloud
CH_USER=default
CH_PASSWORD=<password>
EOF
chmod 600 ch.env
./deploy.sh            # preflight, terraform apply, config.env
#   → add the printed client IP to the service's IP access list
./10-ch-setup.sh       # schema + 100M rows (ROWS=…, CHUNK=… to change)
./20-push.sh           # build, send, floor check from the client
./30-run.sh all        # whole matrix in the background (≈ 1 h 40 min); or one phase: floor|s1|kv|s2|s3
./31-fetch.sh <stamp>  # copy results; repeat until matrix.log says "done all"
python3 40-report.py results/<stamp> > results/<stamp>/REPORT.md
```

**Before cleanup, take the captures** the write-up needs: the Cloud console's service monitoring
and query insights during S1/S3, a SQL console `system.query_log` query by `log_comment`, and the
CloudWatch metrics of the Valkey node and both DynamoDB tables. Then:

```bash
./destroy.sh           # AWS side, bucket included
./90-ch-cleanup.sh     # DROP DATABASE cachelab on the service
```

Remove the client IP from the service's IP access list.

### Not measured

DAX, ElastiCache Serverless, Valkey cluster mode and replicas, PrivateLink to ClickHouse Cloud,
single-flight or lock-based refresh, write-time counters in Valkey (`INCR` / `ZINCRBY`) instead of
aggregation, client-side caches, the cost of the AWS resources.

### Files

| File | Role |
|---|---|
| `main.tf`, `variables.tf`, `outputs.tf` | EC2 client (SSM only, no inbound), Valkey, DynamoDB `kv` / `aside`, gateway endpoint, bucket, IAM |
| `deploy.sh`, `destroy.sh` | preflight + apply → `config.env`; destroy |
| `sql/10-schema.sql`, `sql/20-load.sql` | tables, projection, MVs; deterministic 30-day load |
| `10-ch-setup.sh`, `90-ch-cleanup.sh` | create and load / drop on the service |
| `cachebench/` | the load generator (`spec.md` is its design) |
| `20-push.sh`, `matrix.sh`, `30-run.sh`, `31-fetch.sh` | send, run matrix on the client, fetch |
| `40-report.py` | result lines → markdown tables |

---

## 한국어

많은 사용자에게 분석 결과를 서비스하는 팀이 자주 묻는 질문입니다. *요청마다 ClickHouse Cloud에서
집계할까, 아니면 Redis 호환 저장소에 결과를 캐시할까?* 답은 요청의 모양에 달려 있어서, 이 실습은 세
가지 모양을 클라이언트·캐시·ClickHouse Cloud 서비스를 한 리전에 둔 채 나란히 측정합니다.

구성도는 위 English 절과 같습니다(ap-northeast-2, 클라이언트와 Valkey는 같은 AZ).

### 비교 대상

| 경로 | 읽기 경로 |
|---|---|
| `ch` | 요청마다 HTTPS로 ClickHouse, `use_query_cache=0` |
| `ch-qc` | ClickHouse 자체 쿼리 캐시, `use_query_cache=1`, 외부 캐시와 같은 TTL |
| `ch-agg` | MV로 미리 집계한 테이블(`user_stats`, `events_1m`)을 ClickHouse에서 조회 |
| `vk-aside` | Valkey cache-aside: `GET` → 미스 → ClickHouse → `SET EX ttl` |
| `ddb-aside` | DynamoDB cache-aside: `GetItem` → 만료 여부(읽을 때 확인) → 미스 → ClickHouse → `PutItem` |
| `vk-kv`, `ddb-kv` | ClickHouse에서 적재한 Valkey / DynamoDB를 서빙 저장소로 사용, 읽기 경로에 ClickHouse 없음 |

### 시나리오

| | 요청 | 경로 | 변수 | 주요 측정값 |
|---|---|---|---|---|
| 바닥 | `SELECT 1`, `PING`, 없는 키 `GetItem` | ch, vk, ddb | 동시성 1, 16 | 어떤 설계도 내려갈 수 없는 지연 |
| S1 애드혹 | 차원 5개 중 하나로 GROUP BY, 필터 최대 3개, 1시간–30일 범위, 1억 행 | ch, ch-qc, vk-aside, ddb-aside | 쿼리 공간 100 / 1만 / 100만(Zipf 1.1), 동시성 8 / 32 / 128 | 적중률, p50/p99, QPS, 여전히 ClickHouse에 도달하는 쿼리 |
| S2 포인트 | 사용자 100만 명 중 한 명의 합계(Zipf) | ch(프로젝션), ch-agg, vk-kv, ddb-kv, vk-aside, ddb-aside | 동시성 8 / 32 / 128 / 512 | p99, p99.9, 오류가 시작되는 동시성 |
| S3 대시보드 | 초당 1만 행을 넣는 동안 고정 타일 12개(`queries/s3_tiles.json`) | ch, ch-qc, ch-agg, vk-aside, ddb-aside | TTL 5 / 60초, 동시성 32 / 128 | ClickHouse 부하, 신선도(지금 − 응답 속 최신 행), TTL 만료 시 초당 요청 최고치 |

ClickHouse 요청마다 실행 ID를 `log_comment`로 붙이고, 실행이 끝나면 `cachebench`가 모든 레플리카의
`system.query_log`를 읽습니다(건수, 평균/p99 시간, 읽은 행·바이트, 쿼리 캐시 읽기·쓰기, CPU).
결과 줄은 `results/<stamp>/*.jsonl`, 표는 `40-report.py`.

### 가설 (실행으로 확인할 것)

- S1: 캐시는 같은 쿼리가 반복되는 만큼만 도움이 됩니다. 쿼리 공간이 크면 적중률이 낮고, aside 경로는
  미스마다 왕복이 하나 늘며 캐시 메모리도 듭니다.
- S2: Valkey·DynamoDB의 단일 키 읽기는 ClickHouse 쿼리 한 번의 바닥보다 낮습니다. 미리 집계한 테이블을
  쓰는 ClickHouse는 그 차이를 줄이고 두 번째 시스템이 필요 없습니다.
- S3: 쿼리 캐시와 외부 캐시는 적중률만큼 ClickHouse 부하를 줄이고 TTL만큼 신선도를 잃습니다.
  single-flight가 없으면 만료 때마다 같은 쿼리가 몰립니다.

### 공정성 메모

- 한 리전, 클라이언트와 Valkey는 같은 AZ. ClickHouse Cloud는 공개 엔드포인트(PrivateLink 없음),
  DynamoDB는 게이트웨이 엔드포인트. 셋 다 TLS.
- cache-aside는 바로 씁니다. 미스의 지연에 `SET` / `PutItem`이 포함됩니다.
- DynamoDB TTL은 만료된 항목을 백그라운드에서 늦게 지웁니다(AWS: 보통 며칠 안). 그래서 `ddb-aside`는
  `exp`가 지난 항목을 미스로 봅니다.
- DynamoDB 항목은 400 KB 제한이 있습니다. S1 응답은 `LIMIT 100`이고, 더 큰 본문은 캐시하지 않습니다
  (`ddb_item_too_large`).
- ClickHouse 쿼리 캐시는 레플리카마다 따로 있습니다. 엔드포인트 뒤에 레플리카가 여럿이면 `ch-qc`의
  적중률은 레플리카별입니다(`server.replicas`, `qc_read`로 확인).
- `ch-qc`는 `query_cache_nondeterministic_function_handling=save`를 씁니다. S3 타일이 `now()`를 부르는데
  기본값(`throw`)은 이를 캐시하지 않고 오류를 냅니다.
- 결과는 서비스 크기(레플리카당 메모리, 레플리카 수)에 달려 있고, 실행이 이를 기록합니다.

### 실행

필요한 것: ap-northeast-2용 AWS 자격 증명, Terraform 1.5 이상, Session Manager `send-command` 권한이 있는
AWS CLI, `clickhouse`(클라이언트), Go 1.27 이상, 같은 리전의 ClickHouse Cloud 서비스.
명령은 English 절의 블록과 같습니다: `deploy.sh` → 클라이언트 IP를 서비스 IP 접근 목록에 추가 →
`10-ch-setup.sh` → `20-push.sh` → `30-run.sh all`(약 1시간 40분, 백그라운드) → `31-fetch.sh <stamp>` →
`40-report.py`.

**정리 전에 캡처합니다**: S1/S3 동안 Cloud 콘솔의 서비스 모니터링과 query insights, `log_comment`로
거른 SQL 콘솔의 `system.query_log`, Valkey 노드와 DynamoDB 테이블 두 개의 CloudWatch 지표. 그다음
`./destroy.sh`(AWS 쪽, 버킷 포함), `./90-ch-cleanup.sh`(서비스의 `cachelab` 삭제), 서비스 IP 접근 목록에서
클라이언트 IP 제거.

### 측정하지 않은 것

DAX, ElastiCache Serverless, Valkey 클러스터 모드와 레플리카, ClickHouse Cloud PrivateLink,
single-flight나 잠금 기반 갱신, 집계 대신 Valkey 쓰기 시점 카운터(`INCR` / `ZINCRBY`), 클라이언트 측
캐시, AWS 리소스 비용.

### 파일

파일 표는 English 절과 같습니다.
