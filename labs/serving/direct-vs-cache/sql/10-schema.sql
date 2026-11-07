-- Schema for labs/serving/direct-vs-cache (run by 10-ch-setup.sh before the load).
-- Materialized views exist before the load, so the load fills the pre-aggregated tables too.

CREATE DATABASE IF NOT EXISTS cachelab;

-- Raw events. The sort key serves the ad-hoc filters (country, device) and time ranges;
-- the projection serves point lookups by user_id (S2 arm `ch`).
CREATE TABLE IF NOT EXISTS cachelab.events
(
    ts          DateTime,
    user_id     UInt32,
    campaign_id UInt16,
    country     LowCardinality(String),
    device      LowCardinality(String),
    event_type  LowCardinality(String),
    revenue     Float64,
    PROJECTION p_user (SELECT * ORDER BY user_id, ts)
)
ENGINE = MergeTree
PARTITION BY toDate(ts)
ORDER BY (country, device, ts);

-- Per-user stats (S2 arms `ch-agg`, `vk-aside`, `ddb-aside`, and the source of `vk-kv` / `ddb-kv`).
CREATE TABLE IF NOT EXISTS cachelab.user_stats
(
    user_id UInt32,
    events  SimpleAggregateFunction(sum, UInt64),
    revenue SimpleAggregateFunction(sum, Float64),
    last_ts SimpleAggregateFunction(max, DateTime)
)
ENGINE = AggregatingMergeTree
ORDER BY user_id;

CREATE MATERIALIZED VIEW IF NOT EXISTS cachelab.user_stats_mv TO cachelab.user_stats AS
SELECT user_id, count() AS events, sum(revenue) AS revenue, max(ts) AS last_ts
FROM cachelab.events
GROUP BY user_id;

-- Per-minute rollup for the dashboard tiles (S3 arm `ch-agg`). No campaign_id: with it the
-- rollup would be about as large as the raw table.
CREATE TABLE IF NOT EXISTS cachelab.events_1m
(
    minute     DateTime,
    country    LowCardinality(String),
    device     LowCardinality(String),
    event_type LowCardinality(String),
    events     SimpleAggregateFunction(sum, UInt64),
    revenue    SimpleAggregateFunction(sum, Float64),
    users      AggregateFunction(uniq, UInt32),
    newest     SimpleAggregateFunction(max, DateTime)
)
ENGINE = AggregatingMergeTree
PARTITION BY toDate(minute)
ORDER BY (minute, country, device, event_type);

CREATE MATERIALIZED VIEW IF NOT EXISTS cachelab.events_1m_mv TO cachelab.events_1m AS
SELECT toStartOfMinute(ts) AS minute, country, device, event_type,
       count() AS events, sum(revenue) AS revenue, uniqState(user_id) AS users, max(ts) AS newest
FROM cachelab.events
GROUP BY minute, country, device, event_type;
