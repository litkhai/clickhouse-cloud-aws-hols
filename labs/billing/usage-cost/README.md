# Usage Cost API — what ClickHouse Cloud bills, and how far it breaks down

> **Last run: 2026-10-02** — `01-fetch.py` → `04-backups.py` ran end to end against a real organization: one 31-day range and one 42-day range (two windows); `02-load.sql` and `03-allocate.sql` on one service. ClickHouse Cloud API `v1` (OpenAPI `info.version` 1.0), `organizationTier` `ENTERPRISE`, ClickHouse 26.6.1.2191 on the service.
> No changes since.
>
> **마지막 실행: 2026-10-02** — 실제 조직에서 `01-fetch.py` → `04-backups.py`를 끝까지 실행: 31일 범위 1회, 42일 범위 1회(창 2개), `02-load.sql`·`03-allocate.sql`은 서비스 하나에서. ClickHouse Cloud API `v1`(OpenAPI `info.version` 1.0), `organizationTier` `ENTERPRISE`, 서비스의 ClickHouse 26.6.1.2191.
> 그 뒤 변경 없음.

[English](#english) | [한국어](#한국어)

## English

This lab answers two recurring billing questions with the Usage Cost API, and shows where its detail ends:

1. Three cost categories can be tracked: `service`, `clickpipe` and `datawarehouse`. Is the S3 cost of stored data the `datawarehouse` item?
2. ClickPipes is clear enough. Can `service` and `datawarehouse` costs be shown in more detail?

It only reads the API and system tables. It creates no service and changes none, so running it costs nothing beyond the queries of steps 2 and 3 on a running service.

### What the API returns

`GET /v1/organizations/{organizationId}/usageCost?from_date=…&to_date=…` ([reference](https://clickhouse.com/docs/products/cloud/api-reference/billing/get-organization-usage-costs)):

- `to_date` is inclusive and the range is at most 31 days. A 32-day request answers `400 Time period queried exceeds 31 days`, so `01-fetch.py` splits longer ranges into windows.
- Days are UTC. The response is a grand total plus one record per **day × entity**: `date`, `dataWarehouseId`, `serviceId` (null on data-warehouse records), `entityType`, `entityId`, `entityName`, `organizationTier`, `locked`, `metrics`, `totalCHC`. `organizationTier` is in real responses but not in the published spec.
- `locked: false` marks a provisional day; its figures can still change. On 2026-10-02 the last 11 days (from 2026-09-21) were still unlocked, so expect about two weeks, not one or two days.
- `filter=tag:Key=Value` narrows the report to tagged resources.

Each entity type carries its own metrics (spec read 2026-10-02, and the same sets in every real record):

| `entityType` | metrics |
|---|---|
| `datawarehouse` | `storageCHC`, `backupCHC` |
| `service` | `computeCHC`, `publicDataTransferCHC`, `interRegionTier1…4DataTransferCHC` |
| `clickpipe` | `computeCHC`, `dataTransferCHC`, `initialLoadCHC` |

### Answers

**1. Yes, stored data is the `datawarehouse` item.** Data stored in ClickHouse Cloud is billed on the `datawarehouse` record as `storageCHC`; on AWS that storage is S3 that ClickHouse manages. Backups are billed on the same record as `backupCHC`. A `service` record never carries storage. A data warehouse is the storage that a service shares with its compute-compute-separated child services, so one warehouse record covers all of them.
Not included: S3 buckets you own and read with `s3()` or ClickPipes (see [`labs/s3/`](../../s3/)). Those appear on your AWS bill; ClickHouse bills only the compute and data transfer around them.

**2. Yes, down to the API's grain: day × entity × metric.**

- `service`: compute, internet egress and inter-region transfer (tiers 1–4), each on its own, per service and day
- `datawarehouse`: storage and backup separately, per warehouse and day
- `filter=tag:…` narrows the report to tagged resources (team, environment)
- Below that grain the billing API has no data: nothing per database, table, user or query. `03-allocate.sql` *estimates* shares from system tables and spreads the billed CHC proportionally. The output calls this an allocation, never a bill.

CHC are credits. Their price depends on the contract, so the lab reports CHC only.

### Permissions (measured 2026-10-02)

| Call | Permission (spec) | Smallest system role that worked |
|---|---|---|
| `usageCost` (01) | `control-plane:organization:view` | **Member**: its only permission is `organization:view`; `organization:view-billing` is not needed |
| service backups (04) | `control-plane:service:view-backups` | **Basic Service Reader**: the same key answered `403` with Member and `200` with Basic Service Reader |

Create a dedicated key for the lab (Console → Organization → API Keys) rather than reusing an Admin key.

On a shared service, give 02 and 03 their own SQL user. Run as an admin, once:

```sql
CREATE DATABASE billing_hols COMMENT 'clickhouse-cloud-aws-hols labs/billing/usage-cost';
CREATE USER billing_hols IDENTIFIED WITH sha256_hash BY '<sha256-hex-of-the-password>';
GRANT SHOW, SELECT, INSERT, CREATE DATABASE, CREATE TABLE, DROP TABLE, TRUNCATE, OPTIMIZE
    ON billing_hols.* TO billing_hols;
GRANT SELECT ON system.parts TO billing_hols;
GRANT SELECT ON system.query_log* TO billing_hols;
GRANT SELECT ON system.asynchronous_metric_log* TO billing_hols;
GRANT READ ON REMOTE TO billing_hols;   -- clusterAllReplicas()
GRANT SHOW TABLES, CREATE TEMPORARY TABLE ON *.* TO billing_hols;
```

`GRANT ALL ON billing_hols.*` fails when run from the Cloud SQL console: the console user cannot pass on `CHECK` and several `SYSTEM …` privileges, hence the explicit list. `READ ON REMOTE` is what `clusterAllReplicas()` asks for. `CREATE TEMPORARY TABLE` is for 03's session tables. `SHOW TABLES ON *.*` lets the user see every table's metadata but read no data: `system.parts` lists only tables the user may `SHOW`, so without it 03 shares storage out among `system` and `billing_hols` alone.

### Files

| File | Does |
|---|---|
| [`.env.example`](.env.example) | Organization ID, API key, and the service host, user and password for 02 and 03. Copy to `.env` (gitignored, mode 600) |
| [`chc_api.py`](chc_api.py) | Shared by 01 and 04: configuration (environment first, then `.env`), Basic auth, retries on 429/5xx, ≤31-day windows |
| [`01-fetch.py`](01-fetch.py) | Fetches a range window by window, saves the raw JSON to `out/`, writes `out/usage_cost.jsonl`, prints totals by type × metric and per entity, marks provisional days. **Fails** if a record carries a metric outside its type's set or the records do not add up to the grand total |
| [`02-load.sql`](02-load.sql) | Loads the jsonl into the dedicated database `billing_hols` (refuses a `billing_hols` it did not create). `ReplacingMergeTree` keyed on (`date`, `entityType`, `entityId`), so a provisional day is replaced when re-fetched. Example queries for questions 1 and 2 |
| [`03-allocate.sql`](03-allocate.sql) | On one service: storage share per database/table and compute share per user, times the billed CHC, plus an *unallocated* line. **Fails** if any day's allocated + unallocated differs from the billed CHC |
| [`04-backups.py`](04-backups.py) | Backup count and `sizeInBytes` per service, next to the warehouse's `backupCHC` |
| [`tests/`](tests/) | Offline tests with made-up data, including fault injection for every check |

`out/` is gitignored: real entity names, IDs and amounts stay there.

### Run

Python 3.9+ (standard library only) and `clickhouse client` for steps 2 and 3.

```bash
cd labs/billing/usage-cost
cp .env.example .env && chmod 600 .env    # then fill it in
```

**Step 1 — fetch and check.** A range longer than 31 days is split into windows.

```bash
python3 01-fetch.py --from 2026-08-21 --to 2026-10-01
python3 01-fetch.py --from 2026-09-01 --to 2026-10-01 --filter tag:Environment=Production
```

Output, with made-up names and numbers:

```
usage cost, in CHC (ClickHouse Cloud credits), not currency
  range:        2026-09-29 .. 2026-10-01
  windows:      1
  records:      12
  grand total:  195.2000 CHC

totals by entityType and metric
  entityType     metric                                CHC
  clickpipe      computeCHC                         7.5000
  clickpipe      dataTransferCHC                    1.0000
  clickpipe      initialLoadCHC                     1.2000
  datawarehouse  storageCHC                        30.7500
  datawarehouse  backupCHC                          3.2500
  service        computeCHC                       142.0000
  service        publicDataTransferCHC              7.2500
  service        interRegionTier1DataTransferCHC    1.5000
  ...

per entity
  entityType     entityName        CHC  days
  clickpipe      clickpipe-a    9.7000     3
  datawarehouse  warehouse-a   34.0000     3
  service        service-a    120.0000     3
  service        service-b     31.5000     3

provisional days (locked=false): these figures may still change
  date        records      CHC
  2026-10-01        4  44.9000

checks: every record carries only the metrics of its entityType; sum(totalCHC) equals grandTotalCHC in each of 1 window(s)
```

**Step 2 — load and query.** Run from the lab directory; the `INSERT` reads `out/usage_cost.jsonl`. `clickhouse client` takes the password from `CLICKHOUSE_PASSWORD` in `.env` (checked with client 26.9: a wrong value fails authentication), so it never appears on the command line; `--ask-password` prompts instead.

```bash
set -a; . ./.env; set +a
clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" --queries-file 02-load.sql
```

**Step 3 — allocate.** Connected to the service to allocate. Its ID is the `serviceId` of its `service` rows in `out/usage_cost.jsonl`.

```bash
clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" \
    --param_service_id=<service-id> --param_from=2026-08-21 --param_to=2026-10-01 \
    --queries-file 03-allocate.sql
```

**Step 4 — backups.** A service that existed during the range but has been deleted since answers `404`; 04 says so and goes on with the others.

```bash
python3 04-backups.py
```

### How 03 allocates, and what it cannot tell

- **Storage** is shared out by active `bytes_on_disk` per database and table in `system.parts`. That is a snapshot taken when the query runs, applied to every day of the range: a table that grew or was dropped during the range is weighted by today's size.
- **Compute** is shared out by CPU time per user in `system.query_log` against the service's capacity: `CGroupMaxCPU` × uptime per replica from `system.asynchronous_metric_log`. Every finished or failed query row counts. On the day measured (2026-10-01) the service logged no secondary queries (`is_initial_query = 0`), so nothing could be counted twice; measure again on a service that uses parallel replicas. What no query explains — idle uptime, merges, background work — is its own *unallocated* line. A day with billed compute and no log samples is entirely unallocated and flagged.
- **Rotated logs.** ClickHouse renames the system logs on upgrade (`query_log_1`, `query_log_2`, …), so 03 reads them with `merge('system', '^query_log(_[0-9]+)?$')` across all replicas. The range you can allocate is bounded by how far back those logs go.
- **One service.** Only the compute of the service you are connected to is allocated. Other services on the same warehouse are not queried, so their compute is not split by user.
- **Expect a large unallocated line.** Compute is billed for the provisioned size × uptime, not for the CPU queries use. On the service we ran it on, which is up all day with a light query load, almost all billed compute was unallocated: the queries used a small fraction of the capacity. That is the honest answer for an always-on service, not a gap in the script.

### Tests

```bash
python3 tests/test_offline.py
```

No network and no service: made-up fixtures, a faked HTTP layer, and `clickhouse local` for the two SQL files when the binary is on `PATH`. Every check is also run against input built to break it, and must fail.

### Out of scope

Pricing and currency conversion · per-query billing (it does not exist) · changing any service · AWS Cost Explorer (only where self-owned S3 shows up).

---

## 한국어

이 실습은 자주 나오는 빌링 질문 두 가지에 Usage Cost API로 답하고, 그 API로 어디까지 쪼갤 수 있는지 보여 줍니다.

1. 추적할 수 있는 비용 항목은 `service`, `clickpipe`, `datawarehouse` 세 가지입니다. 저장된 데이터의 S3 비용이 `datawarehouse` 항목인가?
2. ClickPipes는 충분히 명확합니다. `service`와 `datawarehouse` 비용을 더 자세히 볼 수 있는가?

API와 시스템 테이블을 읽기만 합니다. 서비스를 만들거나 바꾸지 않으므로, 실행 중인 서비스에서 2·3단계 쿼리를 돌리는 것 말고는 비용이 들지 않습니다.

### API가 돌려주는 것

`GET /v1/organizations/{organizationId}/usageCost?from_date=…&to_date=…` ([레퍼런스](https://clickhouse.com/docs/products/cloud/api-reference/billing/get-organization-usage-costs)):

- `to_date`는 그날을 포함하고, 범위는 최대 31일입니다. 32일을 요청하면 `400 Time period queried exceeds 31 days`가 돌아오므로 `01-fetch.py`가 긴 범위를 창으로 나눕니다.
- 날짜는 UTC 기준입니다. 응답은 총합 하나와 **일 × 엔티티**별 레코드입니다. 레코드 필드는 `date`, `dataWarehouseId`, `serviceId`(데이터 웨어하우스 레코드에서는 null), `entityType`, `entityId`, `entityName`, `organizationTier`, `locked`, `metrics`, `totalCHC`입니다. `organizationTier`는 실제 응답에는 있지만 공개 스펙에는 없습니다.
- `locked: false`는 아직 확정되지 않은(provisional) 날이라 수치가 바뀔 수 있습니다. 2026-10-02에는 최근 11일(2026-09-21부터)이 잠기지 않은 상태였으니, 하루이틀이 아니라 2주쯤 걸린다고 보세요.
- `filter=tag:Key=Value`로 태그가 붙은 리소스만 볼 수 있습니다.

엔티티 유형마다 메트릭이 다릅니다(2026-10-02에 스펙을 읽었고, 실제 레코드도 모두 같은 구성이었습니다).

| `entityType` | 메트릭 |
|---|---|
| `datawarehouse` | `storageCHC`, `backupCHC` |
| `service` | `computeCHC`, `publicDataTransferCHC`, `interRegionTier1…4DataTransferCHC` |
| `clickpipe` | `computeCHC`, `dataTransferCHC`, `initialLoadCHC` |

### 답

**1. 네, 저장된 데이터는 `datawarehouse` 항목입니다.** ClickHouse Cloud에 저장된 데이터는 `datawarehouse` 레코드의 `storageCHC`로 청구됩니다. AWS에서는 ClickHouse가 관리하는 S3입니다. 백업은 같은 레코드의 `backupCHC`입니다. `service` 레코드에는 스토리지가 없습니다. 데이터 웨어하우스는 서비스와, compute-compute 분리로 만든 자식 서비스들이 함께 쓰는 스토리지이므로 웨어하우스 레코드 하나가 그 모두를 덮습니다.
포함되지 않는 것: 직접 소유하고 `s3()`나 ClickPipes로 읽는 S3 버킷([`labs/s3/`](../../s3/) 참고). 그 비용은 AWS 청구서에 나오고, ClickHouse는 그 주변의 compute와 데이터 전송만 청구합니다.

**2. 네, API의 단위인 일 × 엔티티 × 메트릭까지입니다.**

- `service`: compute, 인터넷 송신, 리전 간 전송(티어 1–4)을 서비스·일별로 각각
- `datawarehouse`: 스토리지와 백업을 웨어하우스·일별로 따로
- `filter=tag:…`로 태그 단위(팀, 환경) 보고서
- 그 아래 단위는 빌링 API에 데이터가 없습니다. 데이터베이스·테이블·사용자·쿼리별 값은 없습니다. `03-allocate.sql`은 시스템 테이블에서 비율을 *추정*해 청구된 CHC를 그 비율대로 나눕니다. 출력에는 청구가 아니라 배분이라고 적습니다.

CHC는 크레딧입니다. 가격은 계약마다 다르므로 이 실습은 CHC로만 보고합니다.

### 권한 (2026-10-02 실측)

| 호출 | 권한(스펙) | 동작한 가장 작은 system 역할 |
|---|---|---|
| `usageCost` (01) | `control-plane:organization:view` | **Member**: 권한이 `organization:view` 하나뿐이고, `organization:view-billing`은 필요 없음 |
| 서비스 백업 (04) | `control-plane:service:view-backups` | **Basic Service Reader**: 같은 키가 Member일 때 `403`, Basic Service Reader일 때 `200` |

Admin 키를 재사용하지 말고 실습 전용 키를 만드세요(Console → Organization → API Keys).

공유 서비스라면 02와 03에 전용 SQL 사용자를 주세요. 관리자로 한 번만 실행합니다.

```sql
CREATE DATABASE billing_hols COMMENT 'clickhouse-cloud-aws-hols labs/billing/usage-cost';
CREATE USER billing_hols IDENTIFIED WITH sha256_hash BY '<비밀번호의-sha256-hex>';
GRANT SHOW, SELECT, INSERT, CREATE DATABASE, CREATE TABLE, DROP TABLE, TRUNCATE, OPTIMIZE
    ON billing_hols.* TO billing_hols;
GRANT SELECT ON system.parts TO billing_hols;
GRANT SELECT ON system.query_log* TO billing_hols;
GRANT SELECT ON system.asynchronous_metric_log* TO billing_hols;
GRANT READ ON REMOTE TO billing_hols;   -- clusterAllReplicas()
GRANT SHOW TABLES, CREATE TEMPORARY TABLE ON *.* TO billing_hols;
```

Cloud SQL 콘솔에서 `GRANT ALL ON billing_hols.*`를 실행하면 실패합니다. 콘솔 사용자가 `CHECK`와 일부 `SYSTEM …` 권한을 넘겨줄 수 없기 때문입니다. 그래서 권한을 하나씩 적었습니다. `READ ON REMOTE`는 `clusterAllReplicas()`가 요구하는 권한입니다. `CREATE TEMPORARY TABLE`은 03의 세션 임시 테이블용입니다. `SHOW TABLES ON *.*`는 모든 테이블의 메타데이터를 보게 하지만 데이터는 읽지 못합니다. `system.parts`에는 그 사용자가 `SHOW`할 수 있는 테이블만 나오므로, 이 권한이 없으면 03은 스토리지를 `system`과 `billing_hols`에만 나눕니다.

### 파일

| 파일 | 하는 일 |
|---|---|
| [`.env.example`](.env.example) | 조직 ID, API 키, 02·03용 서비스 host·user·비밀번호. `.env`로 복사(gitignore 대상, 모드 600) |
| [`chc_api.py`](chc_api.py) | 01과 04가 함께 씀: 설정(환경 변수 먼저, 그다음 `.env`), Basic 인증, 429/5xx 재시도, 31일 이하 창 |
| [`01-fetch.py`](01-fetch.py) | 범위를 창별로 받아 원본 JSON을 `out/`에 저장하고 `out/usage_cost.jsonl`을 쓴 뒤, 유형 × 메트릭별·엔티티별 합계를 출력하고 provisional 날을 표시. 레코드에 그 유형의 메트릭이 아닌 것이 있거나 레코드 합이 총합과 다르면 **실패** |
| [`02-load.sql`](02-load.sql) | jsonl을 전용 DB `billing_hols`에 적재(이 실습이 만들지 않은 `billing_hols`는 거부). (`date`, `entityType`, `entityId`) 키의 `ReplacingMergeTree`라서 provisional 날은 다시 받으면 교체됨. 질문 1·2용 예시 쿼리 |
| [`03-allocate.sql`](03-allocate.sql) | 서비스 하나에서 데이터베이스·테이블별 스토리지 몫과 사용자별 compute 몫을 청구 CHC에 곱하고, *미배분* 줄을 따로 둠. 어느 날이든 배분 + 미배분이 청구 CHC와 다르면 **실패** |
| [`04-backups.py`](04-backups.py) | 서비스별 백업 수와 `sizeInBytes`를 웨어하우스의 `backupCHC` 옆에 출력 |
| [`tests/`](tests/) | 지어낸 데이터로 하는 오프라인 테스트. 모든 검사에 결함 주입 포함 |

`out/`은 gitignore 대상입니다. 실제 엔티티 이름·ID·금액은 그 안에만 남습니다.

### 실행

Python 3.9 이상(표준 라이브러리만)과, 2·3단계용 `clickhouse client`가 필요합니다.

```bash
cd labs/billing/usage-cost
cp .env.example .env && chmod 600 .env    # 그다음 값을 채움
```

**1단계 — 받아서 검사.** 31일보다 긴 범위는 창으로 나뉩니다.

```bash
python3 01-fetch.py --from 2026-08-21 --to 2026-10-01
python3 01-fetch.py --from 2026-09-01 --to 2026-10-01 --filter tag:Environment=Production
```

출력 형식은 English 절의 예시와 같습니다(이름과 숫자는 지어낸 것).

**2단계 — 적재하고 조회.** 실습 디렉터리에서 실행합니다. `INSERT`가 `out/usage_cost.jsonl`을 읽습니다. `clickhouse client`는 `.env`의 `CLICKHOUSE_PASSWORD`에서 비밀번호를 읽으므로(client 26.9에서 확인, 틀린 값이면 인증 실패) 명령줄에 비밀번호가 남지 않습니다. 프롬프트로 받으려면 `--ask-password`를 쓰세요.

```bash
set -a; . ./.env; set +a
clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" --queries-file 02-load.sql
```

**3단계 — 배분.** 배분할 서비스에 접속해서 실행합니다. 서비스 ID는 `out/usage_cost.jsonl`에서 그 서비스의 `service` 행에 있는 `serviceId`입니다.

```bash
clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" \
    --param_service_id=<service-id> --param_from=2026-08-21 --param_to=2026-10-01 \
    --queries-file 03-allocate.sql
```

**4단계 — 백업.** 범위 중에 있었지만 그 뒤 삭제된 서비스는 `404`를 돌려줍니다. 04는 그렇다고 알리고 나머지 서비스를 계속 처리합니다.

```bash
python3 04-backups.py
```

### 03의 배분 방식과 한계

- **스토리지**는 `system.parts`의 데이터베이스·테이블별 활성 `bytes_on_disk` 비율로 나눕니다. 쿼리를 돌린 시점의 스냅샷을 범위의 모든 날에 적용하므로, 범위 중에 커지거나 지워진 테이블도 오늘 크기로 계산됩니다.
- **Compute**는 `system.query_log`의 사용자별 CPU 시간을 서비스 용량(`system.asynchronous_metric_log`의 replica별 `CGroupMaxCPU` × 가동 시간)에 견주어 나눕니다. 끝났거나 실패한 쿼리 행을 모두 셉니다. 측정한 날(2026-10-01)에는 secondary 쿼리(`is_initial_query = 0`)가 하나도 기록되지 않아 겹쳐 셀 것이 없었습니다. parallel replicas를 쓰는 서비스라면 다시 측정하세요. 어떤 쿼리로도 설명되지 않는 부분(idle 가동, merge, 백그라운드 작업)은 따로 *미배분* 줄로 둡니다. 청구된 compute는 있는데 로그 샘플이 없는 날은 전부 미배분으로 표시합니다.
- **로그 교체.** ClickHouse는 업그레이드할 때 시스템 로그 이름을 바꿉니다(`query_log_1`, `query_log_2`, …). 그래서 03은 모든 replica에서 `merge('system', '^query_log(_[0-9]+)?$')`로 읽습니다. 배분할 수 있는 범위는 그 로그가 얼마나 남아 있는지에 달려 있습니다.
- **서비스 하나.** 접속한 서비스의 compute만 배분합니다. 같은 웨어하우스의 다른 서비스는 조회하지 않으므로 그 compute는 사용자별로 나뉘지 않습니다.
- **미배분 줄이 크게 나올 수 있습니다.** Compute는 쿼리가 쓴 CPU가 아니라 프로비저닝 크기 × 가동 시간으로 청구됩니다. 실행해 본 서비스는 하루 종일 켜져 있고 쿼리 부하가 가벼워서, 청구된 compute의 거의 전부가 미배분이었습니다. 쿼리가 쓴 것은 용량의 작은 일부였습니다. 늘 켜진 서비스라면 그게 정직한 답이지 스크립트의 빈틈이 아닙니다.

### 테스트

```bash
python3 tests/test_offline.py
```

네트워크도 서비스도 쓰지 않습니다. 지어낸 픽스처, 가짜 HTTP 계층, 그리고 바이너리가 `PATH`에 있으면 두 SQL 파일을 `clickhouse local`로 돌립니다. 모든 검사를 일부러 깨뜨린 입력에도 돌려서 실패하는지 확인합니다.

### 다루지 않는 것

가격과 통화 환산 · 쿼리별 청구(존재하지 않음) · 서비스 변경 · AWS Cost Explorer(직접 소유한 S3가 나타나는 곳으로만 언급).
