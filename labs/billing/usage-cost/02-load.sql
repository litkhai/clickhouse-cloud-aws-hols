-- 02-load.sql: load the flattened usage-cost records into a dedicated database
-- and run the example queries for the two questions of the lab.
--
-- Run from the lab directory (the INSERT reads out/usage_cost.jsonl, written by
-- 01-fetch.py, relative to the directory you run it from):
--
--     set -a; . ./.env; set +a      # .env sets CLICKHOUSE_PASSWORD (mode 600, never committed)
--     clickhouse client --host <host> --secure --user <user> \
--         --queries-file 02-load.sql
--
-- Password: clickhouse client 26.9 reads CLICKHOUSE_PASSWORD from the environment.
-- Measured 2026-10-02 against a ClickHouse Cloud service: the login succeeds with
-- it, and a wrong value fails with AUTHENTICATION_FAILED. That keeps the password
-- off the command line, where `--password <password>` would show in the process
-- list. The alternative is `--ask-password`, which prompts:
--
--     clickhouse client --host <host> --secure --user <user> --ask-password \
--         --queries-file 02-load.sql
--
-- The only database touched is billing_hols, created here. Nothing is written to
-- `default` or to any other database. Amounts are CHC (credits), not currency.

-- Guard: refuse to continue if a database named billing_hols exists that this lab
-- did not create. The comment is the marker. No row matches on a clean server and
-- on a re-run, so throwIf passes; it throws when the comment differs.
SELECT throwIf(
    count() > 0,
    'database billing_hols already exists and was not created by this lab (its comment differs); refusing to write to it'
) AS guard
FROM system.databases
WHERE name = 'billing_hols'
  AND comment != 'clickhouse-cloud-aws-hols labs/billing/usage-cost'
FORMAT Null;

CREATE DATABASE IF NOT EXISTS billing_hols
COMMENT 'clickhouse-cloud-aws-hols labs/billing/usage-cost';

-- One row per day x entity, the shape 01-fetch.py writes. ReplacingMergeTree keeps
-- the row with the greatest fetched_at per (date, entityType, entityId), so a
-- provisional day (locked = false) is replaced once it is fetched again. Merges
-- happen in the background: read with FINAL until then.
CREATE TABLE IF NOT EXISTS billing_hols.usage_cost
(
    date                              Date,
    entityType                        LowCardinality(String),
    entityId                          String,
    entityName                        String,
    serviceId                         String,          -- '' for datawarehouse rows
    dataWarehouseId                   String,
    organizationTier                  LowCardinality(String),
    locked                            Bool,            -- false: provisional
    totalCHC                          Float64,
    -- datawarehouse
    storageCHC                        Float64,
    backupCHC                         Float64,
    -- service (computeCHC is shared with clickpipe)
    computeCHC                        Float64,
    publicDataTransferCHC             Float64,
    interRegionTier1DataTransferCHC   Float64,
    interRegionTier2DataTransferCHC   Float64,
    interRegionTier3DataTransferCHC   Float64,
    interRegionTier4DataTransferCHC   Float64,
    -- clickpipe
    dataTransferCHC                   Float64,
    initialLoadCHC                    Float64,
    fetched_at                        DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(fetched_at)
ORDER BY (date, entityType, entityId)
COMMENT 'usage cost per day and entity, in CHC; clickhouse-cloud-aws-hols labs/billing/usage-cost';

INSERT INTO billing_hols.usage_cost FROM INFILE 'out/usage_cost.jsonl' FORMAT JSONEachRow;

-- Q1a. Is storage the datawarehouse item? Storage and backup appear only on
-- datawarehouse rows; service and clickpipe rows carry 0 in both columns.
SELECT
    entityType,
    count()                AS records,
    sum(storageCHC)        AS storageCHC,
    sum(backupCHC)         AS backupCHC
FROM billing_hols.usage_cost FINAL
GROUP BY entityType
ORDER BY entityType
FORMAT PrettyCompact;

-- Q1b. Per data warehouse over the loaded range: storage against backup. One
-- warehouse record covers the storage of every service that shares it.
SELECT
    entityName                                                       AS warehouse,
    min(date)                                                        AS first_day,
    max(date)                                                        AS last_day,
    sum(storageCHC)                                                  AS storage_chc,
    sum(backupCHC)                                                   AS backup_chc,
    round(100 * sum(backupCHC) / nullIf(sum(storageCHC) + sum(backupCHC), 0), 1) AS backup_pct_of_total
FROM billing_hols.usage_cost FINAL
WHERE entityType = 'datawarehouse'
GROUP BY entityName, entityId
ORDER BY warehouse
FORMAT PrettyCompact;

-- Q2a. Per service and day: compute, internet egress (public transfer) and the
-- four inter-region transfer tiers, each in its own column.
SELECT
    entityName                          AS service,
    date,
    computeCHC                          AS compute,
    publicDataTransferCHC               AS public_transfer,
    interRegionTier1DataTransferCHC     AS inter_region_t1,
    interRegionTier2DataTransferCHC     AS inter_region_t2,
    interRegionTier3DataTransferCHC     AS inter_region_t3,
    interRegionTier4DataTransferCHC     AS inter_region_t4,
    totalCHC,
    if(locked, '', 'provisional')       AS note
FROM billing_hols.usage_cost FINAL
WHERE entityType = 'service'
ORDER BY service, date
FORMAT PrettyCompact;

-- Q2b. Each category's share of the range total, per service.
SELECT
    service,
    category,
    chc,
    round(100 * chc / nullIf(sum(chc) OVER (PARTITION BY service), 0), 2) AS share_pct
FROM
(
    SELECT
        entityName                  AS service,
        cat.1                       AS category,
        round(sum(cat.2), 6)        AS chc
    FROM billing_hols.usage_cost FINAL
    ARRAY JOIN
    [
        ('compute',            computeCHC),
        ('public transfer',    publicDataTransferCHC),
        ('inter-region tier 1', interRegionTier1DataTransferCHC),
        ('inter-region tier 2', interRegionTier2DataTransferCHC),
        ('inter-region tier 3', interRegionTier3DataTransferCHC),
        ('inter-region tier 4', interRegionTier4DataTransferCHC)
    ] AS cat
    WHERE entityType = 'service'
    GROUP BY service, category
)
ORDER BY service, chc DESC, category
FORMAT PrettyCompact;

-- Q2c. The same shares over all services together.
SELECT
    category,
    chc,
    round(100 * chc / nullIf(sum(chc) OVER (), 0), 2) AS share_pct
FROM
(
    SELECT
        cat.1                       AS category,
        round(sum(cat.2), 6)        AS chc
    FROM billing_hols.usage_cost FINAL
    ARRAY JOIN
    [
        ('compute',            computeCHC),
        ('public transfer',    publicDataTransferCHC),
        ('inter-region tier 1', interRegionTier1DataTransferCHC),
        ('inter-region tier 2', interRegionTier2DataTransferCHC),
        ('inter-region tier 3', interRegionTier3DataTransferCHC),
        ('inter-region tier 4', interRegionTier4DataTransferCHC)
    ] AS cat
    WHERE entityType = 'service'
    GROUP BY category
)
ORDER BY chc DESC, category
FORMAT PrettyCompact;
