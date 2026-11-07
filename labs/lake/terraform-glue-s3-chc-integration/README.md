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
> Found 2026-11-05 — a deployment from 2025-11-16 was still in the account ([#70](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/70)). It came from code older than `bb9c885`, which used other names: the bucket `chc-iceberg-data-<account_id>`, and the crawlers `chc-glue-integration-csv-crawler` and `chc-glue-integration-parquet-crawler` beside the iceberg one. Its iceberg crawler had the schedule `cron(0/5 * * * ? *)` and ran every 5 minutes for almost a year without creating a table. The lab folder had no `terraform.tfstate`, and without one `destroy.sh` prints "No terraform.tfstate found. Nothing to destroy." and exits. Everything was deleted with the AWS CLI on 2026-11-05; *Cleanup* shows how to check for leftovers. The current `main.tf` sets no crawler schedule. Nothing was re-run.
>
> Measured 2026-11-07 — cost, on ClickHouse Cloud 26.8.1.608 (2 replicas, ap-northeast-2) with [cost-measure/](cost-measure/), not with this lab's stack. *Cost (AWS side)* below has the figures: no Glue cache across queries (one `GetTable` per catalog table per query), S3 requests per query, listing, and Athena registration without a crawler. Still not checked: which Glue calls AWS bills (its pages do not say), and listing larger catalogs ([#71](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/71)).
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
>
> 2026-11-05 발견 — 2025-11-16에 배포한 리소스가 계정에 그대로 남아 있었습니다 ([#70](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/70)). `bb9c885` 이전 코드로 만든 것이라 이름이 다릅니다. 버킷은 `chc-iceberg-data-<account_id>`이고, iceberg 크롤러 옆에 `chc-glue-integration-csv-crawler`와 `chc-glue-integration-parquet-crawler`가 더 있었습니다. iceberg 크롤러에는 `cron(0/5 * * * ? *)` 스케줄이 걸려 있어서 1년 가까이 5분마다 돌았고, 테이블은 하나도 만들지 않았습니다. 실습 폴더에 `terraform.tfstate`가 없었는데, 이 파일이 없으면 `destroy.sh`는 "No terraform.tfstate found. Nothing to destroy."를 출력하고 끝납니다. 2026-11-05에 AWS CLI로 모두 지웠습니다. 남은 리소스를 확인하는 방법은 *정리*에 있습니다. 지금 `main.tf`에는 크롤러 스케줄이 없습니다. 다시 실행하지는 않았습니다.
>
> 2026-11-07 측정 — 비용. ClickHouse Cloud 26.8.1.608(레플리카 2개, ap-northeast-2)에서 이 실습의 스택이 아니라 [cost-measure/](cost-measure/)로 측정했습니다. 아래 *비용 (AWS 쪽)*에 수치가 있습니다: 쿼리 사이 Glue 캐시 없음(쿼리마다 카탈로그 테이블 하나당 `GetTable` 1건), 쿼리당 S3 요청, 목록 조회, 크롤러 없는 Athena 등록. 아직 확인 안 된 것: AWS가 어떤 Glue 호출에 과금하는지(AWS 페이지에 없음), 큰 카탈로그의 목록 조회 ([#71](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/71)).

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

### Cost (AWS side)

Federating with `DataLakeCatalog` (`catalog_type = 'glue'`) costs AWS money mainly as Glue Data Catalog API calls, plus S3 requests for the Iceberg files. ClickHouse Cloud compute is billed separately and is not covered here. Each figure says where it comes from ([#71](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/71)).

**Glue calls and S3 requests from ClickHouse.** Measured on 2026-11-07 with [cost-measure/](cost-measure/): ClickHouse Cloud 26.8.1.608 with 2 replicas, ap-northeast-2, authenticating with `aws_role_arn`, user agent `aws-sdk-cpp/1.11.771`. The account had one Glue database, holding 40 Iceberg tables written by Athena: `t01` with 200,000 rows and the rest with 100 rows each. Glue calls come from the CloudTrail event history. S3 requests come from `system.query_log` `ProfileEvents` (`S3GetObject`, `S3HeadObject`). The queries ran one at a time, 6 seconds apart.

| What ClickHouse ran | Glue calls | S3 requests (GET + HEAD) |
|---|---|---|
| `CREATE DATABASE … ENGINE = DataLakeCatalog` | none | none |
| `SELECT count()` on one table, 10 times | `GetTable` 1 every time, 10 in all | 4 + 4 the first time on each replica, then 1 + 1 (once 2 + 1) |
| A join of 3 tables | `GetTable` 3, one per table | 17 + 12 on its first run, which read 200,200 rows |
| `SHOW TABLES`, 3 times | `GetDatabases` 2 and `GetTables` 2 each time, listing all 40 tables | none |
| `SELECT … FROM system.tables`, filtered to the catalog and unfiltered | none | none |

`count()` was answered from Iceberg metadata (`read_rows` 1), so those S3 requests are metadata reads, not data files. The `system.tables` query filtered to the catalog returned 0 rows: the catalog's tables do not appear in `system.tables`.

**Earlier run.** Measured from the CloudTrail event history of a run of [labs/postgres/aurora-analytics-pg-clickhouse](../../postgres/aurora-analytics-pg-clickhouse/) on 2026-10-09: ClickHouse Cloud 26.6.1, ap-northeast-2, `aws_role_arn`, user agent `aws-sdk-cpp`. The 2026-11-07 run above gives the same per-query count.

| What ClickHouse ran | Glue calls |
|---|---|
| `CREATE DATABASE … ENGINE = DataLakeCatalog` and `SHOW TABLES` | `GetDatabases` 2, `GetTables` 4. The account had 2 Glue databases. |
| `SELECT count()` on each of 24 tables, once each | `GetTable` 24, one per query |

**Registering tables without a crawler.** Athena `CREATE TABLE … AS SELECT` with `table_type = 'ICEBERG'` writes the table and registers it in Glue itself; no crawler ran. CloudTrail showed 6 Glue calls per table from `athena.amazonaws.com` (40 tables, 2026-11-07): `CreateTable` 1, `GetDatabase` 1 and `GetTable` 4. The `GetTable` calls failed with `EntityNotFoundException`, because they check whether the table exists before creating it. These calls use the same free requests as ClickHouse's.

**Prices.** Glue: vendor doc [AWS Glue pricing](https://aws.amazon.com/glue/pricing/), read 2026-11-05. The Asia Pacific (Seoul) prices come from the page's price data, published 2026-10-12, and are the same as US East (N. Virginia). S3: AWS Price List API, S3 Standard requests in ap-northeast-2, published 2026-11-04 and read 2026-11-07.

| Item | Free each month | Then |
|---|---|---|
| Glue requests. The page names `GetTable`, `GetPartitions` and `CreateTable` among them. | 1 million requests | $1.00 per million |
| Glue storage. One object is a table, table version, partition, partition index, statistics, database or catalog. | 1 million objects | $1.00 per 100,000 objects a month |
| S3 GET and all other requests, HEAD among them (`APN2-Requests-Tier2`) | none | $0.00035 per 1,000 |
| S3 PUT, COPY, POST and LIST requests (`APN2-Requests-Tier1`) | none | $0.0045 per 1,000 |

**Which Glue calls are billed.** The pricing page and the [Glue FAQ](https://aws.amazon.com/glue/faqs/), both read 2026-11-07, do not define a Data Catalog request or list the billed API calls. The pricing page only says you are charged for "storing and accessing table metadata". It links no such list. This section said on 2026-11-05 that it did; that was wrong. The figures below count every call, so they are an upper bound.

**What this means.** Each point below is worked out from the tables above.

- **No cache across queries.** Every query made one `GetTable` call for each catalog table it read, even when the same query ran again 6 seconds later on the same replica. A query on k tables makes k calls. Above the free tier, a one-table query costs $0.000001 in Glue calls. For example, a dashboard with 20 panels, each joining 3 tables and refreshed every minute, makes 20 × 3 × 60 × 24 × 30 = 2,592,000 calls in 30 days. That is $1.59 beyond the free million, if nothing else in the account uses the free requests.
- **S3 per query.** A repeated one-table `count()` made 2 S3 requests, which is $0.0000007. The first query on a replica made 8. A query that reads data adds requests for the data files: the 3-table join made 29 on its first run. For example, 10 million repeated one-table queries in a month make 20 million S3 requests, which is $7.00.
- **Listing.** `SHOW TABLES` made 2 `GetDatabases` and 2 `GetTables` calls for each Glue database in the account. That count did not grow with 40 tables in one database. ClickHouse mounts the region's whole catalog as one database (see the banner), so a listing touches every Glue database in the region. `system.tables` made no Glue calls, so BI tools that read it do not cost Glue calls, but they do not see the catalog's tables there either.
- **Registering.** Creating a table through Athena made 6 Glue calls. 1,000 new tables would be 6,000 calls.
- **Shared free tier.** The free requests cover every caller, not only ClickHouse. In the 2026-10-09 run, Aurora's `aurora_analytics` made 3,620 `GetTable` calls, against 24 from ClickHouse.
- **Storage.** A lab-sized catalog, with one database and a few tables, stays inside the free million objects.

**Seen during the run (2026-11-07).**

- 2 of the 3 runs of the 3-table join failed with `S3_ERROR`: "AuthorizationHeaderMalformed … the region 'us-east-1' is wrong; expecting 'ap-northeast-2'". Their Glue calls had succeeded. The first run of the same join worked, and so did every one-table query. The integration is Beta. Joins across catalog tables were not investigated further.
- The first attempt, at 03:54 UTC, stopped when ClickHouse Cloud replaced both replicas. `system.query_log` is kept per replica, and the old pods' rows went with them. `DROP DATABASE … SYNC` then timed out waiting for a replaced replica that was still registered. `measure.sh` therefore creates a new catalog name for each run, sets `distributed_ddl_output_mode = 'none'`, and reads `system.query_log` right after the queries.

**Reproduce.** In `cost-measure/`, set `chc_iam_role_arn` and run `terraform apply`. Then run `./measure.sh tables`, `./measure.sh ch` and `./measure.sh s3` in that order. Wait about 15 minutes for CloudTrail, then run `./measure.sh trail` and `terraform destroy`. `./measure.sh cleanup` drops the catalogs it created. The raw output in `out/` holds account IDs and host names and is not committed.

**Not checked.**

- **Billed calls.** Which Glue calls AWS bills (see above). The billing usage report was not used.
- **Larger catalogs.** Listing a catalog with more tables than one `GetTables` page holds, or with many Glue databases. This run had 40 tables in one database.
- **Data-heavy queries.** S3 requests for queries that read many data files.

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
- Run `terraform destroy` on what `terraform.tfstate` in this folder records (S3 bucket, Glue database, crawler, IAM role)
- Optionally clean up local Terraform state files

⚠️ **Warning**: This permanently deletes the S3 bucket, Glue database, and all data.

Without `terraform.tfstate`, `destroy.sh` removes nothing: it prints "No terraform.tfstate found. Nothing to destroy." and exits. If the state is gone, or the lab was deployed from another clone, delete the resources by hand, then check that none are left. On 2026-11-05, after the cleanup in [#70](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/70), these lists were empty:

```bash
aws glue list-crawlers --region ap-northeast-2
aws glue get-databases --region ap-northeast-2 --query 'DatabaseList[].Name'
aws s3api list-buckets --query 'Buckets[?starts_with(Name, `chc-`)].Name'
aws iam list-roles --query 'Roles[?contains(RoleName, `chc-glue`)].RoleName'
```

A deployment from code before `bb9c885` (2025-11-16) has a bucket named `chc-iceberg-data-<account_id>`, two more crawlers (`chc-glue-integration-csv-crawler`, `chc-glue-integration-parquet-crawler`), and an iceberg crawler that runs every 5 minutes until it is deleted.

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

### 비용 (AWS 쪽)

`DataLakeCatalog`(`catalog_type = 'glue'`)로 페더레이션할 때 AWS 쪽에서 드는 돈은 주로 Glue Data Catalog API 호출이고, Iceberg 파일을 읽는 S3 요청이 더해집니다. ClickHouse Cloud 컴퓨팅 비용은 따로 청구되며 여기서 다루지 않습니다. 수치마다 출처를 적었습니다 ([#71](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/71)).

**ClickHouse가 보내는 Glue 호출과 S3 요청.** 2026-11-07에 [cost-measure/](cost-measure/)로 측정했습니다. ClickHouse Cloud 26.8.1.608(레플리카 2개), ap-northeast-2, `aws_role_arn` 인증, user agent `aws-sdk-cpp/1.11.771`입니다. 계정에는 Glue 데이터베이스가 하나 있었고, 그 안에 Athena로 만든 Iceberg 테이블 40개가 있었습니다. `t01`은 200,000행, 나머지는 100행씩입니다. Glue 호출은 CloudTrail 이벤트 기록에서, S3 요청은 `system.query_log`의 `ProfileEvents`(`S3GetObject`, `S3HeadObject`)에서 셌습니다. 쿼리는 6초 간격으로 하나씩 실행했습니다.

| ClickHouse에서 실행한 것 | Glue 호출 | S3 요청 (GET + HEAD) |
|---|---|---|
| `CREATE DATABASE … ENGINE = DataLakeCatalog` | 없음 | 없음 |
| 테이블 하나에 `SELECT count()`를 10번 | 매번 `GetTable` 1건, 모두 10건 | 레플리카마다 처음에는 4 + 4, 그 뒤로는 1 + 1 (한 번은 2 + 1) |
| 테이블 3개 조인 | `GetTable` 3건, 테이블마다 1건 | 첫 실행에서 17 + 12, 200,200행 읽음 |
| `SHOW TABLES`를 3번 | 매번 `GetDatabases` 2건과 `GetTables` 2건, 테이블 40개를 모두 나열 | 없음 |
| `system.tables` 조회, 카탈로그로 거른 것과 전체 | 없음 | 없음 |

`count()`는 Iceberg 메타데이터로 답했습니다(`read_rows` 1). 그래서 위의 S3 요청은 데이터 파일이 아니라 메타데이터를 읽은 것입니다. 카탈로그로 거른 `system.tables` 조회는 0행을 돌려줬습니다. 카탈로그의 테이블은 `system.tables`에 나오지 않습니다.

**이전 실행.** [labs/postgres/aurora-analytics-pg-clickhouse](../../postgres/aurora-analytics-pg-clickhouse/)를 2026-10-09에 실행한 기록을 CloudTrail 이벤트 기록에서 측정했습니다. 그 실행은 ClickHouse Cloud 26.6.1, ap-northeast-2, `aws_role_arn` 인증, user agent `aws-sdk-cpp`였습니다. 위의 2026-11-07 실행도 쿼리당 호출 수가 같습니다.

| ClickHouse에서 실행한 것 | Glue 호출 |
|---|---|
| `CREATE DATABASE … ENGINE = DataLakeCatalog`와 `SHOW TABLES` | `GetDatabases` 2건, `GetTables` 4건. 계정에 Glue 데이터베이스가 2개 있었습니다. |
| 테이블 24개에 `SELECT count()`를 한 번씩 | `GetTable` 24건, 쿼리마다 1건 |

**크롤러 없이 테이블 등록.** Athena의 `CREATE TABLE … AS SELECT`에 `table_type = 'ICEBERG'`를 주면 테이블을 쓰면서 Glue에도 직접 등록합니다. 크롤러는 돌지 않았습니다. CloudTrail에는 `athena.amazonaws.com`이 테이블마다 Glue를 6건 호출한 것으로 남았습니다(테이블 40개, 2026-11-07). `CreateTable` 1건, `GetDatabase` 1건, `GetTable` 4건입니다. `GetTable`은 `EntityNotFoundException`으로 실패했는데, 만들기 전에 테이블이 있는지 확인하는 호출이기 때문입니다. 이 호출도 ClickHouse와 같은 무료 요청을 씁니다.

**요금.** Glue: 벤더 문서 [AWS Glue 요금](https://aws.amazon.com/glue/pricing/), 2026-11-05에 읽음. 아시아 태평양(서울) 단가는 이 페이지의 가격 데이터(2026-10-12 게시)에서 가져왔고, 미국 동부(버지니아 북부)와 같습니다. S3: AWS Price List API의 ap-northeast-2 S3 Standard 요청 단가, 2026-11-04 게시, 2026-11-07에 읽음.

| 항목 | 매달 무료 | 초과분 |
|---|---|---|
| Glue 요청. 페이지는 `GetTable`, `GetPartitions`, `CreateTable`을 예로 듭니다. | 요청 100만 건 | 100만 건당 $1.00 |
| Glue 저장. 테이블, 테이블 버전, 파티션, 파티션 인덱스, 통계, 데이터베이스, 카탈로그가 각각 객체 하나입니다. | 객체 100만 개 | 객체 10만 개당 월 $1.00 |
| S3 GET과 그 밖의 모든 요청, HEAD 포함 (`APN2-Requests-Tier2`) | 없음 | 1,000건당 $0.00035 |
| S3 PUT, COPY, POST, LIST 요청 (`APN2-Requests-Tier1`) | 없음 | 1,000건당 $0.0045 |

**어떤 Glue 호출이 과금되는지.** 요금 페이지와 [Glue FAQ](https://aws.amazon.com/glue/faqs/)를 2026-11-07에 읽었는데, 둘 다 Data Catalog 요청이 무엇인지 정의하지 않고 과금되는 API 호출 목록도 없습니다. 요금 페이지는 "storing and accessing table metadata"에 과금한다고만 적고, 그런 목록에 링크하지도 않습니다. 이 절은 2026-11-05에 페이지에 목록 링크가 있다고 적었는데, 틀린 내용이었습니다. 아래 계산은 모든 호출을 요청으로 셌으므로 상한입니다.

**의미.** 아래 항목은 모두 위 표에서 계산한 것입니다.

- **쿼리 사이 캐시 없음.** 같은 쿼리를 같은 레플리카에서 6초 뒤에 다시 실행해도, 쿼리마다 읽는 카탈로그 테이블 하나당 `GetTable`을 1건씩 호출했습니다. 테이블 k개를 읽는 쿼리는 k건입니다. 무료 구간을 넘으면 테이블 하나짜리 쿼리의 Glue 호출 비용은 $0.000001입니다. 예를 들어 패널 20개가 각각 테이블 3개를 조인하고 1분마다 새로 고치는 대시보드는 30일에 20 × 3 × 60 × 24 × 30 = 2,592,000건을 호출합니다. 계정 안에서 무료 요청을 쓰는 다른 호출자가 없다면 무료 100만 건을 넘는 부분이 $1.59입니다.
- **쿼리당 S3.** 테이블 하나에 반복한 `count()`는 S3 요청 2건, $0.0000007입니다. 레플리카에서 처음 실행한 쿼리는 8건이었습니다. 데이터를 읽는 쿼리는 데이터 파일 요청이 더해집니다. 테이블 3개 조인은 첫 실행에서 29건이었습니다. 예를 들어 테이블 하나짜리 쿼리를 한 달에 1,000만 번 반복하면 S3 요청 2,000만 건, $7.00입니다.
- **목록 조회.** `SHOW TABLES`는 계정의 Glue 데이터베이스마다 `GetDatabases` 2건과 `GetTables` 2건을 호출했습니다. 데이터베이스 하나에 테이블이 40개여도 이 수는 늘지 않았습니다. ClickHouse는 리전의 카탈로그 전체를 데이터베이스 하나로 붙이므로(배너 참고), 목록을 조회하면 리전의 Glue 데이터베이스 전부를 건드립니다. `system.tables`는 Glue를 호출하지 않았습니다. 그래서 이것을 읽는 BI 도구는 Glue 호출 비용이 들지 않지만, 거기서 카탈로그의 테이블을 보지도 못합니다.
- **등록.** Athena로 테이블을 하나 만들 때 Glue 호출이 6건이었습니다. 새 테이블 1,000개면 6,000건입니다.
- **함께 쓰는 무료 구간.** 무료 요청은 ClickHouse만이 아니라 모든 호출자에게 적용됩니다. 2026-10-09 실행에서 Aurora `aurora_analytics`는 `GetTable`을 3,620건 호출했고, ClickHouse는 24건이었습니다.
- **저장.** 데이터베이스 하나에 테이블 몇 개인 실습 규모 카탈로그는 무료 객체 100만 개 안에 들어갑니다.

**실행 중에 본 것 (2026-11-07).**

- 테이블 3개 조인을 3번 실행했는데 그중 2번이 `S3_ERROR`로 실패했습니다: "AuthorizationHeaderMalformed … the region 'us-east-1' is wrong; expecting 'ap-northeast-2'". Glue 호출은 성공한 뒤였습니다. 같은 조인의 첫 실행과 테이블 하나짜리 쿼리는 모두 성공했습니다. 이 연동은 Beta이고, 카탈로그 테이블 사이의 조인은 더 조사하지 않았습니다.
- 03:54 UTC의 첫 시도는 ClickHouse Cloud가 레플리카 2개를 모두 교체하면서 멈췄습니다. `system.query_log`는 레플리카마다 따로 저장되어서, 옛 pod의 기록은 pod와 함께 사라졌습니다. 그다음 `DROP DATABASE … SYNC`는 교체됐지만 아직 등록되어 있던 레플리카를 기다리다 시간 초과됐습니다. 그래서 `measure.sh`는 실행마다 새 카탈로그 이름을 만들고, `distributed_ddl_output_mode = 'none'`을 주고, 쿼리를 마치자마자 `system.query_log`를 읽습니다.

**다시 실행하기.** `cost-measure/`에서 `chc_iam_role_arn`을 정하고 `terraform apply`를 실행합니다. 그다음 `./measure.sh tables`, `./measure.sh ch`, `./measure.sh s3`를 차례로 실행합니다. CloudTrail을 위해 15분쯤 기다린 뒤 `./measure.sh trail`과 `terraform destroy`를 실행합니다. `./measure.sh cleanup`은 만든 카탈로그를 지웁니다. `out/`의 원본 출력에는 계정 ID와 호스트 이름이 있어서 커밋하지 않습니다.

**확인 안 된 것.**

- **과금되는 호출.** AWS가 어떤 Glue 호출에 과금하는지(위 참고). 청구 사용 보고서는 보지 않았습니다.
- **큰 카탈로그.** `GetTables` 한 페이지에 다 들어가지 않을 만큼 테이블이 많거나 Glue 데이터베이스가 많은 카탈로그의 목록 조회. 이번 실행은 데이터베이스 하나에 테이블 40개였습니다.
- **데이터를 많이 읽는 쿼리.** 데이터 파일을 많이 읽는 쿼리의 S3 요청 수.

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
- 이 폴더의 `terraform.tfstate`에 기록된 리소스(S3 버킷, Glue 데이터베이스, 크롤러, IAM 역할)에 `terraform destroy` 실행
- 선택적으로 로컬 Terraform state 파일 정리

⚠️ **경고**: S3 버킷, Glue 데이터베이스와 모든 데이터가 영구적으로 삭제됩니다.

`terraform.tfstate`가 없으면 `destroy.sh`는 아무것도 지우지 않고, "No terraform.tfstate found. Nothing to destroy."를 출력하고 끝납니다. state가 없어졌거나 다른 클론에서 배포했다면 리소스를 직접 지운 뒤 남은 것이 없는지 확인하세요. 2026-11-05 [#70](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/70)에서 정리한 뒤에는 아래 목록이 모두 비어 있었습니다.

```bash
aws glue list-crawlers --region ap-northeast-2
aws glue get-databases --region ap-northeast-2 --query 'DatabaseList[].Name'
aws s3api list-buckets --query 'Buckets[?starts_with(Name, `chc-`)].Name'
aws iam list-roles --query 'Roles[?contains(RoleName, `chc-glue`)].RoleName'
```

`bb9c885`(2025-11-16) 이전 코드로 배포했다면 버킷 이름이 `chc-iceberg-data-<account_id>`이고, 크롤러가 두 개 더 있으며(`chc-glue-integration-csv-crawler`, `chc-glue-integration-parquet-crawler`), iceberg 크롤러는 지울 때까지 5분마다 돕니다.

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
