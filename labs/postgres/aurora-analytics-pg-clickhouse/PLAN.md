# 시험 계획서: Aurora PostgreSQL `aurora_analytics`(내장 DuckDB) — 버스터블(db.t4g) 인스턴스 적합성

> 작성 2026-10-09 · 목적 중립 · 실행 담당: 별도 에이전트 · 결과는 이 문서의 §9 양식으로
>
> **2026-10-09 개정**: pg_clickhouse 경로(P) 추가(§1 Q6, §3, §5 단계 2·3), 쿼리 원본을 tpcds-scripts로 고정(§5 단계 1), 같은 날 읽기 전용 API로 확인한 사실 반영(§2), 엔진 18.6, E는 db.r8gd.xlarge, SF100 실패 질의는 따뜻한 실행 생략(§5 단계 2). 스크립트와 실행법은 [README.md](README.md).
>
> 이 문서는 특정 제품·고객 데이터와 무관하다. 데이터는 TPC-DS·TPC-H 생성기로만 만든다.

## 1. 목적과 질문

**주 목적**: Amazon Aurora PostgreSQL의 `aurora_analytics` 확장(S3의 Parquet/Iceberg를 외래 테이블로 읽는 내장 DuckDB 엔진)이
**버스터블 인스턴스 db.t4g.medium·db.t4g.large에서 동작하는지, 어디까지 쓸 만한지**를 확인한다.

답할 질문:

1. **Q1 가능 여부**: db.t4g.medium·db.t4g.large에서 확장을 켜고 외래 테이블을 조회할 수 있는가? (예/아니오, 오류 원문)
2. **Q2 기능 정확성**: 같은 질의가 기준(로컬 DuckDB)과 같은 결과를 내는가?
3. **Q3 규모 한계**: TPC-DS SF100(약 100 GB)에서 몇 개 질의가 끝나고, 몇 개가 메모리 취소·디스크 넘침·시간 초과로 실패하는가?
4. **Q4 성능·비용**: 같은 질의를 비교 인스턴스(Serverless v2, db.r8g.large, 선택: db.r8gd.large)와 비교한 시간·비용, t4g CPU 크레딧 소모.
5. **Q5 간섭**: 분석 질의가 같은 인스턴스의 일반 OLTP 질의 지연에 주는 영향.
6. **Q6 비슷한 크기의 다른 경로**: 같은 질의를 PostgreSQL 앞단(2 vCPU) + pg_clickhouse → ClickHouse Cloud(레플리카당 8 GiB)로 보냈을 때의 완료율·시간·비용·간섭. 분석 실행이 PostgreSQL 인스턴스 밖에서 일어나는 구조라는 차이를 그대로 기록한다.

비목적: 공식 TPC 결과 산출, 엔진 간 우열 홍보.

## 2. 확인된 사실 (2026-10-09, 출처 기록)

- 지원 버전: Aurora PostgreSQL **17.11 이상**, **18.6 이상**. 확장 `aurora_analytics`, 파라미터 `aurora_analytics.enabled`(클러스터 파라미터 그룹, 동적), IAM 역할 기능 이름 `AuroraAnalytics`, private 서브넷이면 S3 게이트웨이 엔드포인트. — AWS Aurora 사용 설명서 "Prerequisites", "Tutorial: Querying Amazon S3 data"
- 문법: `CREATE FOREIGN TABLE t () SERVER aurora_analytics_server OPTIONS (location 's3://…/', format 'parquet' | 'iceberg', region '…')`. 빈 열 목록이면 스키마 추론. 읽기 전용. — "Working with foreign tables"
- DuckDB 함수(`read_parquet()` 등)를 직접 부를 수 없다(외래 테이블로만). — Franck Pachot, DEV Community 비교 글
- 메모리: `aurora_analytics.query_mem`(기본값은 인스턴스 메모리에서 결정), 상한 ≈ 인스턴스 메모리 − `shared_buffers`(기본 약 2/3). 메모리 압박 시 질의 취소 `ERROR: [Aurora Analytics] Out of Memory Error`. 넘침은 로컬 저장(NVMe 또는 EBS). — "Resource management"
- 지표: CloudWatch `AuroraAnalyticsMemoryUsage`, `AuroraAnalyticsDiskSpillSize`, `AuroraAnalyticsCacheHitRatio`, `AuroraAnalyticsActiveThreads`; 함수 `aurora_analytics_cache_size()`, `aurora_analytics_clear_cache()`, `aurora_analytics_stat_statements()`; 대기 이벤트 `Extension:AuroraAnalyticsExecute`.
- Aurora PG 17은 db.t4g.medium·large를 지원(17.4+). **`aurora_analytics`가 t4g에서 되는지는 문서에 없다.** 공개 사례는 Serverless v2(17.11)와 db.r8gd.xlarge·2xlarge뿐.
- 서울(ap-northeast-2) 공시 단가(AWS Price List, 2026-10-06 게시본): db.t4g.medium $0.113/h · db.t4g.large $0.227/h · db.r7g.large $0.333/h, Serverless v2 $0.20/ACU-h, 저장 $0.12/GB-월, I/O $0.24/100만. 실행 전 Price List로 다시 확인하고 r8g·r8gd 단가도 뽑는다.

- **2026-10-09 읽기 전용 API 확인(서울)**: `describe-db-engine-versions` — 17.x는 17.11까지, 18.x는 18.3·18.4·18.6. `describe-orderable-db-instance-options` — 17.11·18.6 모두 db.t4g.medium·db.t4g.large·db.serverless·db.r8g.large 주문 가능, **db.r8gd.large는 0건**, d계열 최소는 db.r8gd.xlarge(그리고 db.r6gd.xlarge). 주문 가능은 확장 동작을 뜻하지 않는다(Q1).
- pg_clickhouse 최신 v0.11.0(2026-09-30, GitHub releases), PostgreSQL 14+. ClickHouse Cloud 서버를 host로 주면 binary 드라이버가 TLS 9440을 기본으로 쓴다(v0.11.0 참조 문서). ClickHouse Cloud API: 레플리카 메모리 최소 8 GiB·4의 배수, 웨어하우스의 첫 서비스는 레플리카 2개 이상(OpenAPI, 2026-10-09).
- EC2 사양(`describe-instance-types`): t4g.medium 2 vCPU·4 GiB, t4g.large 2 vCPU·8 GiB, m6gd.large 2 vCPU·8 GiB, r6gd.large 2 vCPU·16 GiB.

**실행 전 다시 확인할 것**: 위 문서의 현재판(바뀌었으면 차이를 §9에 기록), Aurora 엔진 최신 마이너, `describe-orderable-db-instance-options` 결과.

## 3. 환경

| 항목 | 값 |
|---|---|
| 리전 | ap-northeast-2(서울), 모든 자원 같은 AZ 우선 |
| 엔진 | Aurora PostgreSQL **18.6**(P 앞단 PostgreSQL 18과 메이저를 맞춤; 정확한 버전 기록), 단일 인스턴스 클러스터 |
| 저장 구성 | Aurora Standard와 I/O-Optimized 중 **Standard**(비용 계산은 둘 다) |
| 데이터 | S3 버킷 1개(같은 리전), SSE-S3, 게이트웨이 엔드포인트 |
| 생성·기준 머신 | EC2 m7g.4xlarge(16 vCPU · 64 GiB) + gp3 500 GB(일시), DuckDB CLI 1.5.6 |
| 클라이언트 | 생성 머신에서 psql·pgbench(Aurora는 같은 VPC, P 앞단은 TLS로 인터넷 경유) |
| 태그 | 모든 자원에 `purpose=aurora-analytics-t4g-test`, `owner=<담당>`, `ttl=<날짜>` |

### 비교 대상 (질의·데이터·설정 동일)

| ID | 인스턴스 | 메모리 | 역할 |
|---|---|---|---|
| A | db.t4g.medium | 4 GiB | 주 대상 |
| B | db.t4g.large | 8 GiB | 주 대상 |
| C | Serverless v2, 0.5–8 ACU | 가변 | 공개 사례가 있는 기준 |
| D | db.r8g.large(EBS 전용) | 16 GiB | 비버스터블 기준 |
| E (선택) | db.r8gd.xlarge(NVMe) | 32 GiB | 권장 계열 기준 — r8gd.large는 서울에서 주문 불가(2026-10-09). 크기가 다르므로 비교 시 명시 |
| P | ClickHouse Managed Postgres 18, m6gd.large(2 vCPU · 8 GiB)로 변경 요청. 2026-10-09 실행에서는 변경이 늦게 적용돼 실행 중 크기가 r6gd.large(16 GiB)인지 m6gd.large인지 모름 — RESULTS.md + pg_clickhouse → ClickHouse Cloud(레플리카당 8 GiB 고정, 레플리카 2) | 16 GiB + 8 GiB×2 | 비슷한 크기의 다른 경로. 데이터는 같은 Parquet를 MergeTree로 적재(적재 시간·비용 포함) |
| P-s3 (선택) | P와 같은 앞단 → ClickHouse S3 엔진 테이블(같은 Parquet를 그 자리에서 읽음) | 〃 | 적재 없이 같은 파일을 읽는 경우 |
| R | 생성 머신의 DuckDB(로컬 파일) | — | 결과 정답·참고 시간 |

A가 Q1에서 실패하면 A는 거기서 끝내고 나머지를 진행한다.

## 4. 데이터

### 4.1 생성
- **TPC-DS SF1**(기능 확인용)과 **TPC-DS SF100**(규모 확인용), 선택으로 **TPC-H SF10**.
- 생성기: DuckDB `tpcds`·`tpch` 확장(`CALL dsdgen(sf=100)`, `CALL dbgen(sf=10)`)을 **디스크 기반 DuckDB 파일**에서. 메모리가 부족하면 `SET memory_limit`, `SET temp_directory`.
- Parquet 쓰기: 표마다 `COPY (SELECT * FROM <표>) TO 's3://<버킷>/tpcds/sf100/<표>/' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE 122880, FILE_SIZE_BYTES '256MB')` — 파일 128–512 MB(AWS 권장: 작은 파일 피하기). 사실 표(`store_sales` 등)는 날짜 키 순으로 정렬해 쓴다.
- 기록: 표별 행 수, 파일 수, 총 바이트, 생성 시간, DuckDB 버전. 행 수는 TPC-DS 명세의 SF100 값과 맞춰 본다.

### 4.2 외래 테이블
- 각 대상(A–E)에서 24개 표를 `CREATE FOREIGN TABLE <표> () SERVER aurora_analytics_server OPTIONS (location 's3://…/<표>/', format 'parquet')`(스키마 추론). 추론된 형식을 `\d`로 저장해 대상 간 비교.
- 형식이 추론과 TPC-DS 명세가 다르면(예: 소수 자릿수) 그대로 두고 기록(질의 결과 비교에서 걸러짐).

## 5. 시험 절차

각 단계는 **앞 단계 통과 뒤에만** 진행한다. 모든 단계에서 정확한 명령·출력을 로그로 남긴다.

### 단계 0 — 가능 여부 (Q1, 대상당 30분 이내)
1. `aws rds describe-orderable-db-instance-options --engine aurora-postgresql --engine-version <버전> --db-instance-class <클래스>` 저장.
2. 클러스터·인스턴스 생성(커스텀 클러스터 파라미터 그룹, `aurora_analytics.enabled=true`), IAM 역할 연결(`AuroraAnalytics`).
3. `CREATE EXTENSION aurora_analytics;` → `SELECT extname, extversion FROM pg_extension;` → `SELECT srvname FROM pg_foreign_server;`
4. SF1 `store_sales` 외래 테이블 → `SELECT count(*)`, `EXPLAIN ANALYZE` 저장(분석 엔진으로 내려갔는지).
5. 기본값 기록: `SHOW aurora_analytics.query_mem; SHOW shared_buffers;`, `aurora_analytics_cache_size()`.
- **판정**: 3·4가 되면 통과. 오류면 원문·단계·인스턴스 ID 기록 후 그 대상 종료.

### 단계 1 — 기능 정확성 (Q2, SF1)
- TPC-DS 파생 질의 103개(99개, 14·23·24·39는 두 형태): [tpcds-scripts](https://github.com/litkhai/tpcds-scripts) `engines/duckdb/queries`를 커밋으로 고정해 사용. 101개는 같은 저장소의 PostgreSQL 방언 질의와 글자 하나 다르지 않고, q77·q90은 별칭에 `as`/따옴표를 더한 것으로 PostgreSQL에서도 유효하다(DuckDB 1.5.6·PostgreSQL 16 픽스처로 확인, 2026-10-09). 이것이 아래의 "최소 수정 1벌"의 출발점이다.
- 각 대상에서 1회 실행, 결과를 정렬해 행 수·열별 합계(숫자 열)·해시로 R과 비교.
- PostgreSQL 문법 차이로 실패하는 질의는 **최소 수정 1벌**을 만들어 모든 대상(R 포함)에 같게 적용하고 수정 내역을 질의 번호별로 기록. 수정 후에도 실패하면 "미지원"으로 분류.
- 분류: 성공·결과 일치 / 성공·결과 불일치 / 문법 실패 / 실행 오류(원문).

### 단계 2 — 규모 (Q3·Q4, SF100)
- 단계 1에서 결과가 일치한 질의 집합만 사용.
- 실행 규칙:
  - 세션 `statement_timeout = 600s`(10분). 넘으면 "시간 초과".
  - **차가운 실행 1회**: 인스턴스 재시작 또는 `aurora_analytics_clear_cache()` 뒤.
  - **따뜻한 실행 3회**: 연속, 중앙값 보고. 차가운 실행이 실패(시간 초과·OOM·넘침·오류)한 질의는 따뜻한 실행을 생략하고 `skipped`로 기록(대상당 최악 103 × 4 × 600초를 막는 예산 상한).
  - 질의 사이 5초 쉼, 한 번에 한 질의(동시성 1).
- 질의마다 기록: 시작·끝 시각, 경과 시간, 성공·실패 종류(OOM 취소 / 넘침 공간 부족 / 시간 초과 / 기타), `aurora_analytics_stat_statements()`의 캐시 적중·S3 읽기 바이트.
- 1분 간격 CloudWatch: CPUUtilization, FreeableMemory, `AuroraAnalytics*` 4종, ReadIOPS·WriteIOPS, VolumeReadIOPs, **t4g는 CPUCreditBalance·CPUCreditUsage·CPUSurplusCreditBalance·CPUSurplusCreditsCharged**.
- **2-b 같은 조건의 조정 실행(선택)**: `shared_buffers`를 줄이고 `query_mem`을 올린 설정 1벌(값은 대상별로 문서 권장 방향에 따라 정하고 모두 기록)을 실패율이 높은 대상에만. 기본 실행과 따로 보고.

P는 같은 규칙으로 실행하고, 차가운 실행 전 ClickHouse가 받아 주는 캐시 비우기(`SYSTEM DROP …`)를 하고 거부된 것은 기록한다. 질의마다 `EXPLAIN (VERBOSE)`로 전부 내려갔는지(full/partial) 기록한다.

### 단계 3 — 간섭 (Q5, A·B 중 통과한 것과 D, 그리고 P 앞단)
- 같은 인스턴스에 pgbench(스케일 50, 클라이언트 8, 읽기·쓰기 기본 스크립트) 10분 기준선 → 같은 10분 동안 SF100 질의 중 무거운 5개를 반복 실행.
- 기록: pgbench TPS·지연 p50·p95(기준선 대비), 분석 질의 시간, CPU 크레딧 변화.

### 단계 4 — 정리
- 모든 클러스터·인스턴스·스냅샷·파라미터 그룹·IAM 역할·엔드포인트·EC2·EBS 삭제, S3 데이터는 결과 확정 뒤 삭제(또는 보관 결정 기록).
- Cost Explorer에서 태그별 실제 비용(하루 지연 감안해 다음 날 확인).

## 6. 측정 정의

| 지표 | 정의 |
|---|---|
| 완료율 | 단계 2 질의 중 시간 안에 성공한 비율 |
| 질의 시간 | 클라이언트에서 잰 경과 시간(초), 따뜻한 3회 중앙값 |
| 기하평균 | 완료된 공통 질의 집합의 기하평균(대상 간 비교는 **모든 대상이 끝낸 질의만**) |
| 실패 유형 | OOM 취소 · 넘침 공간 부족 · 시간 초과 · 문법 · 기타 |
| 크레딧 | 단계 2 동안 CPUCreditBalance 최소값, 초과 크레딧 과금량 |
| 비용 | (인스턴스 단가 × 시간) + 초과 크레딧 + S3 요청·저장 + I/O, 질의 집합 1회당 |

## 7. 중립성 규칙

- 모든 대상에 **같은 데이터 파일·같은 질의 문구·같은 순서·같은 시간 제한**. 기본 실행에서 대상별 튜닝 금지.
- 질의 수정은 1벌만, 모든 대상 공통. 수정은 문법 맞춤에 한하고 의미를 바꾸지 않는다.
- R(로컬 DuckDB)은 정답·참고용이며 Aurora와 시간 비교 결론을 내지 않는다.
- 결과에 불리한 것도 그대로 기록. 재시도는 원인(예: 일시적 S3 오류)을 기록한 경우에만 1회.
- 공표 시 TPC 공정 사용 규칙에 따라 "TPC-DS에서 파생, 공식 TPC 결과와 비교할 수 없음"을 명시.

## 8. 안전·예산

- **결제 승인 후에만 시작.** P 경로(ClickHouse Cloud 서비스·Managed Postgres)는 이미 있는 서비스를 크기만 맞춰 쓰고, 시험 전 크기를 기록해 끝나면 되돌린다. 그 비용은 Usage Cost API(이 저장소 `labs/billing/usage-cost`)로 시험 시간대만 따로 본다.
- 예산 상한(Aurora 쪽) **$60**(예상: 생성 EC2 수 시간 + Aurora 대상 5개 각 2–4시간 + S3 약 30 GB). AWS Budgets 경보 $30·$50, 태그 필터.
- 각 대상은 단계가 끝나면 즉시 삭제(다음 대상을 기다리며 켜 두지 않음). 작업 중단 시 정리 스크립트부터.
- 자격 증명은 저장소·로그·결과에 남기지 않는다. 데이터는 생성 데이터만(고객 데이터 금지).
- 퍼블릭 접근 없음(private 서브넷, 보안 그룹은 생성 머신만 허용).

## 9. 결과 보고 양식

```
# 결과: aurora_analytics on t4g — <날짜>

## 환경
- 엔진 버전: … / extversion: … / 리전·AZ: …
- 대상별 인스턴스 ID·클래스·시작·종료 시각
- DuckDB(생성·R) 버전: …
- 문서·단가 재확인 결과와 계획 대비 차이: …

## Q1 가능 여부
| 대상 | orderable | CREATE EXTENSION | SF1 조회 | 오류 원문 |

## Q2 정확성 (SF1, 99개)
| 대상 | 일치 | 불일치 | 문법 실패 | 실행 오류 | 수정한 질의 번호 |

## Q3·Q4 규모 (SF100)
| 대상 | 완료율 | OOM | 넘침 | 시간 초과 | 공통 집합 기하평균(따뜻) | 차가운 실행 합계 | 크레딧 최소·초과 과금 | 1회당 비용 |
(질의별 원자료는 CSV 첨부: 대상, 질의, 실행 종류, 초, 결과, 캐시 적중 바이트, S3 읽기 바이트)

## Q5 간섭
| 대상 | pgbench TPS 기준/동시 | p95 기준/동시 | 분석 질의 시간 |

## Q6 pg_clickhouse 경로 (P, P-s3)
| 대상 | 적재 시간 | 완료율 | 전부 내려감(full) 질의 수 | 공통 집합 기하평균(따뜻) | 1회당 비용 |

## 결론 (사실만)
- t4g.medium: 가능/불가, 쓸 수 있는 범위(데이터 크기·질의 종류)
- t4g.large: 같은 항목
- 관찰한 한계·주의점, 미확인으로 남은 것

## 실제 비용
| 자원 | 시간 | 금액 |
```

## 10. 산출물
- 이 계획서에 따른 결과 문서(§9), 질의별 CSV, CloudWatch 지표 내보내기(CSV), 실행 스크립트(생성·외래 테이블·실행·정리), 수정한 질의 1벌과 수정 내역, 사용한 명령 로그.
