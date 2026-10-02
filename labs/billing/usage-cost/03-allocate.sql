-- 03-allocate.sql: spread one service's billed CHC over databases (storage) and
-- users (compute), using shares estimated from system tables.
--
-- THIS IS AN ALLOCATION, NOT A BILL. The billing API has no data below
-- day x entity x metric: nothing per database, table, user or query. The shares
-- below are estimates from system tables, multiplied by the CHC that was billed.
-- Amounts are CHC (credits), not currency.
--
-- Needs 02-load.sql to have run (reads billing_hols.usage_cost). Run it connected
-- to the ONE service you want to allocate, from the lab directory:
--
--     set -a; . ./.env; set +a      # .env sets CLICKHOUSE_PASSWORD (mode 600, never committed)
--     clickhouse client --host <host> --secure --user <user> \
--         --param_service_id=<service-uuid> --param_from=YYYY-MM-DD --param_to=YYYY-MM-DD \
--         --queries-file 03-allocate.sql
--
-- clickhouse client 26.9 reads CLICKHOUSE_PASSWORD from the environment (measured
-- 2026-10-02, see 02-load.sql); `--ask-password` is the alternative.
--
-- Grants the SQL user needs besides SELECT on billing_hols.usage_cost and the
-- system tables below: SHOW TABLES ON *.* (system.parts lists only the tables the
-- user may SHOW) and CREATE TEMPORARY TABLE ON *.* (for the tmp_* tables).
--
-- Only this service's compute is allocated. Other services on the same data
-- warehouse are not queried; they appear only as part of the shared storage.
--
-- The script keeps its working data in TEMPORARY tables (session only, no
-- database). It writes nothing to billing_hols, `default` or any other database.
-- It needs one client session for the whole file, which `clickhouse client
-- --queries-file` provides; the temporary tables are named tmp_* below.
--
-- Run on 2026-10-02 (ClickHouse 26.6.1.2191, 2 replicas) for 2026-08-21 ..
-- 2026-10-01: 42 days in about 32 s; the final check held (largest difference
-- 3.6e-15).

SELECT arrayJoin([
    'ALLOCATION, NOT A BILL: billed CHC spread by shares estimated from system tables.',
    concat('service ', {service_id:String}, ', ', toString({from:Date}), ' .. ', toString({to:Date}), ' (UTC days)'),
    'storage: share of active bytes_on_disk per database (system.parts, a snapshot taken now, applied to every day).',
    'compute: CPU seconds per user (system.query_log) over CGroupMaxCPU capacity (system.asynchronous_metric_log); the rest is unallocated.',
    'days with locked = false are provisional: the billed figures may still change.'
]) AS notice
FORMAT TSVRaw;

-- Guard: the billed rows must be there, and the service must sit on one warehouse.
SELECT
    throwIf(
        count() = 0,
        'no service rows in billing_hols.usage_cost for this service and range; run 01-fetch.py and 02-load.sql first, or check the parameters'
    ) AS has_rows,
    throwIf(
        uniqExact(dataWarehouseId) > 1,
        'this service has more than one dataWarehouseId in the range; allocate a narrower range'
    ) AS one_warehouse
FROM billing_hols.usage_cost FINAL
WHERE entityType = 'service'
  AND serviceId = {service_id:String}
  AND date BETWEEN {from:Date} AND {to:Date}
FORMAT Null;

-- Billed CHC per day: this service's compute, and the storage of its data
-- warehouse. Storage is a warehouse item (a `datawarehouse` row), not a service
-- one; the warehouse id comes from this service's `service` rows. A datawarehouse
-- row is matched on dataWarehouseId or on entityId, whichever the API fills.
CREATE TEMPORARY TABLE tmp_billed ENGINE = Memory AS
WITH
    svc AS
    (
        SELECT
            date                         AS day,
            any(dataWarehouseId)         AS warehouse_id,
            sum(computeCHC)              AS compute_billed,
            min(locked)                  AS locked
        FROM billing_hols.usage_cost FINAL
        WHERE entityType = 'service'
          AND serviceId = {service_id:String}
          AND date BETWEEN {from:Date} AND {to:Date}
        GROUP BY day
    ),
    wh AS
    (
        SELECT
            date                         AS day,
            sum(storageCHC)              AS storage_billed
        FROM billing_hols.usage_cost FINAL
        WHERE entityType = 'datawarehouse'
          AND date BETWEEN {from:Date} AND {to:Date}
          AND (
                dataWarehouseId IN (SELECT warehouse_id FROM svc)
             OR entityId        IN (SELECT warehouse_id FROM svc)
          )
        GROUP BY day
    )
SELECT
    svc.day                              AS day,
    svc.locked                           AS locked,
    svc.compute_billed                   AS compute_billed,
    wh.storage_billed                    AS storage_billed
FROM svc
LEFT JOIN wh ON wh.day = svc.day
SETTINGS join_use_nulls = 0;

-- Storage: active bytes per database and table. Snapshot at query time.
--
-- This reads the replica the client is connected to and is NOT wrapped in
-- clusterAllReplicas. Measured 2026-10-02 (ClickHouse 26.6.1.2191, 2 replicas):
-- sum(bytes_on_disk) of the active parts over clusterAllReplicas('default',
-- system.parts), divided by the local sum, was 1.997 with 2 replicas. Every
-- replica reports the same parts, so the local system.parts is right; summing
-- across replicas would count each part once per replica.
-- system.parts lists only the tables the user may SHOW: without SHOW TABLES ON
-- *.* the storage is shared out among the visible databases only.
CREATE TEMPORARY TABLE tmp_parts ENGINE = Memory AS
SELECT
    database,
    `table`,
    sum(bytes_on_disk)                   AS bytes
FROM system.parts
WHERE active
GROUP BY database, `table`;

CREATE TEMPORARY TABLE tmp_db ENGINE = Memory AS
SELECT
    d.database                           AS database,
    d.db_bytes                           AS bytes,
    if(t.total > 0, d.db_bytes / t.total, 0) AS share
FROM (SELECT database, sum(bytes) AS db_bytes FROM tmp_parts GROUP BY database) AS d
CROSS JOIN (SELECT sum(bytes) AS total FROM tmp_parts) AS t;

-- Every day's storage CHC is shared out with the same snapshot shares. The shares
-- sum to 1, so allocated storage equals billed storage on every day. With no
-- active parts there is nothing to share out and the final check fails.
CREATE TEMPORARY TABLE tmp_alloc_storage ENGINE = Memory AS
SELECT
    d.day                                AS day,
    p.database                           AS database,
    p.bytes                              AS bytes,
    p.share * d.storage_billed           AS allocated_chc
FROM tmp_billed AS d
CROSS JOIN tmp_db AS p;

-- Compute, numerator: CPU seconds per day and user. type IN (...) keeps the
-- finished and failed queries; QueryStart rows carry no counters.
--
-- Rotated logs: the system logs are renamed on upgrade (query_log, query_log_1 ...
-- query_log_7), so merge() reads every table whose name matches the pattern.
-- Measured 2026-10-02 on ClickHouse 26.6.1.2191: merge() works over query_log ..
-- query_log_7 and over asynchronous_metric_log*, 43 days, with every column used
-- here. The fallback below was not needed on 26.6. If merge() fails on another
-- version because the rotated tables have different columns, replace the
-- merge(...) call with a UNION ALL of explicit columns, for example:
--     SELECT type, event_date, event_time, user, ProfileEvents
--       FROM clusterAllReplicas('default', system.query_log)
--     UNION ALL
--     SELECT type, event_date, event_time, user, ProfileEvents
--       FROM clusterAllReplicas('default', system.query_log_1)
--     ... through query_log_7
-- Every finished or failed row is counted, not only is_initial_query = 1. Measured
-- on 2026-10-01 (ClickHouse 26.6.1.2191, 2 replicas): 0 of 292,780 such rows had
-- is_initial_query = 0. No query was logged as a secondary query, so nothing can
-- be counted twice here. Measure it again on a service that uses parallel
-- replicas before relying on this there.
-- The logs may not reach back over the whole range; a day with no rows is flagged
-- below. clusterAllReplicas reads the replicas that answer when the query runs.
CREATE TEMPORARY TABLE tmp_user_cpu ENGINE = Memory AS
SELECT
    toDate(event_time, 'UTC')            AS day,
    user,
    sum((ProfileEvents['UserTimeMicroseconds'] + ProfileEvents['SystemTimeMicroseconds']) / 1e6) AS cpu_s
FROM clusterAllReplicas('default', merge('system', '^query_log(_[0-9]+)?$'))
WHERE type IN ('QueryFinish', 'ExceptionWhileProcessing')
  AND event_date BETWEEN {from:Date} - 1 AND {to:Date} + 1
  AND event_time >= toDateTime({from:Date}, 'UTC')
  AND event_time <  toDateTime({to:Date}, 'UTC') + INTERVAL 1 DAY
GROUP BY day, user;

-- Compute, denominator: capacity in core-seconds per day = sum over replicas and
-- samples of CGroupMaxCPU x the sample interval. The interval is not assumed: it
-- is the median gap between consecutive samples of that replica on that day
-- (gaps of 0, such as two samples within one second, are ignored). Stretches
-- when a replica was not running have no samples and add no capacity.
-- Measured 2026-10-02: the hostname column is present, CGroupMaxCPU is 2 on both
-- replicas, the median sample gap is 1 s, and a replica logs about 86,400 samples
-- a day.
-- The same merge() fallback applies to asynchronous_metric_log (not needed on 26.6).
CREATE TEMPORARY TABLE tmp_capacity ENGINE = Memory AS
SELECT
    day,
    uniqExact(hostname)                  AS replicas,
    sum(samples)                         AS samples,
    sum(core_seconds)                    AS capacity_s
FROM
(
    SELECT
        hostname,
        day,
        count()                          AS samples,
        sum(value) * quantileExactIf(0.5)(gap_s, gap_s > 0) AS core_seconds
    FROM
    (
        SELECT
            hostname,
            toDate(event_time, 'UTC')    AS day,
            value,
            toInt64(event_time) - toInt64(lagInFrame(event_time, 1, event_time) OVER w) AS gap_s
        FROM clusterAllReplicas('default', merge('system', '^asynchronous_metric_log(_[0-9]+)?$'))
        WHERE metric = 'CGroupMaxCPU'
          AND event_date BETWEEN {from:Date} - 1 AND {to:Date} + 1
          AND event_time >= toDateTime({from:Date}, 'UTC')
          AND event_time <  toDateTime({to:Date}, 'UTC') + INTERVAL 1 DAY
        WINDOW w AS (
            PARTITION BY hostname, toDate(event_time, 'UTC')
            ORDER BY event_time
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )
    )
    GROUP BY hostname, day
)
GROUP BY day;

-- One row per billed day. chc_per_cpu_s is what one CPU second is worth that
-- day: billed compute over the capacity, or over the CPU seconds themselves when
-- they exceed the capacity (the shares are scaled down to fit). A day with
-- billed compute and no capacity samples is entirely unallocated.
-- compute_unallocated is the day-level closed form of "billed minus allocated";
-- the allocation below is built per user, so the final check compares two
-- separate computations.
CREATE TEMPORARY TABLE tmp_day ENGINE = Memory AS
SELECT
    b.day                                AS day,
    b.locked                             AS locked,
    b.compute_billed                     AS compute_billed,
    b.storage_billed                     AS storage_billed,
    c.cpu_s                              AS cpu_s,
    k.capacity_s                         AS capacity_s,
    k.replicas                           AS replicas,
    multiIf(
        b.compute_billed > 0 AND k.capacity_s <= 0, 'no system log',
        c.cpu_s > k.capacity_s,                     'cpu above capacity: shares scaled down',
        ''
    )                                    AS flag,
    if(k.capacity_s > 0, b.compute_billed / greatest(k.capacity_s, c.cpu_s), 0) AS chc_per_cpu_s,
    if(k.capacity_s > 0, b.compute_billed * (1 - least(1, c.cpu_s / k.capacity_s)), b.compute_billed) AS compute_unallocated
FROM tmp_billed AS b
LEFT JOIN (SELECT day, sum(cpu_s) AS cpu_s FROM tmp_user_cpu GROUP BY day) AS c ON c.day = b.day
LEFT JOIN tmp_capacity AS k ON k.day = b.day
SETTINGS join_use_nulls = 0;

CREATE TEMPORARY TABLE tmp_alloc_user ENGINE = Memory AS
SELECT
    u.day                                AS day,
    u.user                               AS user,
    u.cpu_s                              AS cpu_s,
    u.cpu_s * d.chc_per_cpu_s            AS allocated_chc
FROM tmp_user_cpu AS u
INNER JOIN tmp_day AS d ON d.day = u.day;

-- Output 1: storage per database over the range. Estimate: share of active bytes
-- times the storage CHC billed over the range.
SELECT '== 1. Storage per database (allocation, not a bill) ==' AS title FORMAT TSVRaw;

SELECT
    if(db = '', 'total', db)                                      AS database,
    formatReadableSize(sum(bytes))                                AS active_size,
    sum(bytes)                                                    AS bytes_on_disk,
    round(100 * sum(share), 2)                                    AS share_pct,
    round(sum(allocated_chc), 6)                                  AS allocated_storage_chc
FROM
(
    SELECT p.database AS db, p.bytes AS bytes, p.share AS share, sum(a.allocated_chc) AS allocated_chc
    FROM tmp_db AS p
    LEFT JOIN tmp_alloc_storage AS a ON a.database = p.database
    GROUP BY p.database, p.bytes, p.share
)
GROUP BY db WITH ROLLUP
ORDER BY db = '' ASC, bytes_on_disk DESC
FORMAT PrettyCompact;

SELECT '== 1b. Largest tables (up to 50) ==' AS title FORMAT TSVRaw;

SELECT
    database,
    `table`,
    formatReadableSize(bytes)                                     AS active_size,
    round(100 * bytes / (SELECT sum(bytes) FROM tmp_parts), 2)    AS share_pct,
    round(bytes / (SELECT sum(bytes) FROM tmp_parts) * (SELECT sum(storage_billed) FROM tmp_day), 6) AS allocated_storage_chc
FROM tmp_parts
ORDER BY bytes DESC
LIMIT 50
FORMAT PrettyCompact;

-- Output 2: compute per user over the range, plus what no query explains.
SELECT '== 2. Compute per user (allocation, not a bill) ==' AS title FORMAT TSVRaw;

SELECT
    who,
    round(cpu_s, 1)                                               AS cpu_seconds,
    round(compute_chc, 6)                                         AS compute_chc,
    round(100 * compute_chc / nullIf(total_billed, 0), 2)         AS share_pct,
    note
FROM
(
    SELECT
        user AS who, 0 AS ord, sum(cpu_s) AS cpu_s, sum(allocated_chc) AS compute_chc,
        '' AS note, (SELECT sum(compute_billed) FROM tmp_day) AS total_billed
    FROM tmp_alloc_user
    GROUP BY user
    UNION ALL
    SELECT
        'unallocated: idle uptime, merges, background work', 1, 0, sum(compute_unallocated),
        if(countIf(flag = 'no system log') > 0,
           concat('includes ', toString(countIf(flag = 'no system log')), ' day(s) flagged no system log'), ''),
        sum(compute_billed)
    FROM tmp_day
    UNION ALL
    SELECT 'total billed compute', 2, 0, sum(compute_billed), '', sum(compute_billed)
    FROM tmp_day
)
ORDER BY ord, compute_chc DESC
FORMAT PrettyCompact;

-- Output 3: per day, billed against allocated and unallocated, compute and
-- storage. The *_diff columns are billed - allocated - unallocated.
SELECT '== 3. Per day: billed = allocated + unallocated ==' AS title FORMAT TSVRaw;

CREATE TEMPORARY TABLE tmp_check ENGINE = Memory AS
SELECT
    d.day                                                         AS day,
    d.compute_billed                                              AS compute_billed,
    a.allocated                                                   AS compute_allocated,
    d.compute_unallocated                                         AS compute_unallocated,
    d.storage_billed                                              AS storage_billed,
    s.allocated                                                   AS storage_allocated,
    toFloat64(0)                                                  AS storage_unallocated,
    d.replicas                                                    AS replicas,
    d.capacity_s                                                  AS capacity_s,
    d.cpu_s                                                       AS cpu_s,
    if(d.locked, '', 'provisional')                               AS provisional,
    d.flag                                                        AS flag
FROM tmp_day AS d
LEFT JOIN (SELECT day, sum(allocated_chc) AS allocated FROM tmp_alloc_user GROUP BY day) AS a ON a.day = d.day
LEFT JOIN (SELECT day, sum(allocated_chc) AS allocated FROM tmp_alloc_storage GROUP BY day) AS s ON s.day = d.day
SETTINGS join_use_nulls = 0;

SELECT
    day,
    round(compute_billed, 6)                                      AS compute_billed,
    round(compute_allocated, 6)                                   AS compute_allocated,
    round(compute_unallocated, 6)                                 AS compute_unallocated,
    round(compute_billed - compute_allocated - compute_unallocated, 9) AS compute_diff,
    round(storage_billed, 6)                                      AS storage_billed,
    round(storage_allocated, 6)                                   AS storage_allocated,
    round(storage_billed - storage_allocated - storage_unallocated, 9) AS storage_diff,
    replicas,
    round(capacity_s)                                             AS capacity_core_s,
    round(cpu_s)                                                  AS cpu_s,
    provisional,
    flag
FROM tmp_check
ORDER BY day
FORMAT PrettyCompact;

-- Output 4: the run fails if any day does not add up.
SELECT throwIf(
    max(abs(compute_billed - compute_allocated - compute_unallocated)) > 1e-6
    OR max(abs(storage_billed - storage_allocated - storage_unallocated)) > 1e-6,
    'billed CHC differs from allocated + unallocated on at least one day; see the per-day table above'
) AS check_failed
FROM tmp_check
FORMAT Null;

SELECT concat(
    'check ok: on every one of ', toString(count()), ' day(s), billed = allocated + unallocated for compute and storage (largest difference ',
    toString(greatest(max(abs(compute_billed - compute_allocated - compute_unallocated)), max(abs(storage_billed - storage_allocated - storage_unallocated)))),
    ' CHC)'
) AS result
FROM tmp_check
FORMAT TSVRaw;
