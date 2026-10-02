-- Made-up stand-ins for the system tables 03-allocate.sql reads, in a database
-- called fx. tests/test_offline.py points 03-allocate.sql at them (clickhouse
-- local has no query_log and no cluster). Matches the fixture usage_cost_response.json.
--
-- Times are written in UTC and stored in Asia/Tokyo columns, like a server whose
-- time zone is not UTC: 03 must still cut its days at UTC midnight.
--
--   2026-09-29  capacity 4800 core-s (2 replicas x 10 samples x 60 s x 4 cores)
--               cpu 1200 s (alice 900, bob 300)      -> 25% of 40 CHC allocated
--   2026-09-30  capacity 4800, cpu 6000 s (alice 4500, bob 1500) -> above capacity,
--               shares scaled down, all 48 CHC allocated
--   2026-10-01  no CGroupMaxCPU samples at all (carol has 100 s of queries)
--               -> "no system log", all 24 CHC unallocated
--   dave: queries just outside the range (2026-09-28 23:59:59 and 2026-10-02 00:00:00 UTC)
--         that must not show up anywhere.

CREATE DATABASE fx;

-- active = 0 rows must be ignored; db_a is 600 of 1000 active bytes.
CREATE TABLE fx.parts
(
    database String, `table` String, bytes_on_disk UInt64, active UInt8
) ENGINE = Memory;

INSERT INTO fx.parts VALUES
    ('db_a',   't1', 400, 1),
    ('db_a',   't2', 200, 1),
    ('db_a',   't1', 5000, 0),
    ('db_b',   't3', 300, 1),
    ('system', 'query_log', 100, 1);

CREATE TABLE fx.query_log
(
    type Enum8('QueryStart' = 1, 'QueryFinish' = 2, 'ExceptionBeforeStart' = 3, 'ExceptionWhileProcessing' = 4),
    event_date Date,
    event_time DateTime('Asia/Tokyo'),
    user String,
    ProfileEvents Map(String, UInt64)
) ENGINE = Memory;

-- rotated copy: the 03 pattern must read it too
CREATE TABLE fx.query_log_1 AS fx.query_log;
-- NOT a rotated copy: the pattern must not read it
CREATE TABLE fx.query_log_copy AS fx.query_log;

-- alice 900 s on 09-29 = 800 user + 100 system. The QueryStart and
-- ExceptionBeforeStart rows carry a huge value that must not be counted.
INSERT INTO fx.query_log
SELECT ty, toDate(ts, 'Asia/Tokyo'), ts, u, map('UserTimeMicroseconds', user_us, 'SystemTimeMicroseconds', system_us)
FROM values('ty String, ts DateTime(\'UTC\'), u String, user_us UInt64, system_us UInt64',
    ('QueryFinish',          '2026-09-29 10:00:00', 'alice',   800000000,    100000000),
    ('QueryStart',           '2026-09-29 10:00:00', 'alice',   999000000000, 0),
    ('ExceptionBeforeStart', '2026-09-29 10:00:01', 'alice',   999000000000, 0),
    ('QueryFinish',          '2026-09-29 11:00:00', 'bob',     150000000,    0),
    -- 2026-09-30: 6000 s against a capacity of 4800; bob's 23:59:59 UTC is already 10-01 in Tokyo
    ('QueryFinish',          '2026-09-30 09:00:00', 'alice',   4000000000,   500000000),
    ('QueryFinish',          '2026-09-30 23:59:59', 'bob',     1500000000,   0),
    -- 2026-10-01: queries but no capacity samples
    ('QueryFinish',          '2026-10-01 08:00:00', 'carol',   100000000,    0),
    -- outside the range, either side
    ('QueryFinish',          '2026-09-28 23:59:59', 'dave',    777000000,    0),
    ('QueryFinish',          '2026-10-02 00:00:00', 'dave',    777000000,    0));

-- bob's other 150 s of 09-29, in the rotated table, at 23:30 UTC (= 08:30 on the 30th in Tokyo)
INSERT INTO fx.query_log_1
SELECT ty, toDate(ts, 'Asia/Tokyo'), ts, u, map('UserTimeMicroseconds', user_us, 'SystemTimeMicroseconds', system_us)
FROM values('ty String, ts DateTime(\'UTC\'), u String, user_us UInt64, system_us UInt64',
    ('ExceptionWhileProcessing', '2026-09-29 23:30:00', 'bob', 100000000, 50000000));

-- poison: the decoy table must stay out of every sum
INSERT INTO fx.query_log_copy
SELECT ty, toDate(ts, 'Asia/Tokyo'), ts, u, map('UserTimeMicroseconds', user_us)
FROM values('ty String, ts DateTime(\'UTC\'), u String, user_us UInt64',
    ('QueryFinish', '2026-09-29 10:00:00', 'mallory', 900000000000));

CREATE TABLE fx.asynchronous_metric_log
(
    hostname LowCardinality(String), event_date Date, event_time DateTime('Asia/Tokyo'),
    metric LowCardinality(String), value Float64
) ENGINE = Memory;

-- 10 samples a minute apart per replica and day, 4 cores
INSERT INTO fx.asynchronous_metric_log
SELECT host, toDate(ts, 'Asia/Tokyo'), ts, 'CGroupMaxCPU', 4
FROM
(
    SELECT host, toDateTime(day, 'UTC') + number * 60 AS ts
    FROM numbers(10) AS n
    CROSS JOIN (SELECT arrayJoin(['replica-a', 'replica-b']) AS host) AS h
    CROSS JOIN (SELECT arrayJoin(['2026-09-29', '2026-09-30']) AS day) AS d
);

-- other metrics must be ignored, on all three days
INSERT INTO fx.asynchronous_metric_log
SELECT 'replica-a', toDate(ts, 'Asia/Tokyo'), ts, 'Uptime', 99999
FROM
(
    SELECT toDateTime(day, 'UTC') + number * 60 AS ts
    FROM numbers(10) AS n
    CROSS JOIN (SELECT arrayJoin(['2026-09-29', '2026-09-30', '2026-10-01']) AS day) AS d
);
