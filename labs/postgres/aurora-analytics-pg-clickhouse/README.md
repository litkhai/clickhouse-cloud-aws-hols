# Aurora PostgreSQL `aurora_analytics` on db.t4g — and pg_clickhouse at a similar size

> **Not run end to end yet.** Prepared 2026-10-09. Run on 2026-10-09: `deploy.sh` (apply, AWS
> provider 5.100.0), then stage 0 only on A (db.t4g.medium) and B (db.t4g.large), Aurora PostgreSQL 18.6,
> `aurora_analytics` 1.0.0, ap-northeast-2: the extension installs, a Parquet foreign table infers its
> schema, and `count(*)` over SF1 `store_sales` returns 2,880,404 rows on both. Default `query_mem` 466,979 kB (A)
> and 977,187 kB (B). Also run: the local SF1 rehearsal in [local/](local/) (Docker only, `local/REHEARSAL.md`).
> Not run yet: correctness over all 103 queries, SF100, C–E, P on ClickHouse Cloud, interference, `destroy.sh`.
> The run is tracked in [#43](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/43).
>
> **아직 끝까지 실행하지 않음.** 2026-10-09 준비. 2026-10-09 실행: `deploy.sh`(apply, AWS provider 5.100.0),
> 이어서 A(db.t4g.medium)·B(db.t4g.large)에서 단계 0만, Aurora PostgreSQL 18.6, `aurora_analytics` 1.0.0, 서울:
> 확장 설치, Parquet 외래 테이블 스키마 추론, SF1 `store_sales` `count(*)` = 2,880,404행이 둘 다 됨. 기본
> `query_mem`은 466,979 kB(A), 977,187 kB(B). 그 밖에 [local/](local/)의 SF1 로컬 리허설(Docker만, `local/REHEARSAL.md`).
> 아직 안 한 것: 103개 질의 정확성, SF100, C–E, ClickHouse Cloud의 P, 간섭, `destroy.sh`.
> 실제 실행은 [#43](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/43)에서 추적.

[English](#english) | [한국어](#한국어)

## English

Aurora PostgreSQL 17.11+ / 18.6+ ships the `aurora_analytics` extension: an embedded DuckDB engine
that reads Parquet and Iceberg in S3 through read-only foreign tables. AWS documents engine
versions but **no list of instance classes** (read 2026-10-09). This lab answers, with
TPC-DS-derived data and the same query text everywhere:

1. Does it work on the burstable **db.t4g.medium / db.t4g.large**, and how far does it go — correctness
   against a local DuckDB, SF100 completion, out-of-memory / spill / timeout, CPU credits, and the effect
   on OLTP latency on the same instance?
2. What do the same queries do when a PostgreSQL front end of a similar size sends them through
   **pg_clickhouse** to a **ClickHouse Cloud** service of a similar size?

The test plan — questions, targets, rules, report template — is [PLAN.md](PLAN.md) (Korean).

### Targets

| ID | What | Memory |
|---|---|---|
| A | Aurora db.t4g.medium + `aurora_analytics` | 4 GiB |
| B | Aurora db.t4g.large + `aurora_analytics` | 8 GiB |
| C | Aurora Serverless v2, 0.5–8 ACU | variable |
| D | Aurora db.r8g.large (EBS) | 16 GiB |
| E (optional) | Aurora db.r8gd.xlarge (NVMe) — `db.r8gd.large` is not orderable in ap-northeast-2 | 32 GiB |
| P | PostgreSQL 18 front end, ClickHouse Managed Postgres r6gd.large (2 vCPU · 16 GiB: same vCPU as db.t4g.large, twice the memory — the resize API accepted m6gd.large but did not apply it, 2026-10-09) + pg_clickhouse → ClickHouse Cloud, 8 GiB per replica, data in MergeTree | 16 + 8 × 2 GiB |
| P-s3 (optional) | the same front end → ClickHouse S3-engine tables over the same Parquet files | same |
| R | DuckDB 1.5.6 on the generator, over its local database file — the correct-answer reference; its times are not compared | — |

Same Parquet files, same 103 queries ([tpcds-scripts](https://github.com/litkhai/tpcds-scripts)
`engines/duckdb/queries`, pinned by commit; 101 are byte-identical to its PostgreSQL dialect and two
add an alias fix that is valid PostgreSQL), same order, 600 s timeout, concurrency 1.

### Architecture

```
 generator EC2 (m7g.4xlarge, public subnet)          ClickHouse Cloud, ap-northeast-2
   DuckDB dsdgen ─► S3 Parquet (SSE-S3) ◄──────────── s3() load into MergeTree (IAM role)
   psql / pgbench / run.py                              ▲ TLS 9440 (pg_clickhouse, binary)
        │ 5432 (private)          │ TLS 5432             │
        ▼                         ▼                      │
 Aurora PostgreSQL 18.6        Managed Postgres 18 ──────┘
 (private subnets, one         (P front end)
  instance, class = target)
   aurora_analytics ─► S3 gateway endpoint ─► the same Parquet
```

Terraform creates the VPC (one public, two private subnets, S3 gateway endpoint, no NAT), the
bucket, the IAM roles (Aurora `AuroraAnalytics` feature; an optional read role for ClickHouse Cloud),
the cluster parameter group with `aurora_analytics.enabled = true`, the Aurora cluster with one
instance, and the generator EC2. The ClickHouse Cloud services are not created by Terraform. A
self-managed EC2 front end (t4g + the `ghcr.io/clickhouse/pg_clickhouse` image) is available with
`create_pgfront = true`.

### Run it

Read [PLAN.md](PLAN.md) §8 (budget, safety) first. Every step writes its log under `out/` (gitignored).

```bash
cp terraform.tfvars.example terraform.tfvars    # owner, ttl, allowed_cidr_blocks
./deploy.sh                                     # preflight (orderable?), apply, writes config.env
./deploy.sh --class db.t4g.large                # next target: same cluster, new class
```

Then fill the `CH_*` and `PGFRONT_*` lines of `config.env`, copy the lab to the generator and run,
in order (each stage only after the previous one passed):

| Step | Script | Plan stage |
|---|---|---|
| Generate SF1 / SF100 to S3 (and R's database) | `01-generate.sh --sf N` | §4 |
| Fetch the pinned query set | `02-queries.sh` | §5 stage 1 |
| Extension, foreign tables, stage 0 checks | `10-aurora-setup.sh --sf N` | stage 0 (Q1) |
| Load ClickHouse Cloud from the same files | `20-clickhouse-load.sh --sf N [--s3-tables]` | P |
| pg_clickhouse server and foreign schema | `21-pgfront-setup.sh --sf N` | P |
| Correctness, SF1 | `run.py --phase correctness`, `compare.py --sf 1` | stage 1 (Q2) |
| Scale, SF100 | `run.py --phase scale` | stage 2 (Q3, Q4, Q6) |

`run.py` and `compare.py` run as `uv run --python 3.12 --with 'psycopg[binary]' --with duckdb==1.5.6 run.py …`:
Amazon Linux 2023 ships Python 3.9 and `duckdb` 1.5.6 needs 3.10 or later.

Interference (stage 3), the CloudWatch export and the §9 report are listed in
[#43](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/43).

```bash
./destroy.sh        # asks you to type the bucket name: the Parquet data goes with it
```

Put ClickHouse Cloud services back to their recorded sizes afterwards.

### Rehearse locally

`local/rehearse.sh --sf 1` runs paths P and R at SF1 with Docker only (PostgreSQL 18 +
pg_clickhouse 0.11.0, ClickHouse server, DuckDB) and compares answers. No timings: a laptop says
nothing about t4g.

### Not part of this lab

An official TPC result. Figures from this lab are derived from TPC-DS and are not comparable to
published TPC-DS results.

---

## 한국어

Aurora PostgreSQL 17.11+ / 18.6+에는 `aurora_analytics` 확장이 들어 있습니다. S3의 Parquet·Iceberg를
읽기 전용 외래 테이블로 읽는 내장 DuckDB 엔진입니다. AWS 문서는 엔진 버전만 적고 **인스턴스 클래스
목록은 없습니다**(2026-10-09 확인). 이 실습은 TPC-DS 파생 데이터와 모든 대상에 같은 질의 문구로
다음을 확인합니다.

1. 버스터블 **db.t4g.medium·db.t4g.large**에서 동작하는가, 어디까지 쓸 만한가 — 로컬 DuckDB 대비
   정확성, SF100 완료율, 메모리 부족·넘침·시간 초과, CPU 크레딧, 같은 인스턴스의 OLTP 지연 영향.
2. 비슷한 크기의 PostgreSQL 앞단이 같은 질의를 **pg_clickhouse**로 비슷한 크기의 **ClickHouse Cloud**에
   보내면 어떻게 되는가.

질문·대상·규칙·결과 양식은 [PLAN.md](PLAN.md)에 있습니다.

### 대상

| ID | 내용 | 메모리 |
|---|---|---|
| A | Aurora db.t4g.medium + `aurora_analytics` | 4 GiB |
| B | Aurora db.t4g.large + `aurora_analytics` | 8 GiB |
| C | Aurora Serverless v2, 0.5–8 ACU | 가변 |
| D | Aurora db.r8g.large(EBS) | 16 GiB |
| E (선택) | Aurora db.r8gd.xlarge(NVMe) — 서울에서 `db.r8gd.large`는 주문 불가 | 32 GiB |
| P | PostgreSQL 18 앞단 ClickHouse Managed Postgres r6gd.large(2 vCPU · 16 GiB: vCPU는 db.t4g.large와 같고 메모리는 두 배 — 크기 변경 API가 m6gd.large를 받고도 적용하지 않음, 2026-10-09) + pg_clickhouse → ClickHouse Cloud 레플리카당 8 GiB, 데이터는 MergeTree | 16 + 8 × 2 GiB |
| P-s3 (선택) | 같은 앞단 → 같은 Parquet 위의 ClickHouse S3 엔진 테이블 | 같음 |
| R | 생성 머신의 DuckDB 1.5.6, 로컬 데이터베이스 파일 — 정답 기준이며 시간은 비교하지 않음 | — |

같은 Parquet 파일, 같은 질의 103개([tpcds-scripts](https://github.com/litkhai/tpcds-scripts)
`engines/duckdb/queries`, 커밋 고정. 101개는 그 저장소의 PostgreSQL 방언과 글자까지 같고 두 개는
PostgreSQL에서도 유효한 별칭 수정), 같은 순서, 600초 제한, 동시성 1.

### 구성

```
 생성 EC2 (m7g.4xlarge, 퍼블릭 서브넷)                ClickHouse Cloud, ap-northeast-2
   DuckDB dsdgen ─► S3 Parquet (SSE-S3) ◄──────────── s3()로 MergeTree 적재 (IAM 역할)
   psql / pgbench / run.py                              ▲ TLS 9440 (pg_clickhouse, binary)
        │ 5432 (프라이빗)          │ TLS 5432            │
        ▼                         ▼                      │
 Aurora PostgreSQL 18.6        Managed Postgres 18 ──────┘
 (프라이빗 서브넷, 인스턴스     (P 앞단)
  하나, 클래스 = 대상)
   aurora_analytics ─► S3 게이트웨이 엔드포인트 ─► 같은 Parquet
```

Terraform은 VPC(퍼블릭 1·프라이빗 2 서브넷, S3 게이트웨이 엔드포인트, NAT 없음), 버킷, IAM 역할(Aurora
`AuroraAnalytics` 기능, ClickHouse Cloud용 읽기 역할은 선택), `aurora_analytics.enabled = true`인 클러스터
파라미터 그룹, 인스턴스 하나짜리 Aurora 클러스터, 생성 EC2를 만듭니다. ClickHouse Cloud 서비스는
Terraform이 만들지 않습니다. `create_pgfront = true`면 직접 운영하는 EC2 앞단(t4g +
`ghcr.io/clickhouse/pg_clickhouse` 이미지)을 쓸 수 있습니다.

### 실행

먼저 [PLAN.md](PLAN.md) §8(예산·안전)을 읽으세요. 모든 단계의 로그는 `out/`(git 제외)에 남습니다.

```bash
cp terraform.tfvars.example terraform.tfvars    # owner, ttl, allowed_cidr_blocks
./deploy.sh                                     # 사전 확인(주문 가능?), apply, config.env 작성
./deploy.sh --class db.t4g.large                # 다음 대상: 같은 클러스터, 클래스만 바꿈
```

그다음 `config.env`의 `CH_*`·`PGFRONT_*` 줄을 채우고 실습을 생성 머신에 복사해 순서대로 실행합니다
(앞 단계를 통과해야 다음 단계).

| 단계 | 스크립트 | 계획 단계 |
|---|---|---|
| SF1·SF100 생성 → S3(R의 데이터베이스 포함) | `01-generate.sh --sf N` | §4 |
| 고정된 질의 세트 받기 | `02-queries.sh` | §5 단계 1 |
| 확장, 외래 테이블, 단계 0 확인 | `10-aurora-setup.sh --sf N` | 단계 0 (Q1) |
| 같은 파일로 ClickHouse Cloud 적재 | `20-clickhouse-load.sh --sf N [--s3-tables]` | P |
| pg_clickhouse 서버와 외래 스키마 | `21-pgfront-setup.sh --sf N` | P |
| 정확성, SF1 | `run.py --phase correctness`, `compare.py --sf 1` | 단계 1 (Q2) |
| 규모, SF100 | `run.py --phase scale` | 단계 2 (Q3, Q4, Q6) |

`run.py`·`compare.py`는 `uv run --python 3.12 --with 'psycopg[binary]' --with duckdb==1.5.6 run.py …`로 실행합니다.
Amazon Linux 2023의 Python은 3.9이고 `duckdb` 1.5.6은 3.10 이상이 필요합니다.

간섭(단계 3), CloudWatch 내보내기, §9 결과 문서는
[#43](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/43)에 적혀 있습니다.

```bash
./destroy.sh        # 버킷 이름을 입력해야 진행: Parquet 데이터도 함께 지워짐
```

끝나면 ClickHouse Cloud 서비스를 기록해 둔 원래 크기로 되돌리세요.

### 로컬 리허설

`local/rehearse.sh --sf 1`은 Docker만으로(PostgreSQL 18 + pg_clickhouse 0.11.0, ClickHouse 서버,
DuckDB) P와 R 경로를 SF1로 돌리고 답을 비교합니다. 시간은 재지 않습니다. 노트북 수치는 t4g에 대해
아무것도 말해 주지 않습니다.

### 이 실습이 아닌 것

공식 TPC 결과. 이 실습의 수치는 TPC-DS에서 파생했으며 공표된 TPC-DS 결과와 비교할 수 없습니다.
