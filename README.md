# ClickHouse Cloud on AWS — Terraform Labs

[English](#english) | [한국어](#한국어)

## English

Terraform labs that stand up AWS-side infrastructure for ClickHouse Cloud: Confluent Kafka, MinIO and Glue data lakes, and secure S3 access.

> This repository was split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols) on the `pre-split-2026-10` tag, with history. The last version of these labs in the original repository: https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10

These labs are kept, not archived, but most have not been re-run since late 2025. Each lab README opens with a **last-verified banner**; read it before you `apply`. ⚠️ marks a lab whose last run on ClickHouse Cloud failed.

### 📨 Kafka (`labs/kafka/`)

| Lab | What it covers  Last run |
|-----|----------------|----------|
| [labs/kafka/terraform-confluent-aws](labs/kafka/terraform-confluent-aws/) | Confluent Platform on AWS with Terraform | 2025-11-20 |
| [labs/kafka/terraform-confluent-aws-nlb-ssl](labs/kafka/terraform-confluent-aws-nlb-ssl/) | Confluent with NLB SSL termination | 2025-11-20 |
| [labs/kafka/terraform-confluent-aws-connect-sink](labs/kafka/terraform-confluent-aws-connect-sink/) | Confluent with the ClickHouse sink connector | 2025-11-24 |

### 🏞 Lake (`labs/lake/`)

| Lab | What it covers  Last run |
|-----|----------------|----------|
| [labs/lake/terraform-minio-on-aws](labs/lake/terraform-minio-on-aws/) | MinIO on AWS via Terraform | 2025-11-16 |
| [labs/lake/terraform-glue-s3-chc-integration](labs/lake/terraform-glue-s3-chc-integration/) | ClickHouse Cloud with the AWS Glue catalog | 2025-11-17 |

### 🪣 S3 (`labs/s3/`)

| Lab | What it covers  Last run |
|-----|----------------|----------|
| [labs/s3/terraform-chc-secures3-aws](labs/s3/terraform-chc-secures3-aws/) | Secure S3 integration with Terraform | 2025-11-30 |
| [labs/s3/terraform-chc-secures3-aws-direct-attach](labs/s3/terraform-chc-secures3-aws-direct-attach/) | S3 integration via direct bucket policy access | 2025-12-05 ⚠️ |

### 🔗 Related repositories

| Repository | What it is |
|---|---|
| [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols) | Core ClickHouse hands-on labs |

### ✅ Repository checks

```bash
git config core.hooksPath .githooks
python3 .github/scripts/check_links.py
./.github/scripts/check_syntax.sh
```

### 📝 License

[MIT](LICENSE). Labs install ClickHouse and other software at run time under their own licences.

---

## 한국어

ClickHouse Cloud와 연동할 AWS 쪽 인프라를 Terraform으로 구성하는 실습입니다. Confluent Kafka, MinIO·Glue 데이터 레이크, 보안 S3 접근을 다룹니다.

> 이 저장소는 [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols)의 `pre-split-2026-10` 태그 시점에서 히스토리와 함께 분리했습니다. 원래 저장소에 있던 마지막 버전: https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10

이 실습들은 archive하지 않고 유지하지만, 대부분 2025년 말 이후 다시 실행하지 않았습니다. 각 실습 README 맨 위의 **마지막 검증 배너**를 `apply` 전에 먼저 읽으세요. ⚠️는 마지막 ClickHouse Cloud 실행이 실패한 실습입니다.

### 📨 Kafka (`labs/kafka/`)

| 실습 | 내용  마지막 실행 |
|-----|----------------|----------|
| [labs/kafka/terraform-confluent-aws](labs/kafka/terraform-confluent-aws/) | Terraform으로 AWS에 Confluent Platform 구성 | 2025-11-20 |
| [labs/kafka/terraform-confluent-aws-nlb-ssl](labs/kafka/terraform-confluent-aws-nlb-ssl/) | NLB SSL 종료를 적용한 Confluent | 2025-11-20 |
| [labs/kafka/terraform-confluent-aws-connect-sink](labs/kafka/terraform-confluent-aws-connect-sink/) | ClickHouse Sink Connector 연동 | 2025-11-24 |

### 🏞 레이크 (`labs/lake/`)

| 실습 | 내용  마지막 실행 |
|-----|----------------|----------|
| [labs/lake/terraform-minio-on-aws](labs/lake/terraform-minio-on-aws/) | Terraform으로 AWS에 MinIO 구성 | 2025-11-16 |
| [labs/lake/terraform-glue-s3-chc-integration](labs/lake/terraform-glue-s3-chc-integration/) | ClickHouse Cloud + AWS Glue 카탈로그 | 2025-11-17 |

### 🪣 S3 (`labs/s3/`)

| 실습 | 내용  마지막 실행 |
|-----|----------------|----------|
| [labs/s3/terraform-chc-secures3-aws](labs/s3/terraform-chc-secures3-aws/) | Terraform 기반 보안 S3 통합 | 2025-11-30 |
| [labs/s3/terraform-chc-secures3-aws-direct-attach](labs/s3/terraform-chc-secures3-aws-direct-attach/) | 버킷 정책 직접 연결 방식 S3 통합 | 2025-12-05 ⚠️ |

### 🔗 관련 저장소

| 저장소 | 설명 |
|---|---|
| [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols) | ClickHouse 핵심 실습 |

### ✅ 저장소 검사

```bash
git config core.hooksPath .githooks
python3 .github/scripts/check_links.py
./.github/scripts/check_syntax.sh
```

### 📝 라이선스

[MIT](LICENSE). 실습이 실행 시점에 설치하는 소프트웨어는 각자의 라이선스를 따릅니다.
