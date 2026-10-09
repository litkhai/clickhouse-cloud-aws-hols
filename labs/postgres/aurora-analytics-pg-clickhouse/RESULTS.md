# Results — 2026-10-09 run

[English](#english) | [한국어](#한국어)

## English

Derived from TPC-DS; not comparable to published TPC-DS results. Every number below was measured on
2026-10-09 between 03:30 and 05:35 UTC in ap-northeast-2 under the conditions listed; nothing is from a
vendor document unless it says so. Raw CSVs: `out/run-2026-10-09/` on the machine that ran it (gitignored).

### Conditions

| | |
|---|---|
| Aurora | PostgreSQL 18.6, `aurora_analytics` 1.0.0, Aurora Standard storage, one cluster: writer **B** db.t4g.large, reader **A** db.t4g.medium (added for this run so A and B ran at the same time) |
| P | ClickHouse Managed Postgres, PostgreSQL 18.6, 2 vCPU, **r6gd.large (16 GiB) or m6gd.large (8 GiB) — not known which during the run**: the m6gd.large resize sent at about 03:55 UTC still read r6gd.large at 04:05, and read m6gd.large at about 05:50; when it took effect was not recorded. pg_clickhouse 0.10 (updated from 0.3 by `21-pgfront-setup.sh`), binary driver, TLS → ClickHouse Cloud 26.6.1, 8 GiB per replica fixed, 2 replicas, data in MergeTree (tpcds-scripts DDL + the three adaptations in `20-clickhouse-load.sh`) |
| R | DuckDB 1.5.6 (Python module) over the generator's local database, m7g.4xlarge |
| Data | DuckDB 1.5.6 `tpcds` dsdgen, SF1 and SF10, Parquet zstd, one S3 bucket. ClickHouse loaded byte-identical copies under `tpcds-ch/` (see "Found on the way") |
| Queries | tpcds-scripts `engines/duckdb/queries` @ `1e4870cc`, 103 files, plus `patches/query30.diff`; same text for every target |
| Rules | concurrency 1; SF1: one run, 60 s timeout; SF10: one cold run (Aurora: `aurora_analytics_clear_cache()`; P: `SYSTEM DROP` caches) + one warm run when cold was ok, 120 s timeout. Timeout enforced by `pg_terminate_backend()` (see below) |
| Not run | SF100, targets C (Serverless v2), D (r8g.large), E (r8gd.xlarge), P-s3, interference (pgbench), the tuned run 2-b. The owner shortened the run to two hours |

### Q1 — does Aurora's embedded DuckDB work on db.t4g? Yes, on both.

Extension, schema inference from Parquet and queries all work on db.t4g.medium and db.t4g.large. Defaults:
`aurora_analytics.query_mem` 466,979 kB (medium) and 977,187 kB (large); `shared_buffers` 267,781 and 614,984 pages.

### Q2 — correctness, SF1, against R (DuckDB) and plain PostgreSQL 18

| target | same as R | differs | timeout (60 s) | OOM | spill error | error |
|---|---|---|---|---|---|---|
| A t4g.medium | 96 | 4 | 3 | 0 | 0 | 0 |
| B t4g.large | 96 | 4 | 3 | 0 | 0 | 0 |
| P pg_clickhouse | 87 | 5 | 5 | 0 | 0 | 6 |

- A and B return the same answer on all 100 queries they completed. Timeouts: q04, q11, q74.
- The four Aurora differences from R (q21, q34, q73, q83) are the answers plain PostgreSQL 18 gives (local
  rehearsal, same data): integer division truncates in PostgreSQL and not in DuckDB. Of the 99 queries
  comparable with plain PostgreSQL, Aurora matched PostgreSQL on 98; the exception, q78, matched DuckDB.
- P: q34, q73 differ the same way; q16, q94 (`EXISTS` with a non-equality condition) and q44 differ from both
  references (rehearsal notes: pushed-down semi join, Decimal parameter — inferred, not confirmed). Errors:
  q06, q32, q41, q92 "Resolved identifier … in parent scope" (seen on ClickHouse 26.6.1 here, not on 26.9 in the
  rehearsal), q64 generated `ALL INNER JOIN` syntax, q75 no supertype for Decimal(7,2) and Float64.
  29 of 103 queries pushed down completely (one Foreign Scan), 74 partly.

### Q3 / Q6 — SF10 (120 s timeout)

| target | completed | timeout | OOM | error | differs from R | cold total (completed) |
|---|---|---|---|---|---|---|
| A t4g.medium | 94 | 9 | 0 | 0 | 4 | 1,719 s |
| B t4g.large | 94 | 9 | 0 | 0 | 4 | 1,735 s |
| P pg_clickhouse | 87 | 10 | 0 | 6 | 4 | 872 s |

Geometric mean over the 82 queries every target completed:

| target | cold | warm |
|---|---|---|
| A t4g.medium | 9.35 s | 2.48 s |
| B t4g.large | 9.63 s | 2.52 s |
| P pg_clickhouse | 6.37 s | 4.17 s |

- Aurora timeouts (A and B, the same nine): q04, q05, q11, q14_1, q67, q70, q74, q77, q80. P timeouts: q01, q04,
  q05, q11, q30, q35, q72, q74, q81, q95; P errors as at SF1.
- Aurora differs from R on q14_2, q21, q34, q83; P on q16, q34, q44, q94.
- A and B were within 2 % of each other on every aggregate above.

### CloudWatch, 04:20–05:35 UTC, 5-minute periods

| metric | A db.t4g.medium | B db.t4g.large |
|---|---|---|
| `CPUCreditBalance` | 0 for the whole window | 0 for the whole window |
| `CPUSurplusCreditsCharged` | 0 | 0 |
| `CPUUtilization` max / avg | 57.7 % / 37.6 % | 52.8 % / 37.7 % |
| `AuroraAnalyticsMemoryUsage` max | 478 MB | 1.0 GB |
| `AuroraAnalyticsDiskSpillSize` max | 852 MB | 585 MB |
| `FreeableMemory` min | 1.66 GB | 5.18 GB |

Both instances ran with no CPU credits, which may be why the 4 GiB and 8 GiB instances performed alike
(inferred, not tested). Queries used their whole `query_mem` and spilled to local storage; none was cancelled
for memory.

### Found on the way (all fixed in the lab, see git log)

- **`statement_timeout` and `pg_cancel_backend()` do not stop an `aurora_analytics` query; it also keeps
  running after the client disconnects.** q04 ran 20 minutes past a 600 s and a 60 s timeout;
  `pg_cancel_backend()` returned true and nothing changed for 15 s; `pg_terminate_backend()` ended all three
  sessions within 15 s. On P (`pg_clickhouse`) `statement_timeout` works.
- DuckDB 1.5.6 writes `s3://…/<table>//data_N.parquet` when the COPY target ends in `/`. Aurora reads those
  keys; ClickHouse `s3()` lists them and then fails with "The specified key does not exist".
- Right after an INSERT, a count on the 2-replica ClickHouse Cloud service read fewer rows than were inserted
  (6,525,695 of 7,197,566); `select_sequential_consistency = 1` reads them all.

### Cleanup

2026-10-09 ~05:50 UTC: seoul-oltp's foreign schemas `sf1`/`sf10` and servers dropped (pg_clickhouse stays at 0.10), Seoul's `sf1`/`sf10` databases dropped, the reader instance deleted, `destroy.sh` (40 resources destroyed; checked: cluster, instances, bucket, endpoint, volume, secret gone), resize back to Seoul 8–120 GiB and seoul-oltp r6gd.large requested.

### Cost

Not read yet: Cost Explorer by tag `purpose=aurora-analytics-t4g-test` is one day behind (check on 2026-10-10).
ClickHouse Cloud usage for the window: `labs/billing/usage-cost`.

---

## 한국어

TPC-DS에서 파생했으며 공표된 TPC-DS 결과와 비교할 수 없습니다. 아래 수치는 모두 2026-10-09 03:30–05:35 UTC,
서울 리전, 위 조건에서 측정한 것입니다. 원자료 CSV는 실행한 머신의 `out/run-2026-10-09/`(git 제외).

### 조건

영어 절의 표와 같습니다. 요점: Aurora PostgreSQL 18.6 + `aurora_analytics` 1.0.0, 한 클러스터에 writer B
db.t4g.large와 reader A db.t4g.medium(이번 실행에서 A·B를 동시에 돌리려고 추가). P는 ClickHouse Managed
Postgres 18.6, 2 vCPU, **r6gd.large(16 GiB)인지 m6gd.large(8 GiB)인지 실행 중 크기는 모름**(03:55경 보낸 m6gd.large 변경이 04:05에는 r6gd.large, 05:50경에는 m6gd.large로 조회됨, 적용 시각 기록 없음) + pg_clickhouse 0.10 → ClickHouse Cloud 26.6.1, 레플리카당 8 GiB 고정 ×2.
R은 DuckDB 1.5.6. 질의 103개(tpcds-scripts `1e4870cc` + `query30.diff`)를 모든 대상에 같은 문구로. SF1은 1회·60초,
SF10은 차가운 1회 + 성공 시 따뜻한 1회·120초. **실행 안 함**: SF100, C·D·E, P-s3, 간섭, 2-b(소유자가 2시간으로 줄임).

### Q1 — t4g에서 Aurora 내장 DuckDB가 되는가: 둘 다 된다

확장·Parquet 스키마 추론·질의가 db.t4g.medium·large 모두에서 동작. 기본 `query_mem` 466,979 kB(medium), 977,187 kB(large).

### Q2 — 정확성, SF1

| 대상 | R과 같음 | 다름 | 시간 초과(60초) | OOM | 넘침 오류 | 오류 |
|---|---|---|---|---|---|---|
| A t4g.medium | 96 | 4 | 3 | 0 | 0 | 0 |
| B t4g.large | 96 | 4 | 3 | 0 | 0 | 0 |
| P pg_clickhouse | 87 | 5 | 5 | 0 | 0 | 6 |

- A·B는 완료한 100개 모두 같은 답. 시간 초과는 q04·q11·q74.
- Aurora가 R과 다른 4개(q21·q34·q73·q83)는 순수 PostgreSQL 18의 답과 같음(정수 나눗셈: PostgreSQL은 몫만, DuckDB는 소수).
  PostgreSQL과 비교 가능한 99개 중 98개가 PostgreSQL과 같고, q78만 DuckDB 쪽 답.
- P: q34·q73은 같은 이유, q16·q94(`EXISTS` + 부등호 조건)·q44는 두 기준 모두와 다름(추정 원인은 리허설 노트, 확인 안 함).
  오류는 q06·q32·q41·q92(ClickHouse 26.6.1의 "Resolved identifier … in parent scope", 리허설의 26.9에서는 없음),
  q64(생성 SQL의 `ALL INNER JOIN`), q75(Decimal과 Float64 공통 타입 없음). 전부 내려간 질의 29개, 일부 74개.

### Q3 / Q6 — SF10 (120초)

| 대상 | 완료 | 시간 초과 | OOM | 오류 | R과 다름 | 차가운 실행 합계(완료분) |
|---|---|---|---|---|---|---|
| A t4g.medium | 94 | 9 | 0 | 0 | 4 | 1,719초 |
| B t4g.large | 94 | 9 | 0 | 0 | 4 | 1,735초 |
| P pg_clickhouse | 87 | 10 | 0 | 6 | 4 | 872초 |

모든 대상이 완료한 82개의 기하평균: 차가운 실행 A 9.35초 · B 9.63초 · P 6.37초, 따뜻한 실행 A 2.48초 · B 2.52초 · P 4.17초.
Aurora 시간 초과(A·B 같은 9개): q04·q05·q11·q14_1·q67·q70·q74·q77·q80. A와 B는 모든 집계에서 2% 안쪽 차이.

### CloudWatch (04:20–05:35 UTC, 5분)

두 인스턴스 모두 `CPUCreditBalance`가 **구간 내내 0**, `CPUSurplusCreditsCharged` 0, CPU 최대 57.7%(A)·52.8%(B).
분석 엔진 메모리 최대 478 MB(A)·1.0 GB(B)로 `query_mem`까지 쓰고 디스크 넘침 최대 852 MB(A)·585 MB(B), 메모리 취소 0건.
4 GiB와 8 GiB가 비슷했던 것은 크레딧 고갈로 기준 성능에 묶였기 때문일 수 있음(추정, 시험 안 함).

### 도중에 찾은 것 (실습에 모두 반영)

- **`statement_timeout`과 `pg_cancel_backend()`로는 `aurora_analytics` 질의가 멈추지 않고, 클라이언트가 끊겨도 계속 돈다.**
  q04가 600초·60초 제한을 넘어 20분 실행, `pg_cancel_backend()`는 true를 돌려주고 15초간 변화 없음, `pg_terminate_backend()`는
  15초 안에 세 세션 모두 종료. P(pg_clickhouse)에서는 `statement_timeout`이 동작.
- DuckDB 1.5.6은 COPY 대상이 `/`로 끝나면 S3에 `<표>//data_N.parquet`로 씀. Aurora는 읽고 ClickHouse `s3()`는 목록만 보고 읽기에 실패.
- 레플리카 2개 ClickHouse Cloud에서 INSERT 직후 count가 적게 나옴(7,197,566 중 6,525,695). `select_sequential_consistency = 1`로 해결.

### 정리

2026-10-09 05:50경 UTC: seoul-oltp의 외래 스키마 `sf1`·`sf10`과 서버 삭제(pg_clickhouse는 0.10 그대로), Seoul의 `sf1`·`sf10` DB 삭제, 리더 인스턴스 삭제, `destroy.sh`(40개 삭제, 클러스터·인스턴스·버킷·엔드포인트·볼륨·시크릿 없음 확인), Seoul 8–120 GiB·seoul-oltp r6gd.large로 되돌리기 요청.

### 비용

아직 읽지 않음: 태그 `purpose=aurora-analytics-t4g-test`의 Cost Explorer는 하루 늦게 반영(2026-10-10 확인).
ClickHouse Cloud 사용분은 `labs/billing/usage-cost`.
