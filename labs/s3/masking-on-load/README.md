# Masking sensitive rows while loading from S3 — ClickPipes (Terraform), load-then-UPDATE, or INSERT … SELECT

> **Last run: 2026-10-12** — `deploy.sh` → `destroy.sh` end to end on one ClickHouse Cloud service (AWS `ap-northeast-2`, 2 replicas, ClickHouse 26.6.1.2326), Terraform 1.16.4, provider `ClickHouse/clickhouse` 3.37.0. Source: the public Stack Overflow `users.parquet` in `eu-west-3` (1.36 GB, 22,484,235 rows), read without credentials. The IAM-role path for a private bucket (`iam_role_arn`) was not run.
> Since then: `sql/40-json-fields.sql` (deleting fields inside a JSON string, literal data only) added and run on its own on the same service on 2026-10-12, 29 of 29 cases passing; it creates no pipe and is not part of `deploy.sh`. `41-regex-cost.sh` and `gen_mask_sql.py` (regex masking: per-row patterns vs generated literals) added and run on its own on the same service on 2026-10-13, three times.
>
> **마지막 실행: 2026-10-12** — ClickHouse Cloud 서비스 하나(AWS `ap-northeast-2`, replica 2개, ClickHouse 26.6.1.2326)에서 `deploy.sh` → `destroy.sh`를 끝까지 실행. Terraform 1.16.4, provider `ClickHouse/clickhouse` 3.37.0. 원본은 `eu-west-3`의 공개 Stack Overflow `users.parquet`(1.36 GB, 22,484,235행)를 자격 증명 없이 읽음. 비공개 버킷용 IAM role 경로(`iam_role_arn`)는 실행하지 않음.
> 그 뒤: `sql/40-json-fields.sql`(JSON 문자열 안의 필드 삭제, 리터럴 데이터만)을 추가해 같은 서비스에서 2026-10-12 따로 실행, 29개 사례 모두 통과. 파이프를 만들지 않고 `deploy.sh`에 들어 있지 않음. `41-regex-cost.sh`·`gen_mask_sql.py`(정규식 마스킹: 행마다 만드는 패턴 vs 생성한 상수)를 추가해 같은 서비스에서 2026-10-13 따로 세 번 실행.

[English](#english) | [한국어](#한국어)

## English

Parquet files in S3 hold sensitive columns. The rows that must be masked are already defined by a `WHERE` clause. The load is one-off, with a few retries expected. Should the masking run inside a ClickPipe deployed with Terraform, or should the data be loaded into ClickHouse Cloud first and masked with an `UPDATE`?

This lab runs three ways on the same file and the same rule, and checks every result row by row:

| | Way | What it does |
|---|---|---|
| **A** | ClickPipes, deployed by Terraform | ClickPipe (one-time, `is_continuous = false`) → `users_landing` (`Null` engine) → materialized view with the masking expressions → `users_a` |
| **B** | Load, then update | `INSERT … SELECT FROM s3()` as is → `users_b`, then lightweight `UPDATE … WHERE` (+ `APPLY PATCHES`); `users_b2` gets `ALTER TABLE … UPDATE` instead |
| **C** | `INSERT … SELECT FROM s3()` with the masking expressions | one statement → `users_c` |

The rule stands in for the real one: `LastAccessDate < '2020-01-01'` (dormant accounts, 7,763,456 rows, 34.5%). For those rows `DisplayName` keeps its first character (`u***`), and `AboutMe`, `WebsiteUrl` and `Location` become `NULL`. Swap the rule and the expressions for your own; everything else stays.

### Answer

- **Mask before the rows are stored (A or C), not after (B).** A and C never write a raw value to any table. B ends with the same rows, but the raw values sit in the table from the load until the update is fully applied, and on disk a little longer (below). A [backup](https://clickhouse.com/docs/cloud/manage/backups/overview) taken in that window keeps them for its retention period — on this service a backup runs every 24 hours and is kept 24 hours (`backupConfiguration`, read 2026-10-12).
- **For a one-off load, C is the simplest form of "mask at ingest".** One statement, no pipe, no Terraform state; a retry is `TRUNCATE` and run it again. It was also the fastest here.
- **Choose A (ClickPipes + Terraform)** when files keep arriving (`is_continuous = true`, or an SQS `queue_url`), when the pipe must live in infrastructure code, or when the load is large enough to want ClickPipes to manage the scaling and retries. The masking is the same MV either way.
- **Retries differ.** A's rows appear all at once when the pipe completes (`MOVE PARTITION`, below), so a failed pipe leaves the target as it was. C writes block by block; a C that fails midway leaves the blocks already written (not run here) — `TRUNCATE` before every retry, or split a large load by file and insert one group at a time.

### Results (2026-10-12)

All four tables end identical: `count() = 22,484,235`, `masked = 7,763,456`, `rule_missed = 0`, `leaks = 0`, and the same `sum(cityHash64(<all columns>))` in `users_a`, `users_b`, `users_b2` and `users_c` (`deploy.sh`, last step).

| | Wall time (`deploy.sh` run) | Other runs the same day | Raw values at rest |
|---|---|---|---|
| A ClickPipes + MV | `apply` → `Completed`: 137 s | 149 s, 153 s, 197 s | never — not even in ClickPipes' staging table |
| B lightweight `UPDATE` | load 27.1 s + `UPDATE` 7.8 s + `APPLY PATCHES` 16.1 s | 25 + 8.8 + 20.1 s | from the load until `APPLY PATCHES`; readable with `SETTINGS apply_patch_parts = 0` in between; replaced parts stay on disk afterwards |
| B `ALTER TABLE … UPDATE` | load (same) + mutation 18.2 s | 25 + 18.2 s | from the load until the mutation ends; replaced parts stay on disk afterwards |
| C `INSERT … SELECT FROM s3()` | 25.3 s | 70.7 s (first read of the file), 25.4 s, 42.7 s | never |

Times are single runs on a shared service, source and service in different regions; read them as "seconds vs minutes", not as a benchmark. A includes provisioning the pipe (`Creation complete after 14–23 s`).

What "at rest" means for B, measured on `users_b`:

1. After the lightweight `UPDATE` every normal query shows masked values (`leaks = 0`). The base parts still hold the old ones: with `SETTINGS apply_patch_parts = 0` the same table returns **7,763,456 unmasked names**. Any user with `SELECT` on the table can add that setting.
2. `ALTER TABLE … APPLY PATCHES` rewrites the base parts; after it, the same query returns 0.
3. The parts replaced by `APPLY PATCHES` or by the mutation stay as `active = 0` in `system.parts` for `old_parts_lifetime` (480 s on this service). They were gone from every replica about 10 minutes later. What happens to the objects in the service's storage after that is not visible from SQL.

### How A works (observed in `system.tables` and `system.query_log`)

ClickPipes for object storage does not write straight into the destination. When the pipe starts it creates, in the destination database:

- `s3_clickpipe_buffer_<pipe id>_0` — `Null` engine, the columns of `users_landing`;
- `…_0_mv_0` — **a copy of `users_mask_mv`**, the same `SELECT`;
- `…_0_mv_0_target` — a `SharedMergeTree` with the columns of `users_a`.

The copy of the MV masks each block, so the staging table holds only masked rows (checked mid-load: 5,299,234 rows, 0 raw). When all files are read, ClickPipes runs `ALTER TABLE … MOVE PARTITION ID 'all' TO TABLE users_a` and drops the three tables. `users_a` therefore shows nothing until the load is complete, then all of it at once. ClickPipes also creates `users_landing_clickpipes_error` for rows it could not insert (0 here).

### Guide: run A on your own bucket

1. **Read the source schema** and write the masked `SELECT` first, as a preview — the same expressions go into the MV:

   ```sql
   DESCRIBE s3('https://<bucket>.s3.<region>.amazonaws.com/<prefix>/*.parquet', 'Parquet',
               extra_credentials(role_arn = '<role arn>'));

   WITH <your WHERE condition> AS m
   SELECT if(m, <masked>, col1) AS col1, …, m AS is_masked
   FROM s3('…', 'Parquet', extra_credentials(role_arn = '<role arn>'))
   LIMIT 20;
   ```

2. **Create the landing table, the target and the MV** — adapt [`sql/00-schema.sql`](sql/00-schema.sql). Keep the landing columns as `DESCRIBE` shows them (`Nullable` included); the target's sorting key must not be `Nullable` (`assumeNotNull`). Create the MV **before** the pipe: the pipe copies the MVs it finds when it starts. That is why `managed_table = false` — with a ClickPipes-managed `Null` table there would be no MV yet when the first rows arrive (reasoning, not run).
3. **Private bucket:** create an IAM role that trusts the service's ClickHouse IAM role — [`labs/s3/terraform-chc-secures3-aws`](../terraform-chc-secures3-aws/) does it — and set `iam_role_arn`. The provider then sends `authentication = "IAM_ROLE"`. Not run in this lab.
4. **Deploy the pipe:** set `source_url` (wildcards allowed) and the columns in [`terraform/main.tf`](terraform/main.tf), then

   ```bash
   cd terraform && terraform init && terraform apply
   ```

   Wait for `state` = `Completed` (`GET /v1/organizations/{org}/services/{service}/clickpipes/{id}`, as `deploy.sh` does). `terraform plan` after that shows only the read-only `state` changing.
5. **Verify** with [`sql/90-verify.sql`](sql/90-verify.sql) adapted to your columns, and check `<landing table>_clickpipes_error`.
6. **Retry:** `TRUNCATE TABLE <target>`, change the MV if needed, then `terraform apply -replace=clickhouse_clickpipe.users` (or `destroy` + `apply`). Ran here as `destroy` + `TRUNCATE` + `apply`: same rows and hash. Without the `TRUNCATE`, a second load appends a second copy.
7. **Clean up:** `terraform destroy` removes only the pipe; the loaded rows stay. Drop the landing table and the MV afterwards.

The equivalent C is [`sql/20-c-insert-select.sql`](sql/20-c-insert-select.sql): the same `SELECT` with `INSERT INTO <target>` in front.

### When the sensitive part is a field inside a JSON string

Often the rule does not mask whole columns but deletes a few fields inside a JSON document stored as a string (a request body, an event payload), and there are hundreds of rules, one per endpoint. The answer above does not change — delete while loading, in the MV or the `INSERT … SELECT` — only the expression does. [`sql/40-json-fields.sql`](sql/40-json-fields.sql) checks each piece on literal data (29 cases, 2026-10-12):

1. **Top-level keys.** ClickHouse has no function that removes a JSON key (`system.functions`, 26.6). Rebuild the object from `JSONExtractKeysAndValuesRaw` without the keys to drop, and return the original string when nothing is dropped. This removes the key whatever its value (also `null`) and also when written with spaces (`"key" : …`) — which a `LIKE '%"key":%'` condition would miss, so the condition is not needed.
2. **Nested `class.field` paths.** Two SQL UDFs (`mask_lab_drop_keys`, `mask_lab_drop_paths`) do the same one level down; when the class holds an array of objects they work element by element. A deeper path and broken JSON are left as they are. A SQL UDF created on one replica showed up on both replicas at once (`system.functions`, `origin = SQLUserDefined`); its name is service-wide.
3. **Hundreds of rules.** One row per `(service, endpoint, class, field)` in a table, a `COMPLEX_KEY_HASHED` dictionary keyed by `(service, endpoint)`, and `arrayZip(dictGetOrDefault(…classes…), dictGetOrDefault(…fields…))` per row: only rows with a rule change. For a one-off load a `map(endpoint, [fields…])` literal inside the MV is simpler; a missing key returns an empty array, and changing a rule means changing the MV.
4. **Check after every batch:** rows where a rule's path is still present — `JSONHas(out, class, field)`, and for arrays per element — and rows where `isValidJSON` is 0.

The alternative, a `JSON(SKIP request.class.field, …)` column, never stores the skipped paths, but it applies to every row alike (no per-endpoint rule), it kept fields inside arrays of objects and inside a JSON document encoded as a string, and the column is no longer a `String`.

Not run: these expressions inside an MV fed by ClickPipes (the copied MV calling a UDF or a dictionary), and their cost at scale.

#### Regex instead of rebuilding: keep the patterns constant

A regex that replaces `"key": <value>` with `"key":null` reaches every depth, and also JSON that is itself encoded as a string (`\"key\": …`). The cost depends on whether the pattern is a constant. Building it per row from each key (`concat('"', regexpQuoteMeta(k), …)` inside `arrayFold`) was far slower than the same patterns written as literals. [`41-regex-cost.sh`](41-regex-cost.sh) measures both on 1,000,000 synthetic rows (about 700 bytes each), with 200 rules of two keys and two thirds of the rows matching (ClickHouse Cloud 26.6.1.2326, `max_threads` 2, 2026-10-13, three runs):

| | Time |
|---|---|
| read only (`JSONExtractString`), 1M rows | 0.12–0.16 s |
| generated literals, 1M rows | 1.86–2.72 s |
| patterns built per row, **100k** rows | 7.4–12.6 s |

That is about 40–50 times slower per row; with one rule of three keys and one third of the rows matching, an earlier run measured 79 s against 0.7–0.9 s per 1M rows (about 100 times). The cause — the pattern compiled per row — is inferred from these numbers, not read in the source. [`gen_mask_sql.py`](gen_mask_sql.py) turns a rules CSV (`endpoint,key`) into a `multiIf` with one literal pattern pair per endpoint (endpoints with the same keys share a branch, keys are regex-escaped). On 15 edge cases both forms give the same output. Neither form nulls a value that is itself nested (`{"key":{"a":{…}}}`, `[{"v":[…]}]`) — a residual check (`"key"\s*:\s*[^n\s]`) catches those — or a key stored as `\uXXXX` escapes, which the residual check does not catch.

One pitfall when timing: wrapping the work in `SELECT count() FROM (… GROUP BY …)` let the optimizer skip computing the masked column, and a 54-second query showed 0.46 s.

### Pitfalls

- **`NULL` in the rule means "not masked".** `if(cond, …)` follows `WHERE` semantics, so a row whose condition is `NULL` keeps its values — as it would be skipped by `UPDATE … WHERE`. If such rows must be masked, use `ifNull(<rule>, true)`. The lab source has no `NULL` in `LastAccessDate`.
- **The MV runs as its definer.** On 26.6 `default_materialized_view_sql_security = DEFINER`, so the pipe's user needs `INSERT` on the landing table only; the MV writes to the target with the rights of the user who created it.
- **Read your own writes across replicas.** Right after C, a `count()` landed on the other replica and returned 21,433,136; the same query a moment later returned 22,484,235. Verify with `SETTINGS select_sequential_consistency = 1` (as `90-verify.sql` and `deploy.sh` do).
- **Lightweight `UPDATE` needs table settings** `enable_block_number_column = 1` and `enable_block_offset_column = 1`, and the query setting `enable_lightweight_update = 1` (both `0` by default on this service, read from `system.settings` and `system.merge_tree_settings` 2026-10-12).

### Run notes

- The first `deploy.sh` attempt (08:26 UTC) stopped in step B: the server finished both inserts at 08:31:09 (`system.query_log`), but `clickhouse client` never received the end of the second one and waited on an open connection. It was killed, `destroy.sh` ran, and the run above started from an empty database.
- Cost was not measured. Read at 08:39 UTC, the Usage Cost API record for the first pipe on 2026-10-12 showed `computeCHC`, `dataTransferCHC` and `initialLoadCHC` all `0` with `locked: false` — provisional, so not a cost yet. The `clickpipe` record is where it will show — see [`labs/billing/usage-cost`](../../billing/usage-cost/).

### Files

| File | What |
|---|---|
| `deploy.sh` · `destroy.sh` | the whole comparison · remove the pipe and the `mask_lab` database |
| `sql/00-schema.sql` | database, landing `Null` table, four targets, masking MV |
| `sql/20-c-insert-select.sql` | C |
| `sql/30…34-b-*.sql` | B: raw load, lightweight `UPDATE`, `ALTER TABLE … UPDATE`, residue checks, `APPLY PATCHES` |
| `sql/40-json-fields.sql` | deleting fields inside a JSON string: top-level keys, `class.field` UDFs, rules through a dictionary, `JSON(SKIP …)`; runs on its own |
| `41-regex-cost.sh` · `gen_mask_sql.py` | regex masking cost: per-row patterns vs generated literals; the generator turns `endpoint,key` rules into a `multiIf`; runs on its own |
| `sql/90-verify.sql` | per-table check (`--param_t=<table>`) |
| `terraform/` | the ClickPipe; credentials as `TF_VAR_*` or `terraform.tfvars` (from `terraform.tfvars.example`) |

## 한국어

S3의 Parquet 파일에 민감한 컬럼이 있고, 마스킹할 행은 이미 `WHERE` 절로 정해져 있습니다. 적재는 일회성이고 몇 번의 재시도가 예상됩니다. 마스킹을 Terraform으로 배포한 ClickPipe 안에서 해야 할까요, 아니면 ClickHouse Cloud에 먼저 적재한 뒤 `UPDATE`로 해야 할까요?

이 실습은 같은 파일·같은 규칙으로 세 방식을 돌리고, 결과를 행 단위로 대조합니다.

| | 방식 | 하는 일 |
|---|---|---|
| **A** | ClickPipes, Terraform 배포 | ClickPipe(일회성, `is_continuous = false`) → `users_landing`(`Null` 엔진) → 마스킹식을 담은 materialized view → `users_a` |
| **B** | 적재 후 수정 | `INSERT … SELECT FROM s3()`로 원본 그대로 → `users_b`, 그다음 lightweight `UPDATE … WHERE`(+ `APPLY PATCHES`). `users_b2`는 대신 `ALTER TABLE … UPDATE` |
| **C** | 마스킹식을 넣은 `INSERT … SELECT FROM s3()` | 문장 하나 → `users_c` |

규칙은 실제 규칙의 대역입니다: `LastAccessDate < '2020-01-01'`(휴면 계정, 7,763,456행, 34.5%). 이 행들은 `DisplayName`의 첫 글자만 남기고(`u***`), `AboutMe`·`WebsiteUrl`·`Location`을 `NULL`로 바꿉니다. 규칙과 마스킹식만 바꾸면 나머지는 그대로 씁니다.

### 답

- **저장하기 전에 마스킹합니다(A 또는 C). 저장한 뒤(B)가 아닙니다.** A와 C는 어떤 테이블에도 원본 값을 쓰지 않습니다. B도 최종 행은 같지만, 적재부터 수정이 완전히 반영될 때까지 원본 값이 테이블에 있고, 디스크에는 그보다 조금 더 남습니다(아래). 그 사이에 [백업](https://clickhouse.com/docs/cloud/manage/backups/overview)이 돌면 보존 기간 동안 백업에 남습니다 — 이 서비스는 24시간마다 백업하고 24시간 보존합니다(`backupConfiguration`, 2026-10-12 확인).
- **일회성 적재라면 "적재 시 마스킹"의 가장 단순한 형태는 C입니다.** 문장 하나, 파이프도 Terraform state도 없고, 재시도는 `TRUNCATE` 후 다시 실행입니다. 여기서는 가장 빠르기도 했습니다.
- **A(ClickPipes + Terraform)를 고를 때**: 파일이 계속 들어올 때(`is_continuous = true` 또는 SQS `queue_url`), 파이프를 인프라 코드로 관리해야 할 때, 적재가 커서 확장과 재시도를 ClickPipes에 맡기고 싶을 때입니다. 마스킹은 어느 쪽이든 같은 MV입니다.
- **재시도 방식이 다릅니다.** A의 행은 파이프가 끝날 때 한 번에 보이므로(`MOVE PARTITION`, 아래) 실패한 파이프는 대상 테이블을 그대로 둡니다. C는 블록 단위로 쓰므로 도중에 실패하면 이미 쓴 블록이 남습니다(여기서 실행하지 않음) — 재시도마다 `TRUNCATE`하거나, 큰 적재는 파일 단위로 나눠 한 묶음씩 넣습니다.

### 결과 (2026-10-12)

네 테이블 모두 같게 끝납니다: `count() = 22,484,235`, `masked = 7,763,456`, `rule_missed = 0`, `leaks = 0`, 그리고 `users_a`·`users_b`·`users_b2`·`users_c`의 `sum(cityHash64(<모든 컬럼>))`이 같습니다(`deploy.sh` 마지막 단계).

| | 걸린 시간 (`deploy.sh` 실행) | 같은 날 다른 실행 | 원본 값이 저장되는가 |
|---|---|---|---|
| A ClickPipes + MV | `apply` → `Completed`: 137초 | 149초, 153초, 197초 | 저장 안 됨 — ClickPipes 스테이징 테이블에도 없음 |
| B lightweight `UPDATE` | 적재 27.1초 + `UPDATE` 7.8초 + `APPLY PATCHES` 16.1초 | 25 + 8.8 + 20.1초 | 적재부터 `APPLY PATCHES`까지. 그 사이에는 `SETTINGS apply_patch_parts = 0`으로 조회됨. 교체된 파트는 그 뒤에도 디스크에 남음 |
| B `ALTER TABLE … UPDATE` | 적재(같음) + 뮤테이션 18.2초 | 25 + 18.2초 | 적재부터 뮤테이션 끝까지. 교체된 파트는 그 뒤에도 디스크에 남음 |
| C `INSERT … SELECT FROM s3()` | 25.3초 | 70.7초(파일 첫 읽기), 25.4초, 42.7초 | 저장 안 됨 |

시간은 공유 서비스에서 한 번씩 잰 값이고 원본과 서비스의 리전이 다릅니다. 벤치마크가 아니라 "초 단위냐 분 단위냐"로 읽으세요. A에는 파이프 생성 시간(`Creation complete after 14–23s`)이 들어 있습니다.

B에서 "저장된다"는 뜻(`users_b`에서 측정):

1. lightweight `UPDATE` 직후 일반 조회는 모두 마스킹된 값을 보여 줍니다(`leaks = 0`). 기본 파트에는 옛 값이 그대로 있습니다: 같은 테이블에 `SETTINGS apply_patch_parts = 0`을 붙이면 **마스킹 안 된 이름 7,763,456건**이 나옵니다. 테이블에 `SELECT` 권한이 있으면 누구나 이 설정을 붙일 수 있습니다.
2. `ALTER TABLE … APPLY PATCHES`가 기본 파트를 다시 씁니다. 그 뒤 같은 조회는 0입니다.
3. `APPLY PATCHES`나 뮤테이션이 교체한 파트는 `old_parts_lifetime`(이 서비스 480초) 동안 `system.parts`에 `active = 0`으로 남습니다. 약 10분 뒤 모든 replica에서 사라졌습니다. 그 뒤 서비스 스토리지의 객체가 어떻게 되는지는 SQL로 보이지 않습니다.

### A의 동작 (`system.tables`·`system.query_log`로 관찰)

오브젝트 스토리지 ClickPipes는 대상 테이블에 바로 쓰지 않습니다. 파이프가 시작되면 대상 데이터베이스에 다음을 만듭니다.

- `s3_clickpipe_buffer_<pipe id>_0` — `Null` 엔진, `users_landing`의 컬럼
- `…_0_mv_0` — **`users_mask_mv`의 복사본**, 같은 `SELECT`
- `…_0_mv_0_target` — `users_a`의 컬럼을 가진 `SharedMergeTree`

MV 복사본이 블록마다 마스킹하므로 스테이징 테이블에는 마스킹된 행만 쌓입니다(적재 도중 확인: 5,299,234행, 원본 0건). 모든 파일을 읽으면 ClickPipes가 `ALTER TABLE … MOVE PARTITION ID 'all' TO TABLE users_a`를 실행하고 세 테이블을 지웁니다. 그래서 `users_a`는 적재가 끝날 때까지 비어 있다가 한 번에 전부 보입니다. ClickPipes는 넣지 못한 행을 위해 `users_landing_clickpipes_error`도 만듭니다(여기서는 0건).

### 가이드: 내 버킷에서 A 실행하기

1. **원본 스키마를 읽고** 마스킹 `SELECT`를 먼저 미리보기로 씁니다 — 같은 식이 MV에 들어갑니다.

   ```sql
   DESCRIBE s3('https://<bucket>.s3.<region>.amazonaws.com/<prefix>/*.parquet', 'Parquet',
               extra_credentials(role_arn = '<role arn>'));

   WITH <WHERE 조건> AS m
   SELECT if(m, <마스킹 값>, col1) AS col1, …, m AS is_masked
   FROM s3('…', 'Parquet', extra_credentials(role_arn = '<role arn>'))
   LIMIT 20;
   ```

2. **착지 테이블·대상 테이블·MV를 만듭니다** — [`sql/00-schema.sql`](sql/00-schema.sql)을 고쳐 씁니다. 착지 테이블 컬럼은 `DESCRIBE` 결과 그대로(`Nullable` 포함) 둡니다. 대상 테이블의 정렬 키는 `Nullable`이면 안 됩니다(`assumeNotNull`). MV는 파이프보다 **먼저** 만듭니다: 파이프는 시작할 때 있는 MV를 복사합니다. 그래서 `managed_table = false`입니다 — ClickPipes가 `Null` 테이블을 직접 만들게 하면 첫 행이 들어올 때 MV가 아직 없습니다(추론, 실행하지 않음).
3. **비공개 버킷:** 서비스의 ClickHouse IAM role을 신뢰하는 IAM role을 만들고 — [`labs/s3/terraform-chc-secures3-aws`](../terraform-chc-secures3-aws/)가 만들어 줍니다 — `iam_role_arn`에 넣습니다. 그러면 provider가 `authentication = "IAM_ROLE"`을 보냅니다. 이 실습에서는 실행하지 않았습니다.
4. **파이프 배포:** [`terraform/main.tf`](terraform/main.tf)에 `source_url`(와일드카드 가능)과 컬럼을 맞추고

   ```bash
   cd terraform && terraform init && terraform apply
   ```

   `state`가 `Completed`가 될 때까지 기다립니다(`GET /v1/organizations/{org}/services/{service}/clickpipes/{id}`, `deploy.sh`와 같음). 그 뒤 `terraform plan`에는 읽기 전용 `state` 변경만 나옵니다.
5. **검증:** [`sql/90-verify.sql`](sql/90-verify.sql)을 컬럼에 맞게 고쳐 돌리고, `<착지 테이블>_clickpipes_error`를 확인합니다.
6. **재시도:** `TRUNCATE TABLE <대상>`, 필요하면 MV를 고치고, `terraform apply -replace=clickhouse_clickpipe.users`(또는 `destroy` + `apply`). 여기서는 `destroy` + `TRUNCATE` + `apply`로 실행했고 같은 행·같은 해시가 나왔습니다. `TRUNCATE`를 빼면 두 번째 적재가 한 벌을 더 붙입니다.
7. **정리:** `terraform destroy`는 파이프만 지우고 적재된 행은 남깁니다. 그 뒤 착지 테이블과 MV를 지웁니다.

같은 일을 C로 하면 [`sql/20-c-insert-select.sql`](sql/20-c-insert-select.sql)입니다: 같은 `SELECT` 앞에 `INSERT INTO <대상>`을 붙인 것입니다.

### 민감한 부분이 JSON 문자열 안의 필드일 때

규칙이 컬럼 전체를 마스킹하는 대신, 문자열로 저장된 JSON 문서(요청 본문, 이벤트 페이로드) 안의 필드 몇 개를 지우는 경우가 많습니다. 규칙은 엔드포인트마다 하나씩, 수백 개가 됩니다. 위의 답은 그대로입니다 — MV나 `INSERT … SELECT`에서 적재하면서 지웁니다. 바뀌는 것은 식뿐입니다. [`sql/40-json-fields.sql`](sql/40-json-fields.sql)이 리터럴 데이터로 하나씩 확인합니다(29개 사례, 2026-10-12).

1. **최상위 키.** ClickHouse에는 JSON 키를 지우는 함수가 없습니다(`system.functions`, 26.6). `JSONExtractKeysAndValuesRaw`로 지울 키를 빼고 객체를 다시 조립하고, 지울 것이 없으면 원래 문자열을 그대로 돌려줍니다. 값이 무엇이든(`null`도) 키를 지우고, `"key" : …`처럼 공백이 있어도 지웁니다 — `LIKE '%"key":%'` 조건은 이런 경우를 놓치므로 조건이 필요 없습니다.
2. **중첩 `클래스.필드` 경로.** SQL UDF 두 개(`mask_lab_drop_keys`, `mask_lab_drop_paths`)가 한 단계 아래에서 같은 일을 합니다. 클래스가 객체 배열이면 원소마다 지웁니다. 더 깊은 경로와 깨진 JSON은 그대로 남습니다. SQL UDF는 replica 하나에서 만들면 두 replica에 바로 보였습니다(`system.functions`, `origin = SQLUserDefined`). 이름은 서비스 전체 단위입니다.
3. **규칙 수백 개.** `(service, endpoint, class, field)`를 한 행씩 테이블에 두고, `(service, endpoint)`를 키로 하는 `COMPLEX_KEY_HASHED` 딕셔너리를 만든 뒤, 행마다 `arrayZip(dictGetOrDefault(…classes…), dictGetOrDefault(…fields…))`로 찾습니다. 규칙이 있는 행만 바뀝니다. 일회성 적재라면 MV 안에 `map(endpoint, [필드…])`를 직접 쓰는 편이 단순합니다. 없는 키는 빈 배열이 나오고, 규칙을 바꾸려면 MV를 바꿔야 합니다.
4. **배치마다 확인:** 규칙의 경로가 남은 행 — `JSONHas(out, 클래스, 필드)`, 배열이면 원소마다 — 과 `isValidJSON`이 0인 행.

대안인 `JSON(SKIP request.클래스.필드, …)` 컬럼은 건너뛴 경로를 아예 저장하지 않습니다. 다만 모든 행에 똑같이 적용되고(엔드포인트별 규칙 불가), 객체 배열 안의 필드와 문자열로 한 번 더 감싼 JSON 안의 필드는 남았으며, 컬럼이 더는 `String`이 아닙니다.

실행하지 않은 것: ClickPipes가 채우는 MV 안에서 이 식들(복사된 MV가 UDF나 딕셔너리를 부르는 것), 그리고 대규모에서의 비용.

#### 다시 조립하는 대신 정규식으로: 패턴은 상수로

`"key": <값>`을 `"key":null`로 바꾸는 정규식은 어느 깊이든, 그리고 문자열로 한 번 더 감싼 JSON(`\"key\": …`)까지 닿습니다. 비용은 패턴이 상수인지에 달려 있습니다. 키마다 행에서 패턴을 조립하면(`arrayFold` 안의 `concat('"', regexpQuoteMeta(k), …)`), 같은 패턴을 상수로 쓴 것보다 훨씬 느렸습니다. [`41-regex-cost.sh`](41-regex-cost.sh)가 합성 100만 행(행당 약 700바이트), 키 두 개짜리 규칙 200개, 3분의 2 행이 규칙에 걸리는 조건에서 둘을 잽니다(ClickHouse Cloud 26.6.1.2326, `max_threads` 2, 2026-10-13, 세 번).

| | 시간 |
|---|---|
| 읽기만(`JSONExtractString`), 100만 행 | 0.12–0.16초 |
| 생성한 상수, 100만 행 | 1.86–2.72초 |
| 행마다 만든 패턴, **10만** 행 | 7.4–12.6초 |

행당 약 40–50배 느립니다. 키 세 개짜리 규칙 하나, 3분의 1 행이 걸리는 앞선 실행에서는 100만 행에 79초 대 0.7–0.9초(약 100배)였습니다. 원인(행마다 패턴을 컴파일)은 이 수치에서 추정한 것이고 소스로 확인하지는 않았습니다. [`gen_mask_sql.py`](gen_mask_sql.py)는 규칙 CSV(`endpoint,key`)를 엔드포인트마다 상수 패턴 한 쌍을 가진 `multiIf`로 바꿉니다(키가 같은 엔드포인트는 한 분기로, 키는 정규식 이스케이프). 경계 사례 15개에서 두 형태의 결과가 같았습니다. 두 형태 모두 값 자체가 중첩 구조인 경우(`{"key":{"a":{…}}}`, `[{"v":[…]}]`)는 null로 바꾸지 못하고 — 잔존 검사(`"key"\s*:\s*[^n\s]`)가 잡습니다 — `\uXXXX`로 이스케이프된 키도 바꾸지 못합니다. 이쪽은 잔존 검사에도 안 잡힙니다.

잴 때의 함정 하나: 작업을 `SELECT count() FROM (… GROUP BY …)`로 감싸면 최적화기가 마스킹 컬럼 계산을 건너뛰어, 54초 걸리는 쿼리가 0.46초로 보였습니다.

### 주의할 점

- **규칙이 `NULL`이면 "마스킹 안 함"입니다.** `if(cond, …)`는 `WHERE`와 같은 의미라서, 조건이 `NULL`인 행은 값이 그대로 남습니다 — `UPDATE … WHERE`에서 건너뛰는 것과 같습니다. 그런 행도 마스킹해야 하면 `ifNull(<규칙>, true)`를 씁니다. 실습 원본의 `LastAccessDate`에는 `NULL`이 없습니다.
- **MV는 정의한 사용자 권한으로 돕니다.** 26.6에서 `default_materialized_view_sql_security = DEFINER`이므로 파이프 사용자는 착지 테이블 `INSERT` 권한만 있으면 되고, MV는 MV를 만든 사용자 권한으로 대상 테이블에 씁니다.
- **replica 사이 읽기 일관성.** C 직후 `count()`가 다른 replica로 가서 21,433,136을 돌려줬고, 잠시 뒤 같은 쿼리는 22,484,235였습니다. 검증은 `SETTINGS select_sequential_consistency = 1`로 합니다(`90-verify.sql`·`deploy.sh`와 같음).
- **lightweight `UPDATE`에는 테이블 설정이 필요합니다**: `enable_block_number_column = 1`, `enable_block_offset_column = 1`, 그리고 쿼리 설정 `enable_lightweight_update = 1`(이 서비스에서는 둘 다 기본 `0`, 2026-10-12 `system.settings`·`system.merge_tree_settings`로 확인).

### 실행 메모

- 첫 `deploy.sh` 시도(08:26 UTC)는 B 단계에서 멈췄습니다: 서버는 두 INSERT를 08:31:09에 끝냈지만(`system.query_log`), `clickhouse client`가 두 번째 응답의 끝을 받지 못하고 열린 연결에서 기다렸습니다. 클라이언트를 끊고 `destroy.sh`를 돌린 뒤, 빈 데이터베이스에서 위 실행을 시작했습니다.
- 비용은 재지 않았습니다. 08:39 UTC에 읽은 Usage Cost API의 첫 파이프 2026-10-12 기록은 `computeCHC`·`dataTransferCHC`·`initialLoadCHC`가 모두 `0`이고 `locked: false`였습니다 — 잠정치라 아직 비용이 아닙니다. 비용은 `clickpipe` 기록에 나옵니다 — [`labs/billing/usage-cost`](../../billing/usage-cost/) 참고.

### 파일

| 파일 | 내용 |
|---|---|
| `deploy.sh` · `destroy.sh` | 비교 전체 · 파이프와 `mask_lab` 데이터베이스 삭제 |
| `sql/00-schema.sql` | 데이터베이스, 착지 `Null` 테이블, 대상 테이블 4개, 마스킹 MV |
| `sql/20-c-insert-select.sql` | C |
| `sql/30…34-b-*.sql` | B: 원본 적재, lightweight `UPDATE`, `ALTER TABLE … UPDATE`, 잔존 확인, `APPLY PATCHES` |
| `sql/40-json-fields.sql` | JSON 문자열 안의 필드 삭제: 최상위 키, `클래스.필드` UDF, 딕셔너리를 거친 규칙, `JSON(SKIP …)`. 따로 실행 |
| `41-regex-cost.sh` · `gen_mask_sql.py` | 정규식 마스킹 비용: 행마다 만든 패턴 vs 생성한 상수. 생성기는 `endpoint,key` 규칙을 `multiIf`로 바꿈. 따로 실행 |
| `sql/90-verify.sql` | 테이블별 확인(`--param_t=<table>`) |
| `terraform/` | ClickPipe. 자격 증명은 `TF_VAR_*` 또는 `terraform.tfvars`(`terraform.tfvars.example`에서 복사) |
