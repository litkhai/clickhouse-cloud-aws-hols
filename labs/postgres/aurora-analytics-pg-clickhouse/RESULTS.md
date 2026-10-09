# Results — 2026-10-09 runs

[English](#english) | [한국어](#한국어)

## English

Measurement record only: conditions and numbers, no interpretation. Derived from TPC-DS; not comparable to
published TPC-DS results. All runs on 2026-10-09 in ap-northeast-2. Raw CSVs stay on the machine that ran them
(`out/run-2026-10-09/`, `out/run-2026-10-09-sf100/`, gitignored).

### Common conditions

- Queries: tpcds-scripts `engines/duckdb/queries` @ `1e4870cc` (103 files) + `patches/query30.diff`, same text on every target; concurrency 1.
- Data: DuckDB 1.5.6 `tpcds` dsdgen, Parquet zstd in one S3 bucket. Parquet size: SF1 0.29 GB, SF10 2.92 GB, SF100 27.8 GB.
- Aurora: PostgreSQL 18.6, `aurora_analytics` 1.0.0, Aurora Standard; foreign tables with schema inference. Default settings.
- P: PostgreSQL front end (ClickHouse Managed Postgres 18.6) + pg_clickhouse 0.10, binary driver, TLS → ClickHouse Cloud 26.6.1; data loaded into MergeTree (tpcds-scripts DDL + the three adaptations in `20-clickhouse-load.sh`). Default settings. The front end size during the runs is r6gd.large or m6gd.large (2 vCPU); a resize was requested and its effective time was not recorded.
- R: DuckDB 1.5.6 over the generator's local database (reference answers).
- Cold run: Aurora `aurora_analytics_clear_cache()`; P `SYSTEM DROP` caches. Timeouts enforced by `pg_terminate_backend()` from a second connection.
- Answer comparison: rows sorted, numbers rounded to 2 decimals, sha256.

### Run 1 — SF1 and SF10 (03:30–05:35 UTC)

Targets: A db.t4g.medium (2 vCPU, 4 GiB, reader), B db.t4g.large (2 vCPU, 8 GiB, writer), P with ClickHouse Cloud 8 GiB per replica × 2.
Defaults read: `aurora_analytics.query_mem` 466,979 kB (A), 977,187 kB (B); `shared_buffers` 267,781 / 614,984 pages.

**SF1** (one run, 60 s)

| target | same answer as R | different | timeout | out of memory | error |
|---|---|---|---|---|---|
| A | 96 | 4 | 3 | 0 | 0 |
| B | 96 | 4 | 3 | 0 | 0 |
| P | 87 | 5 | 5 | 0 | 6 |

- A, B: different from R on q21, q34, q73, q83; timeouts q04, q11, q74. A and B gave identical answers on all 100 completed.
- Against plain PostgreSQL 18 (local rehearsal, same data): A matched on 98 of 99 comparable queries; q78 matched R instead.
- P: different from R on q16, q34, q44, q73, q94; timeouts q01, q04, q11, q74, q81; errors q06, q32, q41, q92 ("Resolved identifier … in parent scope"), q64 (`ALL INNER JOIN` syntax), q75 (no supertype for Decimal(7,2) and Float64). Pushdown by `EXPLAIN (VERBOSE)`: 29 full, 74 partial.

**SF10** (cold once + one warm run when cold succeeded, 120 s)

| target | completed | timeout | out of memory | error | different from R |
|---|---|---|---|---|---|
| A | 94 | 9 | 0 | 0 | 4 |
| B | 94 | 9 | 0 | 0 | 4 |
| P | 87 | 10 | 0 | 6 | 4 |

The 82 queries completed on all three:

| | A | B | P |
|---|---|---|---|
| cold total | 1,571 s | 1,589 s | 758 s |
| warm total | 668 s | 661 s | 620 s |
| cold geomean | 9.35 s | 9.63 s | 6.37 s |
| warm geomean | 2.48 s | 2.52 s | 4.17 s |

Per-query ratio B ÷ P: cold median 1.45 (P lower on 51 of 82), warm median 0.55 (P lower on 23 of 82). A ÷ B: median 1.01 cold, 1.02 warm.

CloudWatch (04:20–05:35 UTC): `CPUCreditBalance` 0 (A) / 0 after 04:15 (B); `CPUSurplusCreditBalance` rose to 26.5 (A) / 27.8 (B);
`CPUSurplusCreditsCharged` 0 in the window; `CPUUtilization` max 99.7 % in a 15-minute period; `AuroraAnalyticsMemoryUsage` max 478 MB (A) / 1.0 GB (B);
`AuroraAnalyticsDiskSpillSize` max 852 MB (A) / 585 MB (B). Aurora T4g instances run in Unlimited mode; CPU credits $0.09 per vCPU-hour (Aurora pricing page, read 2026-10-09).

### Run 2 — SF100 (08:51–12:22 UTC)

Targets: B db.t4g.large (writer), E db.r8gd.2xlarge (8 vCPU, 64 GiB, local NVMe, reader; `query_mem` 8,072,885 kB),
P with ClickHouse Cloud 32 GiB (8 vCPU) per replica × 2. Cold once + one warm run when cold succeeded, 300 s; each target capped at 3 hours.
During this run, `aurora_analytics.enabled` in the cluster parameter group was rewritten from `1` to `true` (dynamic, no reboot) by a targeted apply.

| target | reached | completed | timeout | out of memory | error | different from R |
|---|---|---|---|---|---|---|
| B | 75 of 103 (cap reached at q71) | 53 | 20 | 2 (q23_1, q23_2) | 0 | 3 (q21, q34, q66) |
| E | 103 | 92 | 11 | 0 | 0 | 4 (q21, q34, q73, q83) |
| P | 103 | 78 | 16 | 3 (q17, q25, q29) | 6 | 6 (q16, q34, q44, q49, q73, q94) |

- E timeouts: q04, q05, q11, q14_1, q14_2, q49, q67, q70, q74, q77, q80.
- P timeouts: q01, q02, q04, q05, q11, q14_1, q14_2, q30, q35, q54, q67, q72, q74, q78, q81, q95. P out of memory: `(total) memory limit exceeded … maximum: 28.80 GiB`. P errors: as at SF1. Pushdown: 28 full, 72 partial, 3 not classified.
- Completed only on E: 18 queries; only on P: q49, q70, q77, q80.

The 74 queries completed on both E and P:

| | E | P |
|---|---|---|
| cold total | 3,860 s | 1,337 s |
| warm total | 1,130 s | 1,140 s |
| cold geomean | 21.1 s | 11.3 s |
| warm geomean | 3.05 s | 8.09 s |

Per-query ratio E ÷ P: cold median 2.57 (P lower on 43 of 74; by 3x or more on 32; E lower by 3x or more on 7), warm median 0.33
(P lower on 19; by 3x or more on 6; E lower by 3x or more on 37). Largest warm ratios: q66 22.7, q36 16.3, q86 6.5, q88 5.2 (P lower);
q31 24.8, q83 22.3, q71 19.8, q15 19.4, q43 19.2 (E lower).

List prices per hour, ap-northeast-2 (Price List API and clickhouse.com/pricing, read 2026-10-09): db.t4g.large $0.227, db.r8gd.2xlarge $1.502,
ClickHouse Cloud Enterprise $0.4801 per unit (8 GiB · 2 vCPU) → $3.84 for 32 GiB × 2, generator m7g.4xlarge $0.8024.

### Run 3 — SF10 as Iceberg tables in the AWS Glue Data Catalog (12:26–13:31 UTC)

Same SF10 data (DuckDB dsdgen, regenerated), registered through Athena: a Parquet external table per TPC-DS table,
then CTAS into an Iceberg table (`table_type='ICEBERG'`, Parquet, ZSTD) in a second Glue database; `SELECT *`, no sort.
Targets B (db.t4g.large), E (db.r8gd.2xlarge), P (ClickHouse Cloud 32 GiB per replica × 2). Cold once + one warm run, 120 s.

| step | result |
|---|---|
| Athena CTAS → 24 Iceberg tables in Glue | 24 of 24, row counts equal to the generator's |
| Aurora `IMPORT FOREIGN SCHEMA <glue db> … OPTIONS (location '<Glue catalog ARN>')` | 24 of 24 imported, row counts equal |
| ClickHouse `DataLakeCatalog` (`catalog_type = 'glue'`, `aws_role_arn`) | database created; 24 of 24 counted, row counts equal |
| ClickHouse Iceberg tables over the same files + pg_clickhouse `IMPORT FOREIGN SCHEMA` | done |

| target | completed | timeout | error | different from R |
|---|---|---|---|---|
| B (Iceberg) | 94 | 9 | 0 | 4 (q21, q34, q77, q83) |
| E (Iceberg) | 100 | 3 (q04, q11, q74) | 0 | 4 (q21, q34, q54, q83) |
| P (Iceberg) | 86 | 9 | 8 | 4 (q16, q21, q44, q94) |

- P errors: as at SF1 (6), plus q34 and q73 with `Not found column greater(__table4.hd_vehicle_count, 0_UInt8) in block` while reading the Iceberg files.
- B on Iceberg vs B on Parquet (run 1), 93 queries completed on both: identical answers on all 93; cold total 1,087 s vs 1,615 s, cold geomean 8.09 s vs 8.53 s; warm total 644 s vs 588 s, warm geomean 3.16 s vs 2.28 s.
- E vs P on Iceberg, 86 queries completed on both: cold total 814 s vs 599 s, cold geomean 3.70 s vs 2.81 s; warm total 667 s vs 552 s, warm geomean 1.49 s vs 2.00 s.
- P pushdown: 29 full, 74 partial.

### Found during the runs (fixed in the lab)

- `statement_timeout` and `pg_cancel_backend()` did not stop a running `aurora_analytics` query (q04 ran 20 minutes past 600 s and 60 s limits; cancel returned true with no change for 15 s; the query continued after the client was killed). `pg_terminate_backend()` ended it within 15 s. On P, `statement_timeout` cancelled queries.
- DuckDB 1.5.6 wrote `<table>//data_N.parquet` keys on S3 when the COPY target ended in `/`; Aurora read them, ClickHouse `s3()` failed with "The specified key does not exist".
- A count right after an INSERT on the 2-replica ClickHouse Cloud service returned 6,525,695 of 7,197,566 rows; with `select_sequential_consistency = 1` it returned all.

### Cleanup and cost

Run 1 was destroyed at about 05:50 UTC (40 resources), runs 2 and 3 at about 13:43 UTC (46 resources, incl. the Glue databases, Athena workgroup and Glue endpoint; the reader instances were deleted first). Checked afterwards: no cluster, instance, bucket, Glue database or VPC endpoint left. ClickHouse Cloud: the lab databases were dropped and the service sizes requested back (8–120 GiB per replica; front end r6gd.large); pg_clickhouse on the front end stays at 0.10.
Cost: Cost Explorer by tag `purpose=aurora-analytics-t4g-test`, to be read on 2026-10-10.

---

## 한국어

측정 기록만 담습니다: 조건과 수치, 해석 없음. TPC-DS 파생이며 공표된 TPC-DS 결과와 비교할 수 없습니다. 모든 실행은 2026-10-09, 서울 리전.
원자료 CSV는 실행한 머신의 `out/run-2026-10-09/`, `out/run-2026-10-09-sf100/`(git 제외).

### 공통 조건

- 질의: tpcds-scripts `engines/duckdb/queries` @ `1e4870cc`(103개) + `patches/query30.diff`, 모든 대상에 같은 문구, 동시성 1.
- 데이터: DuckDB 1.5.6 `tpcds` dsdgen, Parquet zstd, S3 버킷 하나. 크기 SF1 0.29 GB, SF10 2.92 GB, SF100 27.8 GB.
- Aurora: PostgreSQL 18.6, `aurora_analytics` 1.0.0, Aurora Standard, 스키마 추론 외래 테이블, 기본 설정.
- P: PostgreSQL 앞단(ClickHouse Managed Postgres 18.6) + pg_clickhouse 0.10, binary 드라이버, TLS → ClickHouse Cloud 26.6.1, MergeTree 적재(tpcds-scripts DDL + `20-clickhouse-load.sh`의 세 가지 조정), 기본 설정. 실행 중 앞단 크기는 r6gd.large 또는 m6gd.large(2 vCPU) — 크기 변경 요청의 적용 시각은 기록되지 않음.
- R: 생성 머신 로컬 데이터베이스의 DuckDB 1.5.6(정답 기준).
- 차가운 실행: Aurora `aurora_analytics_clear_cache()`, P `SYSTEM DROP` 캐시. 제한 시간은 별도 연결의 `pg_terminate_backend()`로 적용.
- 답 비교: 행 정렬, 숫자 소수 둘째 자리 반올림, sha256.

### 실행 1 — SF1·SF10 (03:30–05:35 UTC)

대상: A db.t4g.medium(2 vCPU, 4 GiB, reader), B db.t4g.large(2 vCPU, 8 GiB, writer), P는 ClickHouse Cloud 레플리카당 8 GiB × 2.
기본값: `aurora_analytics.query_mem` 466,979 kB(A), 977,187 kB(B), `shared_buffers` 267,781 / 614,984 페이지.

**SF1**(1회, 60초)

| 대상 | R과 같은 답 | 다름 | 시간 초과 | 메모리 부족 | 오류 |
|---|---|---|---|---|---|
| A | 96 | 4 | 3 | 0 | 0 |
| B | 96 | 4 | 3 | 0 | 0 |
| P | 87 | 5 | 5 | 0 | 6 |

- A·B: R과 다른 질의 q21·q34·q73·q83, 시간 초과 q04·q11·q74. 완료한 100개에서 A와 B의 답은 모두 같음.
- 일반 PostgreSQL 18(로컬 리허설, 같은 데이터)과 비교: 비교 가능한 99개 중 98개 일치, q78은 R과 일치.
- P: R과 다른 질의 q16·q34·q44·q73·q94, 시간 초과 q01·q04·q11·q74·q81, 오류 q06·q32·q41·q92("Resolved identifier … in parent scope"), q64(`ALL INNER JOIN` 문법), q75(Decimal(7,2)와 Float64의 공통 타입 없음). `EXPLAIN (VERBOSE)` 기준 전부 내려감 29, 일부 74.

**SF10**(차가운 1회 + 성공 시 따뜻한 1회, 120초)

| 대상 | 완료 | 시간 초과 | 메모리 부족 | 오류 | R과 다름 |
|---|---|---|---|---|---|
| A | 94 | 9 | 0 | 0 | 4 |
| B | 94 | 9 | 0 | 0 | 4 |
| P | 87 | 10 | 0 | 6 | 4 |

세 대상이 모두 완료한 82개:

| | A | B | P |
|---|---|---|---|
| 차가운 합계 | 1,571초 | 1,589초 | 758초 |
| 따뜻한 합계 | 668초 | 661초 | 620초 |
| 차가운 기하평균 | 9.35초 | 9.63초 | 6.37초 |
| 따뜻한 기하평균 | 2.48초 | 2.52초 | 4.17초 |

질의별 비율 B ÷ P: 차가운 중앙값 1.45(82개 중 51개에서 P가 낮음), 따뜻한 중앙값 0.55(23개에서 P가 낮음). A ÷ B: 중앙값 차가운 1.01, 따뜻한 1.02.

CloudWatch(04:20–05:35 UTC): `CPUCreditBalance` 0(A) / 04:15 이후 0(B), `CPUSurplusCreditBalance` 26.5(A) / 27.8(B)까지 증가,
구간 내 `CPUSurplusCreditsCharged` 0, `CPUUtilization` 15분 구간 최대 99.7%, `AuroraAnalyticsMemoryUsage` 최대 478 MB(A) / 1.0 GB(B),
`AuroraAnalyticsDiskSpillSize` 최대 852 MB(A) / 585 MB(B). Aurora T4g는 Unlimited 모드, CPU 크레딧 vCPU-시간당 $0.09(Aurora 가격 페이지, 2026-10-09 확인).

### 실행 2 — SF100 (08:51–12:22 UTC)

대상: B db.t4g.large(writer), E db.r8gd.2xlarge(8 vCPU, 64 GiB, 로컬 NVMe, reader, `query_mem` 8,072,885 kB),
P는 ClickHouse Cloud 레플리카당 32 GiB(8 vCPU) × 2. 차가운 1회 + 성공 시 따뜻한 1회, 300초, 대상당 3시간 상한.
이 실행 중 클러스터 파라미터 그룹의 `aurora_analytics.enabled`가 대상 지정 apply로 `1`에서 `true`로 다시 쓰임(동적, 재시작 없음).

| 대상 | 실행 | 완료 | 시간 초과 | 메모리 부족 | 오류 | R과 다름 |
|---|---|---|---|---|---|---|
| B | 103개 중 75개(q71에서 상한) | 53 | 20 | 2 (q23_1·q23_2) | 0 | 3 (q21·q34·q66) |
| E | 103 | 92 | 11 | 0 | 0 | 4 (q21·q34·q73·q83) |
| P | 103 | 78 | 16 | 3 (q17·q25·q29) | 6 | 6 (q16·q34·q44·q49·q73·q94) |

- E 시간 초과: q04·q05·q11·q14_1·q14_2·q49·q67·q70·q74·q77·q80.
- P 시간 초과: q01·q02·q04·q05·q11·q14_1·q14_2·q30·q35·q54·q67·q72·q74·q78·q81·q95. P 메모리 부족: `(total) memory limit exceeded … maximum: 28.80 GiB`. P 오류: SF1과 같음. 푸시다운: 전부 28, 일부 72, 분류 안 됨 3.
- E만 완료: 18개, P만 완료: q49·q70·q77·q80.

E와 P가 모두 완료한 74개:

| | E | P |
|---|---|---|
| 차가운 합계 | 3,860초 | 1,337초 |
| 따뜻한 합계 | 1,130초 | 1,140초 |
| 차가운 기하평균 | 21.1초 | 11.3초 |
| 따뜻한 기하평균 | 3.05초 | 8.09초 |

질의별 비율 E ÷ P: 차가운 중앙값 2.57(74개 중 43개에서 P가 낮음, 3배 이상 32개, E가 3배 이상 낮음 7개), 따뜻한 중앙값 0.33
(P가 낮음 19개, 3배 이상 6개, E가 3배 이상 낮음 37개). 따뜻한 비율이 가장 큰 질의: q66 22.7, q36 16.3, q86 6.5, q88 5.2(P가 낮음),
q31 24.8, q83 22.3, q71 19.8, q15 19.4, q43 19.2(E가 낮음).

시간당 정가(서울, Price List API와 clickhouse.com/pricing, 2026-10-09 확인): db.t4g.large $0.227, db.r8gd.2xlarge $1.502,
ClickHouse Cloud Enterprise unit(8 GiB · 2 vCPU)당 $0.4801 → 32 GiB × 2는 $3.84, 생성 머신 m7g.4xlarge $0.8024.

### 실행 3 — SF10을 AWS Glue 카탈로그의 Iceberg 테이블로 (12:26–13:31 UTC)

같은 SF10 데이터(DuckDB dsdgen으로 다시 생성)를 Athena로 등록: 표마다 Parquet 외부 테이블을 만든 뒤 두 번째 Glue 데이터베이스에
Iceberg 테이블로 CTAS(`table_type='ICEBERG'`, Parquet, ZSTD), `SELECT *`, 정렬 없음.
대상 B(db.t4g.large), E(db.r8gd.2xlarge), P(ClickHouse Cloud 레플리카당 32 GiB × 2). 차가운 1회 + 따뜻한 1회, 120초.

| 단계 | 결과 |
|---|---|
| Athena CTAS → Glue에 Iceberg 테이블 24개 | 24/24, 행 수가 생성 시점과 같음 |
| Aurora `IMPORT FOREIGN SCHEMA <glue db> … OPTIONS (location '<Glue 카탈로그 ARN>')` | 24/24 가져옴, 행 수 같음 |
| ClickHouse `DataLakeCatalog`(`catalog_type = 'glue'`, `aws_role_arn`) | 데이터베이스 생성, 24/24 행 수 같음 |
| 같은 파일 위의 ClickHouse Iceberg 테이블 + pg_clickhouse `IMPORT FOREIGN SCHEMA` | 완료 |

| 대상 | 완료 | 시간 초과 | 오류 | R과 다름 |
|---|---|---|---|---|
| B (Iceberg) | 94 | 9 | 0 | 4 (q21·q34·q77·q83) |
| E (Iceberg) | 100 | 3 (q04·q11·q74) | 0 | 4 (q21·q34·q54·q83) |
| P (Iceberg) | 86 | 9 | 8 | 4 (q16·q21·q44·q94) |

- P 오류: SF1과 같은 6개 + Iceberg 파일을 읽을 때 `Not found column greater(__table4.hd_vehicle_count, 0_UInt8) in block`가 난 q34·q73.
- B의 Iceberg와 Parquet(실행 1) 비교, 둘 다 완료한 93개: 답 93개 모두 같음. 차가운 합계 1,087초 vs 1,615초, 기하평균 8.09초 vs 8.53초. 따뜻한 합계 644초 vs 588초, 기하평균 3.16초 vs 2.28초.
- Iceberg 위의 E와 P, 둘 다 완료한 86개: 차가운 합계 814초 vs 599초, 기하평균 3.70초 vs 2.81초. 따뜻한 합계 667초 vs 552초, 기하평균 1.49초 vs 2.00초.
- P 푸시다운: 전부 29, 일부 74.

### 실행 중 발견한 것 (실습에 반영)

- 실행 중인 `aurora_analytics` 질의를 `statement_timeout`과 `pg_cancel_backend()`가 멈추지 못함(q04가 600초·60초 제한을 넘어 20분 실행, 취소는 true를 반환하고 15초간 변화 없음, 클라이언트를 종료해도 계속 실행). `pg_terminate_backend()`는 15초 안에 종료. P에서는 `statement_timeout`이 질의를 취소함.
- DuckDB 1.5.6은 COPY 대상이 `/`로 끝나면 S3에 `<표>//data_N.parquet` 키로 씀. Aurora는 읽었고 ClickHouse `s3()`는 "The specified key does not exist"로 실패.
- 레플리카 2개 ClickHouse Cloud에서 INSERT 직후 count가 7,197,566행 중 6,525,695행을 반환, `select_sequential_consistency = 1`로는 전체를 반환.

### 정리와 비용

실행 1은 05:50 UTC경(40개), 실행 2·3은 13:43 UTC경(46개, Glue 데이터베이스·Athena 작업 그룹·Glue 엔드포인트 포함, 리더 인스턴스는 먼저 삭제) 삭제. 이후 확인: 클러스터·인스턴스·버킷·Glue 데이터베이스·VPC 엔드포인트 없음. ClickHouse Cloud: 실습 데이터베이스 삭제, 서비스 크기 원복 요청(레플리카당 8–120 GiB, 앞단 r6gd.large). 앞단의 pg_clickhouse는 0.10 그대로.
비용: 태그 `purpose=aurora-analytics-t4g-test`의 Cost Explorer, 2026-10-10에 확인 예정.
