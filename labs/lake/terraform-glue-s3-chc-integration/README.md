# ClickHouse Cloud + AWS Glue Catalog Integration

> **Last verified: 2025-11-17** — date of the last commit made while running the lab (there is no separate run log). AWS provider `~> 5.0`.
> No code changes since — only documentation and licence edits.
> AWS provider: `~> 5.0` resolves to 5.100.0, the last 5.x release; never run on 6.x (6.67.0 is the newest, Terraform Registry API read 2026-10-04).
> Provider and AWS/ClickHouse Cloud behaviour may have drifted since; expect to adjust before `apply`.
>
> Not checked — ClickHouse 26.x (recorded 2026-10-07 from the ClickHouse docs and source; nothing was run). *Current Limitations* below is as of ClickHouse Cloud 25.8; Cloud services now run 26.x (one measured 26.6.1.2191 on 2026-10-02 in [labs/billing/usage-cost](../../billing/usage-cost/)).
> - IAM role: the [AWS Glue catalog docs page](https://clickhouse.com/docs/use-cases/data-lake/glue-catalog) (source last changed 2026-05-31) lists `aws_role_arn` from v26.2, with an optional `aws_role_session_name`. In the ClickHouse source (`src/Databases/DataLake/DatabaseDataLakeSettings.cpp`) `aws_role_arn` is absent in `v26.1.1.912-stable` and present from `v26.2.1.1139-stable`; `v26.6.1.1193-stable` also has `aws_external_id`. The lab still puts access keys into its SQL; role auth was not tried here, and the page does not say which principal the role's trust policy must allow on ClickHouse Cloud.
> - `glue_database`: still no such setting in `v26.6.1.1193-stable`. The docs page says ClickHouse supports one namespace: the region's whole catalog is one database and tables are named `` `database.table` ``. The examples here query `` glue_db.`sales_orders` `` without the Glue database name — not checked.
> - Potential issue: `deploy.sh` prints `glue_database = '…'` as an active setting, while this README and `outputs.tf` comment it out. With no such setting in `v25.8.1.5101-lts` or `v26.6.1.1193-stable`, the SQL copied from `deploy.sh` may be rejected — not run.
> - The docs page marks the integration Beta and says to run `SET allow_database_glue_catalog = 1;`. The SQL that `deploy.sh` and `outputs.tf` print does not set it.
>
> **마지막 검증: 2025-11-17** — 실습을 실행하며 남긴 마지막 커밋 날짜 (별도 실행 기록은 없음). AWS provider `~> 5.0`.
> 그 뒤 코드 변경 없음 — 문서와 라이선스 수정만 있었음.
> AWS provider: `~> 5.0`은 마지막 5.x인 5.100.0으로 잡힘. 6.x에서는 실행한 적 없음 (최신 6.67.0, 2026-10-04 Terraform Registry API로 확인).
> 그동안 provider와 AWS·ClickHouse Cloud 동작이 달라졌을 수 있으니 `apply` 전에 조정이 필요할 수 있습니다.
>
> 확인 안 된 것 — ClickHouse 26.x (2026-10-07 ClickHouse 문서와 소스를 읽고 기록, 실행 안 함). 아래 *현재 제약 사항*은 ClickHouse Cloud 25.8 기준입니다. 지금 Cloud 서비스는 26.x입니다 (2026-10-02 [labs/billing/usage-cost](../../billing/usage-cost/)에서 서비스 하나를 26.6.1.2191로 측정).
> - IAM 역할: [AWS Glue catalog 문서](https://clickhouse.com/docs/use-cases/data-lake/glue-catalog)(소스 마지막 변경 2026-05-31)는 v26.2부터 `aws_role_arn`을, 선택 항목으로 `aws_role_session_name`을 적고 있습니다. ClickHouse 소스(`src/Databases/DataLake/DatabaseDataLakeSettings.cpp`)에서 `aws_role_arn`은 `v26.1.1.912-stable`에는 없고 `v26.2.1.1139-stable`부터 있으며, `v26.6.1.1193-stable`에는 `aws_external_id`도 있습니다. 이 실습은 여전히 SQL에 액세스 키를 넣습니다. 역할 인증은 여기서 시도하지 않았고, ClickHouse Cloud에서 역할의 신뢰 정책이 어떤 주체를 허용해야 하는지는 문서에 없습니다.
> - `glue_database`: `v26.6.1.1193-stable`에도 이런 설정은 없습니다. 문서에 따르면 ClickHouse는 네임스페이스를 하나만 지원해서, 리전의 카탈로그 전체가 데이터베이스 하나가 되고 테이블 이름은 `` `database.table` `` 형태입니다. 이 실습의 예시는 Glue 데이터베이스 이름 없이 `` glue_db.`sales_orders` ``를 조회합니다 — 확인 안 함.
> - 잠재 문제: `deploy.sh`는 `glue_database = '…'`를 활성 설정으로 출력하지만, 이 README와 `outputs.tf`는 주석 처리합니다. `v25.8.1.5101-lts`와 `v26.6.1.1193-stable` 모두 이런 설정이 없으므로 `deploy.sh`에서 복사한 SQL은 거부될 수 있습니다 — 실행 안 함.
> - 문서는 이 연동을 Beta로 표시하고 `SET allow_database_glue_catalog = 1;`을 실행하라고 합니다. `deploy.sh`와 `outputs.tf`가 출력하는 SQL에는 이 설정이 없습니다.

[English](#english) | [한국어](#한국어)

## English

> **Related notes** (Korean): [Data Lake Catalog (25.10+)](https://clickhouse.litkhai.dev/articles/feature/data-lake-catalog-25-10/)

Simple Terraform setup to integrate ClickHouse Cloud with AWS Glue Catalog using Apache Iceberg tables.

### ⚠️ Current Limitations (ClickHouse Cloud 25.8)

As of 25.8, when the lab last ran. The docs list IAM role authentication from v26.2 — see the banner.

**Known limitations in ClickHouse Cloud version 25.8:**
- ❌ `glue_database` parameter not supported in DataLakeCatalog
- ❌ IAM role-based authentication not supported (must use access keys)
- ✅ DataLakeCatalog discovers all Glue databases in the region automatically

**Future Updates:**
Once ClickHouse Cloud updates to support these features, this setup will be enhanced with:
- Specific Glue database selection
- IAM role-based authentication support
- Cross-account Glue catalog access

### What This Does

1. Creates S3 bucket for Iceberg data storage
2. Sets up AWS Glue Database and Crawler
3. Generates sample Iceberg table data
4. Automatically runs crawler to register tables
5. Outputs ready-to-use ClickHouse SQL commands

### Prerequisites

- Terraform >= 1.0
- AWS CLI configured
- Python 3 with pip
- ClickHouse Cloud account (same AWS region)
- AWS credentials with permissions for:
  - S3 (create buckets, upload objects)
  - Glue (create databases, crawlers)
  - IAM (create/manage roles for Glue Crawler)

⚠️ **Note**: Some operations may fail if your AWS account has Service Control Policies (SCP) restrictions.

### Quick Start

#### 1. Run Deployment Script

```bash
./deploy.sh
```

The script will:
1. **Prompt for AWS credentials** (stored only in environment variables, not in files)
   - AWS Access Key ID (must start with AKIA for long-term credentials)
   - AWS Secret Access Key
   - AWS Region (default: ap-northeast-2)

2. **Deploy all AWS infrastructure**
   - S3 bucket with encryption and versioning
   - AWS Glue Database and Crawler
   - IAM Role for Glue Crawler (if permissions allow)

3. **Create and upload sample Iceberg table** (`sales_orders`)

4. **Run Glue Crawler** to register the table

5. **Display ClickHouse connection SQL** with credentials embedded

#### 2. Use in ClickHouse Cloud

Copy the SQL output from deploy.sh and run it in your ClickHouse Cloud console. The SQL will already have your credentials embedded:

```sql
CREATE DATABASE glue_db
ENGINE = DataLakeCatalog
SETTINGS
    catalog_type = 'glue',
 -- glue_database = 'clickhouse_iceberg_db', -- Not supported in ClickHouse 25.8
    region = 'ap-northeast-2',
    aws_access_key_id = 'AKIA...',           -- Your actual credentials
    aws_secret_access_key = 'your-secret';    -- filled in by deploy.sh

-- List all tables (from default Glue database in the region)
SHOW TABLES FROM glue_db;

-- Query the Iceberg table
SELECT * FROM glue_db.`sales_orders` LIMIT 10;

-- Run analytics
SELECT category, SUM(price * quantity) as revenue
FROM glue_db.`sales_orders`
GROUP BY category
ORDER BY revenue DESC;
```

**Note:** The `glue_database` parameter is not supported in ClickHouse 25.8. DataLakeCatalog will automatically discover all Glue databases in the specified region.

### Manual Setup (Alternative)

If you prefer step-by-step control:

```bash
# 1. Set AWS credentials as environment variables
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_REGION="ap-northeast-2"

# 2. Initialize Terraform
terraform init

# 3. Deploy infrastructure
terraform apply

# 4. Create Iceberg table
python3 ./scripts/create-iceberg-table.py

# 5. Run Glue Crawler
aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2

# 6. Wait ~2 minutes, then check tables
aws glue get-tables --database-name clickhouse_iceberg_db --region ap-northeast-2

# 7. Get connection info (credentials will show as $AWS_ACCESS_KEY_ID placeholders)
terraform output clickhouse_connection_info
```

### What Gets Created

| Resource | Name | Purpose |
|----------|------|---------|
| S3 Bucket | `chc-glue-integration-{account_id}` | Stores Iceberg data |
| Glue Database | `clickhouse_iceberg_db` | Metadata catalog |
| Glue Crawler | `chc-glue-integration-iceberg-crawler` | Auto-discovers tables |
| IAM Role | `chc-glue-integration-glue-crawler-role` | Crawler permissions |
| Sample Table | `sales_orders` | Demo Iceberg table with 10 rows |

### Configuration

AWS credentials are provided via environment variables (not stored in files):
- `AWS_ACCESS_KEY_ID` - Your AWS access key (must start with AKIA for long-term)
- `AWS_SECRET_ACCESS_KEY` - Your AWS secret access key
- `AWS_REGION` - AWS region (default: ap-northeast-2)

Optional settings in `terraform.tfvars`:

```hcl
aws_region         = "ap-northeast-2"           # AWS region
project_name       = "chc-glue-integration"     # Resource name prefix
glue_database_name = "clickhouse_iceberg_db"    # Glue database name
```

### Architecture

```
┌─────────────────────────────┐
│    ClickHouse Cloud         │
│  ┌───────────────────────┐  │
│  │ DataLakeCatalog DB    │  │
│  │ - Auto-discovers      │  │
│  │   all Glue tables     │  │
│  └───────────┬───────────┘  │
└──────────────┼──────────────┘
               │ AWS Credentials
               ▼
┌─────────────────────────────┐
│         AWS Account         │
│  ┌──────────────────────┐  │
│  │  Glue Catalog        │  │
│  │  - clickhouse_       │  │
│  │    iceberg_db        │  │
│  │  - sales_orders      │  │
│  │                      │  │
│  │  Glue Crawler        │  │
│  │  (Auto-updates)      │  │
│  └──────────┬───────────┘  │
│             │              │
│  ┌──────────▼───────────┐  │
│  │  S3 Bucket           │  │
│  │  /iceberg/           │  │
│  │    /sales_orders/    │  │
│  │      /metadata/      │  │
│  │      /data/          │  │
│  └──────────────────────┘  │
└─────────────────────────────┘
```

### Sample Data

The `sales_orders` table contains:
- 10 sample records
- Categories: Electronics, Books, Clothing, Food, Sports
- Partitioned by `order_date`
- Schema: id, user_id, product_id, category, quantity, price, order_date, description

### Troubleshooting

#### Tables not visible in ClickHouse

```bash
# Check if table exists in Glue
aws glue get-table --database-name clickhouse_iceberg_db --name sales_orders --region ap-northeast-2

# Check crawler status
aws glue get-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2

# Manually trigger crawler
aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2
```

#### Access Denied errors

- Verify your AWS credentials have S3 and Glue read permissions
- Check that credentials start with `AKIA` (long-term, not temporary `ASIA`)
- Test manually:
  ```bash
  aws s3 ls s3://chc-glue-integration-{your-account-id}/
  aws glue get-database --name clickhouse_iceberg_db --region ap-northeast-2
  ```

#### AWS SCP Restrictions

If you see permission denied errors for IAM operations:
- Your AWS account has organizational restrictions
- The setup will still work if you have S3 and Glue permissions
- IAM Role creation may fail (this is expected and safe to ignore)

### Cleanup

```bash
# Remove all resources
./destroy.sh
```

This will:
- Destroy all AWS resources (S3 bucket, Glue database, crawlers, IAM roles)
- Optionally clean up local Terraform state files

⚠️ **Warning**: This permanently deletes the S3 bucket, Glue database, and all data.

### Key Features

- ✅ **Catalog-level integration**: the region's Glue catalog is mounted as one ClickHouse database; choosing a single Glue database (`glue_database`) is not supported in 25.8 (see *Current Limitations*)
- ✅ **Automatic table discovery**: All Glue tables immediately available
- ✅ **Schema synchronization**: Changes reflected automatically
- ✅ **Partition pruning**: Efficient queries on partitioned data
- ✅ **ACID guarantees**: Powered by Apache Iceberg

### Documentation

- [ClickHouse DataLakeCatalog Documentation](https://clickhouse.com/docs/use-cases/data-lake/glue-catalog)
- [Apache Iceberg Specification](https://iceberg.apache.org/spec/)
- [AWS Glue Data Catalog](https://docs.aws.amazon.com/glue/latest/dg/catalog-and-crawler.html)

### License

[MIT](../../../LICENSE) — same as the rest of the repository.

---

## 한국어

> **관련 글**: [Data Lake Catalog (25.10+)](https://clickhouse.litkhai.dev/articles/feature/data-lake-catalog-25-10/)

Apache Iceberg 테이블을 사용해 ClickHouse Cloud를 AWS Glue Catalog와 통합하는 간단한 Terraform 구성입니다.

### ⚠️ 현재 제약 사항 (ClickHouse Cloud 25.8)

실습을 마지막으로 실행한 25.8 기준입니다. 문서에는 v26.2부터 IAM 역할 인증이 있습니다 — 맨 위 배너 참고.

**ClickHouse Cloud 25.8 버전의 알려진 제약 사항:**
- ❌ DataLakeCatalog에서 `glue_database` 파라미터를 지원하지 않습니다
- ❌ IAM 역할 기반 인증을 지원하지 않습니다 (액세스 키를 사용해야 합니다)
- ✅ DataLakeCatalog가 리전의 모든 Glue 데이터베이스를 자동으로 찾습니다

**향후 업데이트:**
ClickHouse Cloud가 이 기능들을 지원하도록 업데이트되면, 이 구성은 다음 기능으로 보강됩니다.
- 특정 Glue 데이터베이스 선택
- IAM 역할 기반 인증 지원
- 교차 계정 Glue 카탈로그 접근

### 이 실습이 하는 일

1. Iceberg 데이터를 저장할 S3 버킷을 만듭니다
2. AWS Glue 데이터베이스와 크롤러를 설정합니다
3. 샘플 Iceberg 테이블 데이터를 생성합니다
4. 크롤러를 자동으로 실행해 테이블을 등록합니다
5. 바로 쓸 수 있는 ClickHouse SQL 명령을 출력합니다

### 사전 준비

- Terraform >= 1.0
- 설정이 끝난 AWS CLI
- pip가 있는 Python 3
- ClickHouse Cloud 계정 (같은 AWS 리전)
- 다음 권한이 있는 AWS 자격 증명:
  - S3 (버킷 생성, 객체 업로드)
  - Glue (데이터베이스, 크롤러 생성)
  - IAM (Glue Crawler용 역할 생성·관리)

⚠️ **참고**: AWS 계정에 서비스 제어 정책(SCP) 제한이 있으면 일부 작업이 실패할 수 있습니다.

### 빠른 시작

#### 1. 배포 스크립트 실행

```bash
./deploy.sh
```

스크립트는 다음을 합니다.
1. **AWS 자격 증명을 입력받습니다** (파일이 아니라 환경 변수에만 저장)
   - AWS Access Key ID (장기 자격 증명이므로 AKIA로 시작해야 함)
   - AWS Secret Access Key
   - AWS 리전 (기본값: ap-northeast-2)

2. **모든 AWS 인프라를 배포합니다**
   - 암호화와 버전 관리가 켜진 S3 버킷
   - AWS Glue 데이터베이스와 크롤러
   - Glue Crawler용 IAM 역할 (권한이 허용하는 경우)

3. **샘플 Iceberg 테이블을 만들어 업로드합니다** (`sales_orders`)

4. **Glue Crawler를 실행해** 테이블을 등록합니다

5. **자격 증명이 들어간 ClickHouse 연결 SQL을 표시합니다**

#### 2. ClickHouse Cloud에서 사용

deploy.sh가 출력한 SQL을 복사해 ClickHouse Cloud 콘솔에서 실행합니다. SQL에는 자격 증명이 이미 들어 있습니다.

```sql
CREATE DATABASE glue_db
ENGINE = DataLakeCatalog
SETTINGS
    catalog_type = 'glue',
 -- glue_database = 'clickhouse_iceberg_db', -- ClickHouse 25.8에서는 지원하지 않음
    region = 'ap-northeast-2',
    aws_access_key_id = 'AKIA...',           -- 실제 자격 증명
    aws_secret_access_key = 'your-secret';    -- deploy.sh가 채워 넣음

-- 모든 테이블 조회 (리전의 기본 Glue 데이터베이스에서)
SHOW TABLES FROM glue_db;

-- Iceberg 테이블 조회
SELECT * FROM glue_db.`sales_orders` LIMIT 10;

-- 분석 실행
SELECT category, SUM(price * quantity) as revenue
FROM glue_db.`sales_orders`
GROUP BY category
ORDER BY revenue DESC;
```

**참고:** `glue_database` 파라미터는 ClickHouse 25.8에서 지원하지 않습니다. DataLakeCatalog는 지정한 리전의 모든 Glue 데이터베이스를 자동으로 찾습니다.

### 수동 설정 (대안)

단계마다 직접 제어하려면 다음과 같이 합니다.

```bash
# 1. AWS 자격 증명을 환경 변수로 설정
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_REGION="ap-northeast-2"

# 2. Terraform 초기화
terraform init

# 3. 인프라 배포
terraform apply

# 4. Iceberg 테이블 생성
python3 ./scripts/create-iceberg-table.py

# 5. Glue Crawler 실행
aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2

# 6. 약 2분 기다린 뒤 테이블 확인
aws glue get-tables --database-name clickhouse_iceberg_db --region ap-northeast-2

# 7. 연결 정보 확인 (자격 증명은 $AWS_ACCESS_KEY_ID 같은 플레이스홀더로 표시됨)
terraform output clickhouse_connection_info
```

### 생성되는 리소스

| 리소스 | 이름 | 용도 |
|----------|------|---------|
| S3 버킷 | `chc-glue-integration-{account_id}` | Iceberg 데이터 저장 |
| Glue 데이터베이스 | `clickhouse_iceberg_db` | 메타데이터 카탈로그 |
| Glue 크롤러 | `chc-glue-integration-iceberg-crawler` | 테이블 자동 탐색 |
| IAM 역할 | `chc-glue-integration-glue-crawler-role` | 크롤러 권한 |
| 샘플 테이블 | `sales_orders` | 10개 행이 있는 데모 Iceberg 테이블 |

### 설정

AWS 자격 증명은 환경 변수로 전달합니다 (파일에 저장하지 않음).
- `AWS_ACCESS_KEY_ID` - AWS 액세스 키 (장기 자격 증명이므로 AKIA로 시작해야 함)
- `AWS_SECRET_ACCESS_KEY` - AWS 시크릿 액세스 키
- `AWS_REGION` - AWS 리전 (기본값: ap-northeast-2)

`terraform.tfvars`에서 선택적으로 설정할 수 있는 값:

```hcl
aws_region         = "ap-northeast-2"           # AWS 리전
project_name       = "chc-glue-integration"     # 리소스 이름 접두사
glue_database_name = "clickhouse_iceberg_db"    # Glue 데이터베이스 이름
```

### 아키텍처

```
┌─────────────────────────────┐
│    ClickHouse Cloud         │
│  ┌───────────────────────┐  │
│  │ DataLakeCatalog DB    │  │
│  │ - Auto-discovers      │  │
│  │   all Glue tables     │  │
│  └───────────┬───────────┘  │
└──────────────┼──────────────┘
               │ AWS Credentials
               ▼
┌─────────────────────────────┐
│         AWS Account         │
│  ┌──────────────────────┐  │
│  │  Glue Catalog        │  │
│  │  - clickhouse_       │  │
│  │    iceberg_db        │  │
│  │  - sales_orders      │  │
│  │                      │  │
│  │  Glue Crawler        │  │
│  │  (Auto-updates)      │  │
│  └──────────┬───────────┘  │
│             │              │
│  ┌──────────▼───────────┐  │
│  │  S3 Bucket           │  │
│  │  /iceberg/           │  │
│  │    /sales_orders/    │  │
│  │      /metadata/      │  │
│  │      /data/          │  │
│  └──────────────────────┘  │
└─────────────────────────────┘
```

### 샘플 데이터

`sales_orders` 테이블에 들어 있는 것:
- 샘플 레코드 10개
- 카테고리: Electronics, Books, Clothing, Food, Sports
- `order_date`로 파티션됨
- 스키마: id, user_id, product_id, category, quantity, price, order_date, description

### 문제 해결

#### ClickHouse에서 테이블이 보이지 않음

```bash
# Glue에 테이블이 있는지 확인
aws glue get-table --database-name clickhouse_iceberg_db --name sales_orders --region ap-northeast-2

# 크롤러 상태 확인
aws glue get-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2

# 크롤러를 수동으로 실행
aws glue start-crawler --name chc-glue-integration-iceberg-crawler --region ap-northeast-2
```

#### Access Denied 오류

- AWS 자격 증명에 S3와 Glue 읽기 권한이 있는지 확인합니다
- 자격 증명이 `AKIA`로 시작하는지 확인합니다 (임시 자격 증명인 `ASIA`가 아닌 장기 자격 증명)
- 직접 테스트합니다:
  ```bash
  aws s3 ls s3://chc-glue-integration-{your-account-id}/
  aws glue get-database --name clickhouse_iceberg_db --region ap-northeast-2
  ```

#### AWS SCP 제한

IAM 작업에서 권한 거부(permission denied) 오류가 보인다면:
- AWS 계정에 조직 차원의 제한이 걸려 있는 것입니다
- S3와 Glue 권한이 있으면 설정은 그래도 동작합니다
- IAM 역할 생성은 실패할 수 있습니다 (예상된 동작이며 무시해도 안전합니다)

### 정리

```bash
# 모든 리소스 제거
./destroy.sh
```

이 스크립트는 다음을 합니다.
- 모든 AWS 리소스 삭제 (S3 버킷, Glue 데이터베이스, 크롤러, IAM 역할)
- 선택적으로 로컬 Terraform state 파일 정리

⚠️ **경고**: S3 버킷, Glue 데이터베이스와 모든 데이터가 영구적으로 삭제됩니다.

### 주요 기능

- ✅ **카탈로그 수준 통합**: 리전의 Glue 카탈로그를 ClickHouse 데이터베이스 하나로 마운트. Glue 데이터베이스 하나만 고르는 `glue_database`는 25.8에서 지원하지 않음 (*현재 제약 사항* 참고)
- ✅ **테이블 자동 탐색**: 모든 Glue 테이블을 바로 사용 가능
- ✅ **스키마 동기화**: 변경 사항이 자동으로 반영됨
- ✅ **파티션 프루닝**: 파티션된 데이터에 대한 효율적인 쿼리
- ✅ **ACID 보장**: Apache Iceberg 기반

### 문서

- [ClickHouse DataLakeCatalog 문서](https://clickhouse.com/docs/use-cases/data-lake/glue-catalog)
- [Apache Iceberg 명세](https://iceberg.apache.org/spec/)
- [AWS Glue Data Catalog](https://docs.aws.amazon.com/glue/latest/dg/catalog-and-crawler.html)

### 라이선스

[MIT](../../../LICENSE) — 저장소의 나머지 부분과 같습니다.
