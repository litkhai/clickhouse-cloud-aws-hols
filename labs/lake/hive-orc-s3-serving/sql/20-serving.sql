-- Serving path: load the lake into MergeTree. The MV explodes item events on the way in.
-- Run: ./ch_run.py sql/20-serving.sql

-- name: s1_events
CREATE TABLE IF NOT EXISTS hive_orc_lab.events
(
    event_id   UInt64,
    event_time DateTime,
    player_id  UInt64,
    server_id  UInt16,
    platform   LowCardinality(String),
    event_type LowCardinality(String),
    payload    String CODEC(ZSTD(3)),
    dt         Date
)
ENGINE = MergeTree
PARTITION BY dt
ORDER BY (event_type, dt, player_id);

-- name: s1_items
CREATE TABLE IF NOT EXISTS hive_orc_lab.item_events
(
    event_id   UInt64,
    event_time DateTime,
    player_id  UInt64,
    server_id  UInt16,
    platform   LowCardinality(String),
    event_type LowCardinality(String),
    item_id    UInt32,
    qty        UInt16,
    price      UInt32,
    dt         Date
)
ENGINE = MergeTree
PARTITION BY dt
ORDER BY (event_type, item_id, dt);

-- name: s1_mv
-- The transform as a materialized view: one row per element of payload.items
CREATE MATERIALIZED VIEW IF NOT EXISTS hive_orc_lab.explode_items_mv TO hive_orc_lab.item_events AS
SELECT event_id, event_time, player_id, server_id, platform, event_type,
       it.item_id AS item_id, it.qty AS qty, it.price AS price, dt
FROM hive_orc_lab.events
ARRAY JOIN JSONExtract(payload, 'items', 'Array(Tuple(item_id UInt32, qty UInt16, price UInt32))') AS it
WHERE event_type IN ('purchase', 'gacha', 'item_drop');

-- name: s2_load
-- 30 days of raw events from the Hive table's ORC files; the MV fills item_events in the same insert
INSERT INTO hive_orc_lab.events
SELECT event_id, toDateTime(event_time), player_id, server_id, platform, event_type, payload, toDate(dt)
FROM s3('https://{{BUCKET}}.s3.{{REGION}}.amazonaws.com/warehouse/game_lake.db/events_raw/*/*', 'ORC',
        extra_credentials(role_arn = '{{CH_ROLE}}'))
WHERE dt <= '2026-10-30';

-- name: s3_counts
SELECT * FROM (
    SELECT 'events' AS t, count() AS rows FROM hive_orc_lab.events
    UNION ALL SELECT 'item_events' AS t, count() AS rows FROM hive_orc_lab.item_events)
ORDER BY t;

-- name: s3_sizes
-- Stored size in ClickHouse (compressed) next to the ORC bytes on S3 (sql/10: r2 files)
SELECT table, sum(rows) AS rows, formatReadableSize(sum(data_compressed_bytes)) AS compressed,
       formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed, count() AS parts
FROM system.parts
WHERE database = 'hive_orc_lab' AND active
GROUP BY table ORDER BY table;

-- name: s3_orc_bytes
SELECT 'events_raw' AS hive_table, formatReadableSize(sum(_size)) AS orc_bytes, count() AS files
FROM (SELECT DISTINCT _path, _size
      FROM s3('https://{{BUCKET}}.s3.{{REGION}}.amazonaws.com/warehouse/game_lake.db/events_raw/*/*', 'One',
              extra_credentials(role_arn = '{{CH_ROLE}}')));
