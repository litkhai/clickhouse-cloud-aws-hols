# ClickHouse Cloud on AWS — Labs

[English](#english) | [한국어](#한국어)

## English

Terraform labs that stand up AWS-side infrastructure for ClickHouse Cloud — Confluent Kafka, MinIO and Glue data lakes, and secure S3 access — and a billing lab that reads the Usage Cost API and creates nothing, and a Postgres lab on Aurora's embedded DuckDB and pg_clickhouse.

> This repository was split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols) on the `pre-split-2026-10` tag, with history. The last version of these labs in the original repository: https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10

These labs are kept, not archived, but most have not been re-run since late 2025. Each lab README opens with a **last-verified banner** that also lists what was not checked; read it before you `apply`. ⚠️ marks a lab whose last run on ClickHouse Cloud failed.

### 📨 Kafka (`labs/kafka/`)

| Lab | What it covers | Last run |
|-----|----------------|----------|
| [labs/kafka/terraform-confluent-aws](labs/kafka/terraform-confluent-aws/) | Confluent Platform on AWS with Terraform | 2025-11-20 |
| [labs/kafka/terraform-confluent-aws-nlb-ssl](labs/kafka/terraform-confluent-aws-nlb-ssl/) | Confluent with NLB SSL termination | 2025-11-20 |
| [labs/kafka/terraform-confluent-aws-connect-sink](labs/kafka/terraform-confluent-aws-connect-sink/) | Confluent with the ClickHouse sink connector | 2025-11-24 |

### 🏞 Lake (`labs/lake/`)

| Lab | What it covers | Last run |
|-----|----------------|----------|
| [labs/lake/terraform-minio-on-aws](labs/lake/terraform-minio-on-aws/) | MinIO on AWS via Terraform | 2025-11-16 |
| [labs/lake/terraform-glue-s3-chc-integration](labs/lake/terraform-glue-s3-chc-integration/) | ClickHouse Cloud with the AWS Glue catalog | 2025-11-17 |

### 🪣 S3 (`labs/s3/`)

| Lab | What it covers | Last run |
|-----|----------------|----------|
| [labs/s3/terraform-chc-secures3-aws](labs/s3/terraform-chc-secures3-aws/) | Secure S3 integration with Terraform | 2025-11-30 |
| [labs/s3/terraform-chc-secures3-aws-direct-attach](labs/s3/terraform-chc-secures3-aws-direct-attach/) | S3 integration via direct bucket policy access | 2025-12-05 ⚠️ |

### 💳 Billing (`labs/billing/`)

| Lab | What it covers | Last run |
|-----|----------------|----------|
| [labs/billing/usage-cost](labs/billing/usage-cost/) | Usage Cost API: what the `service`, `datawarehouse` and `clickpipe` items bill, and an allocation per database and user | 2026-10-02 |

### 🐘 Postgres (`labs/postgres/`)

| Lab | What it covers | Last run |
|-----|----------------|----------|
| [labs/postgres/aurora-analytics-pg-clickhouse](labs/postgres/aurora-analytics-pg-clickhouse/) | Aurora PostgreSQL `aurora_analytics` (embedded DuckDB) on db.t4g, and pg_clickhouse → ClickHouse Cloud at a similar size, TPC-DS-derived SF1 / SF10 / SF100, Glue + Iceberg | 2026-10-09 (partial: SF1, SF10, SF100, SF10 on Glue + Iceberg; targets A, B, E, P) |

### 🔗 Related repositories

| Repository | What it is |
|---|---|
| [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols) | Core ClickHouse hands-on labs |

### ✅ Repository checks

Current state and what still needs a re-run: [STATUS.md](STATUS.md).

```bash
git config core.hooksPath .githooks
python3 .github/scripts/check_links.py
./.github/scripts/check_syntax.sh
python3 tools/labs_json.py --check
```

`docs/labs.json` lists the labs whose `lab.yaml` sets `web: true`, for the notes site, which
fetches it from `main`. Keys and categories: [`tools/lab.schema.md`](tools/lab.schema.md).
After changing a `lab.yaml`, run `python3 tools/labs_json.py` and commit the file.

### 📝 License

[MIT](LICENSE). Labs install ClickHouse and other software at run time under their own licences.

---

## 한국어

ClickHouse Cloud와 연동할 AWS 쪽 인프라를 Terraform으로 구성하는 실습(Confluent Kafka, MinIO·Glue 데이터 레이크, 보안 S3 접근)과, 아무것도 만들지 않고 Usage Cost API만 읽는 빌링 실습, Aurora 내장 DuckDB와 pg_clickhouse를 다루는 Postgres 실습입니다.

> 이 저장소는 [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols)의 `pre-split-2026-10` 태그 시점에서 히스토리와 함께 분리했습니다. 원래 저장소에 있던 마지막 버전: https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10

이 실습들은 archive하지 않고 유지하지만, 대부분 2025년 말 이후 다시 실행하지 않았습니다. 각 실습 README 맨 위의 **마지막 검증 배너**에는 확인하지 않은 것도 적혀 있으니 `apply` 전에 먼저 읽으세요. ⚠️는 마지막 ClickHouse Cloud 실행이 실패한 실습입니다.

### 📨 Kafka (`labs/kafka/`)

| 실습 | 내용 | 마지막 실행 |
|-----|----------------|----------|
| [labs/kafka/terraform-confluent-aws](labs/kafka/terraform-confluent-aws/) | Terraform으로 AWS에 Confluent Platform 구성 | 2025-11-20 |
| [labs/kafka/terraform-confluent-aws-nlb-ssl](labs/kafka/terraform-confluent-aws-nlb-ssl/) | NLB SSL 종료를 적용한 Confluent | 2025-11-20 |
| [labs/kafka/terraform-confluent-aws-connect-sink](labs/kafka/terraform-confluent-aws-connect-sink/) | ClickHouse Sink Connector 연동 | 2025-11-24 |

### 🏞 레이크 (`labs/lake/`)

| 실습 | 내용 | 마지막 실행 |
|-----|----------------|----------|
| [labs/lake/terraform-minio-on-aws](labs/lake/terraform-minio-on-aws/) | Terraform으로 AWS에 MinIO 구성 | 2025-11-16 |
| [labs/lake/terraform-glue-s3-chc-integration](labs/lake/terraform-glue-s3-chc-integration/) | ClickHouse Cloud + AWS Glue 카탈로그 | 2025-11-17 |

### 🪣 S3 (`labs/s3/`)

| 실습 | 내용 | 마지막 실행 |
|-----|----------------|----------|
| [labs/s3/terraform-chc-secures3-aws](labs/s3/terraform-chc-secures3-aws/) | Terraform 기반 보안 S3 통합 | 2025-11-30 |
| [labs/s3/terraform-chc-secures3-aws-direct-attach](labs/s3/terraform-chc-secures3-aws-direct-attach/) | 버킷 정책 직접 연결 방식 S3 통합 | 2025-12-05 ⚠️ |

### 💳 빌링 (`labs/billing/`)

| 실습 | 내용 | 마지막 실행 |
|-----|----------------|----------|
| [labs/billing/usage-cost](labs/billing/usage-cost/) | Usage Cost API: `service`·`datawarehouse`·`clickpipe` 항목이 무엇을 청구하는지, 데이터베이스·사용자별 배분 | 2026-10-02 |

### 🐘 Postgres (`labs/postgres/`)

| 실습 | 내용 | 마지막 실행 |
|-----|----------------|----------|
| [labs/postgres/aurora-analytics-pg-clickhouse](labs/postgres/aurora-analytics-pg-clickhouse/) | db.t4g에서 Aurora PostgreSQL `aurora_analytics`(내장 DuckDB), 비슷한 크기의 pg_clickhouse → ClickHouse Cloud, TPC-DS 파생 SF1·SF10·SF100, Glue + Iceberg | 2026-10-09 (일부: SF1, SF10, SF100, Glue + Iceberg 위 SF10; 대상 A·B·E·P) |

### 🔗 관련 저장소

| 저장소 | 설명 |
|---|---|
| [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols) | ClickHouse 핵심 실습 |

### ✅ 저장소 검사

현재 상태와 재실행이 필요한 항목: [STATUS.md](STATUS.md).

```bash
git config core.hooksPath .githooks
python3 .github/scripts/check_links.py
./.github/scripts/check_syntax.sh
python3 tools/labs_json.py --check
```

`docs/labs.json`에는 `lab.yaml`에 `web: true`가 있는 실습만 담기며, 노트 사이트가 `main`에서
가져갑니다. 키와 분류는 [`tools/lab.schema.md`](tools/lab.schema.md). `lab.yaml`을 바꾼 뒤
`python3 tools/labs_json.py`를 실행하고 그 파일을 커밋하세요.

### 📝 라이선스

[MIT](LICENSE). 실습이 실행 시점에 설치하는 소프트웨어는 각자의 라이선스를 따릅니다.
