# Results — run3, 2026-11-07

[English](#english) | [한국어](#한국어)

## English

**Run**: `results/20261107T-run3/` (2026-11-07 04:37:38 → 06:40:43 UTC), `matrix.sh all`, 10 s warm-up +
60 s recorded per run, request timeout 10 s (client) with `max_execution_time=10` (server).
Tables: [`results/20261107T-run3/REPORT.md`](results/20261107T-run3/REPORT.md) (`40-report.py`).

**Configuration**

| Part | What ran |
|---|---|
| Client | EC2 c7g.2xlarge, ap-northeast-2a, `cachebench` (Go 1.27.1, go-redis v9.23.0, aws-sdk-go-v2 dynamodb v1.73.2) |
| Valkey | ElastiCache for Valkey 8.1, 1 × cache.r7g.large, TLS, same AZ as the client |
| DynamoDB | on-demand, two tables, gateway endpoint, eventually consistent reads |
| ClickHouse | ClickHouse Cloud 26.8.1.608, ap-northeast-2, public endpoint, 2 replicas, **vertical autoscaling 8–120 GiB and shared with other workloads** |
| Data | `cachelab.events` 100M rows over 30 days (1.24 GiB compressed), 1M users; `user_stats` 1M rows; `events_1m` rollup |

**Read this before the numbers**

- The service autoscaled during the run (`sizing.jsonl`, console event log): S1 ran while replicas grew from
  9 vCPU / 36 GiB through 17 / 68 to 30 / 120; **S2 and S3 ran at 30 vCPU / 120 GiB × 2 replicas** (05:40 → end).
  S1 numbers therefore mix sizes; they are not a capacity figure for any one size.
- The service also served other workloads (a live ingest feed, alert queries) during the run.
- In-run server stats failed for most of S1 (`ALL_CONNECTION_TRIES_FAILED` while replicas were replaced).
  `35-server-stats.sh` re-read `query_log` afterwards; runs whose replicas were already gone have no server stats.
- Closed loop: a worker waits for its answer, so in the aside arms a slow miss holds the worker up to the
  10 s timeout. QPS of the aside arms in S1 is bounded by how fast misses come back, not by the cache.
- Earlier attempts are kept, not used: `run1` (service at 2 vCPU / 8 GiB, stopped after 12 runs) and
  `run2` (no server-side time limit — abandoned queries kept running; stopped after 9 runs).

**Floor** (cheapest round trip)

| System | conc 1: p50 / p99 ms | conc 16: QPS |
|---|---|---|
| ClickHouse `SELECT 1` | 3.15 / 3.89 | 4,200 |
| Valkey `PING` | 0.05 / 0.06 | 160,962 |
| DynamoDB `GetItem` (missing key) | 1.44 / 2.41 | 8,295 |

**S1 — ad-hoc aggregation** (group by 1 of 5 dimensions, up to 3 filters, 1 h – 30 d of 100M rows; Zipf 1.1)

| Query space | `ch` QPS (p50 ms) at conc 8 / 32 / 128 | best cached arm, conc 32 | hit ratio |
|---|---|---|---|
| 100 | 20 (173) / 21 (591) / 27 (2,004) | `vk-aside` 19,750 QPS, p50 0.23 ms; `ch-qc` 1,849 QPS, p50 4.1 ms | 1.00 |
| 10,000 | 35 (114) / 36 (364) / 49 (1,089) | `ddb-aside` 1,545 QPS, `vk-aside` 645 QPS | 0.88–0.93 |
| 1,000,000 | 40 (98) / 37 (403) / 51 (1,055) | all aside arms ≈ 110–140 QPS | 0.59–0.63 |

- Direct ClickHouse stays at 20–50 QPS with p99 2–10 s at every concurrency: this workload is CPU-bound.
- A cache helps only by the repeats: at 100 distinct queries everything hits; at 1M, 40% still miss and the
  misses set the throughput (all three caches converge to ≈ 110–140 QPS). Hits stay fast (Valkey p50 ≈ 0.1 ms,
  DynamoDB ≈ 2 ms), the p99 is the miss.
- ClickHouse's own query cache reached 1,849 QPS at p50 4.1 ms (space 100, conc 32) without a second system.

**S2 — point lookup** (one user's totals out of 1M, Zipf 1.1)

| Arm | conc 8 | conc 32 | conc 128 | conc 512 |
|---|---|---|---|---|
| `ch` raw events, projection by `user_id` | 431 QPS, p50 18 ms | 498, 65 ms | 458, 258 ms | 499, 882 ms |
| `ch-agg` pre-aggregated `user_stats` | 1,397, 5.4 ms | 4,436, 6.1 ms | 5,140, 16 ms | 4,879, 98 ms |
| `ddb-kv` | 4,155, 1.8 ms | 18,069, 1.7 ms | 13,784, 4.3 ms | 12,825, 19 ms |
| `vk-kv` | 100,556, 0.07 ms | 160,033, 0.20 ms | 157,693, 0.83 ms | 149,987, 3.2 ms |
| `vk-aside` over `ch-agg` | 6,968, 0.07 ms | 45,992, 0.10 ms | 71,429, 0.14 ms | 60,097, 0.12 ms |
| `ddb-aside` over `ch-agg` | 1,666, 2.6 ms | 8,867, 2.0 ms | 14,289, 4.0 ms | 9,311, 26 ms |

- No errors in any S2 run. A pre-aggregated table is ~10× the raw projection (reads ~16k rows instead of ~620k
  per lookup, console query insights) and holds ~5k QPS at single-digit ms up to conc 32.
- Valkey as the serving store is ~30× that and sub-millisecond; DynamoDB sits between (1.7–4 ms up to conc 128).
- Loading the stores: Valkey 1M users in 2.8 s, 128 MB `used_memory`. DynamoDB 202 s, 1,100 batches given
  up after retries, 163,142 `WriteThrottleEvents` on the new on-demand table (CloudWatch); `kv_miss` stayed at
  3–22 per run.

**S3 — hot dashboard** (12 tiles, Zipf 1.1, 10k rows inserted every second, 69 batches, 0 errors per run)

| Arm (TTL) | conc 32: QPS, p50 | to ClickHouse /s (peak /s) | staleness p50 / p99 s |
|---|---|---|---|
| `ch` | 492, 50 ms | 492 (657) | 1.4 / 1.9 |
| `ch-agg` | 470, 46 ms | 470 (553) | 1.2 / 1.8 |
| `ch-qc` (5 s) | 6,453, 4.1 ms | all served inside ClickHouse | 4.0 / 6.5 |
| `ch-qc` (60 s) | 8,298, 3.8 ms | all served inside ClickHouse | 41.9 / 71.6 |
| `vk-aside` (5 s) | 110,104, 0.17 ms | 65 (227) | 4.2 / 6.9 |
| `vk-aside` (60 s) | 155,265, 0.18 ms | 2.5 (119) | 44.6 / 73.4 |
| `ddb-aside` (5 s) | 14,096, 1.8 ms | 21 (67) | 3.8 / 6.0 |
| `ddb-aside` (60 s) | 16,004, 1.8 ms | 1.9 (59) | 41.7 / 71.6 |

- Every cache trades freshness for load at about its TTL; ClickHouse direct answered with data ~1.5 s old.
- The stampede is visible: with Valkey at TTL 60 the mean load on ClickHouse is 2.5/s but the peak second is
  119 (conc 128: 12.7/s mean, 256 peak) — the expiry of a hot key sends every waiting worker to ClickHouse.
- `ch-agg` (per-minute rollup) was no faster than raw on these tiles; conc 128 rows are in `REPORT.md`.

**Not measured**: see the README list (DAX, Serverless, cluster mode, PrivateLink, single-flight, write-time
counters, AWS cost). The query cache hit/miss per replica is in `qc_read` / `qc_write` where server stats exist.

---

## 한국어

**실행**: `results/20261107T-run3/`(2026-11-07 04:37:38 → 06:40:43 UTC), `matrix.sh all`, 실행마다 워밍업 10초 +
기록 60초, 요청 타임아웃 10초(클라이언트)와 `max_execution_time=10`(서버). 전체 표는
[`results/20261107T-run3/REPORT.md`](results/20261107T-run3/REPORT.md).

**구성**: 클라이언트 EC2 c7g.2xlarge(ap-northeast-2a), ElastiCache for Valkey 8.1 cache.r7g.large 1대(TLS, 같은 AZ),
DynamoDB 온디맨드 테이블 2개(게이트웨이 엔드포인트), ClickHouse Cloud 26.8.1.608(서울, 공개 엔드포인트,
레플리카 2개, **수직 오토스케일링 8–120 GiB, 다른 워크로드와 공유**). 데이터는 30일치 1억 행(압축 1.24 GiB),
사용자 100만 명.

**숫자보다 먼저 읽을 것**

- 실행 중 서비스가 오토스케일링했습니다. S1은 레플리카가 9 vCPU / 36 GiB → 17 / 68 → 30 / 120으로 커지는
  동안 돌았고, **S2·S3는 30 vCPU / 120 GiB × 2**에서 돌았습니다. S1 숫자는 여러 크기가 섞여 있어 특정 크기의
  용량 값이 아닙니다.
- 실행 중 서비스는 다른 워크로드(실시간 적재, 알림 쿼리)도 처리했습니다.
- S1 대부분은 실행 중 서버 통계 조회가 실패했습니다(레플리카 교체 중 `ALL_CONNECTION_TRIES_FAILED`).
  `35-server-stats.sh`로 나중에 `query_log`를 다시 읽었고, 이미 사라진 레플리카의 실행은 서버 통계가 없습니다.
- 닫힌 루프라서 aside 경로에서는 느린 미스가 워커를 최대 10초 붙잡습니다. S1 aside 경로의 QPS는 캐시가 아니라
  미스가 돌아오는 속도가 정합니다.
- 앞선 시도는 보관만 하고 쓰지 않습니다: `run1`(2 vCPU / 8 GiB, 12회 후 중단), `run2`(서버 시간 제한 없음 —
  포기한 쿼리가 계속 실행됨, 9회 후 중단).

**바닥 지연**: ClickHouse `SELECT 1` p50 3.15 ms, Valkey `PING` 0.05 ms, DynamoDB `GetItem` 1.44 ms(동시성 1).
동시성 16에서 각각 4,200 / 160,962 / 8,295 QPS.

**S1 애드혹 집계**

- ClickHouse 직접 질의는 모든 동시성에서 20–50 QPS, p99 2–10초. CPU가 한계인 워크로드입니다.
- 캐시는 반복되는 만큼만 돕습니다. 서로 다른 쿼리 100개면 전부 적중(Valkey 19,750 QPS, p50 0.23 ms),
  100만 개면 40%가 미스이고 그 미스가 처리량을 정해 세 캐시 모두 약 110–140 QPS로 수렴합니다. 적중은 빠르고
  (Valkey p50 ≈ 0.1 ms, DynamoDB ≈ 2 ms) p99는 미스입니다.
- ClickHouse 쿼리 캐시만으로 1,849 QPS, p50 4.1 ms(쿼리 100개, 동시성 32) — 두 번째 시스템 없이.

**S2 포인트 조회**

- 원시 이벤트(프로젝션)는 약 500 QPS에서 멈추고 p50이 18 → 882 ms로 늘어납니다.
- 미리 집계한 `user_stats`는 약 10배(조회당 읽는 행 ~62만 → ~1.6만), 동시성 32까지 약 5,000 QPS를 한 자릿수 ms로.
- Valkey 서빙 저장소는 그 약 30배이고 1 ms 미만, DynamoDB는 그 사이(동시성 128까지 1.7–4 ms). 모든 S2 실행 오류 0.
- 적재: Valkey는 100만 명을 2.8초, `used_memory` 128 MB. DynamoDB는 202초, 재시도 후 포기한 배치 1,100개,
  새 온디맨드 테이블에서 `WriteThrottleEvents` 163,142건(CloudWatch). 실행별 `kv_miss`는 3–22건.

**S3 핫 대시보드**(타일 12개, 매초 1만 행 적재)

- 모든 캐시는 TTL만큼 신선도를 내주고 부하를 덜어냅니다. 직접 질의는 약 1.5초 전 데이터로 답했습니다.
- 쿼리 캐시: 6,453–8,298 QPS, p50 약 4 ms, 신선도 p50 4초(TTL 5) / 42초(TTL 60).
- Valkey TTL 60: ClickHouse 평균 부하 2.5/s지만 최고 초당 119건(동시성 128에서 평균 12.7, 최고 256) —
  핫 키 만료 순간 기다리던 워커가 한꺼번에 ClickHouse로 갑니다(stampede).
- 분 단위 롤업(`ch-agg`)은 이 타일에서 원시 테이블보다 빠르지 않았습니다.

**측정하지 않은 것**: README 목록과 같습니다.
