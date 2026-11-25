-- Transform path: the same explode job as spark/explode_items.py, run as one INSERT … SELECT
-- straight from the ORC files (no MergeTree copy of the raw events in between).
-- Run: ./ch_run.py sql/30-transform.sql

-- name: t1_table
CREATE TABLE IF NOT EXISTS hive_orc_lab.item_events_batch AS hive_orc_lab.item_events;

-- name: t2_explode
INSERT INTO hive_orc_lab.item_events_batch
SELECT event_id, toDateTime(event_time), player_id, server_id, platform, event_type,
       it.item_id, it.qty, it.price, toDate(dt)
FROM s3('https://{{BUCKET}}.s3.{{REGION}}.amazonaws.com/warehouse/game_lake.db/events_raw/*/*', 'ORC',
        extra_credentials(role_arn = '{{CH_ROLE}}'))
-- payload is Nullable(String) in the ORC schema; JSONExtract into an Array needs a non-Nullable input
ARRAY JOIN JSONExtract(ifNull(payload, ''), 'items', 'Array(Tuple(item_id UInt32, qty UInt16, price UInt32))') AS it
WHERE event_type IN ('purchase', 'gacha', 'item_drop') AND dt <= '2026-10-30';

-- name: t3_check
-- Three counts that should agree: the MV, the batch insert, and the ORC table Spark wrote
SELECT * FROM (
SELECT 'mv (item_events)' AS source, count() AS rows, toInt64(sum(toInt64(qty) * price)) AS value FROM hive_orc_lab.item_events WHERE dt <= '2026-10-30'
UNION ALL
SELECT 'batch (item_events_batch)' AS source, count() AS rows, toInt64(sum(toInt64(qty) * price)) AS value FROM hive_orc_lab.item_events_batch
UNION ALL
SELECT 'spark (game_lake.item_events ORC)' AS source, count() AS rows, toInt64(sum(toInt64(qty) * price)) AS value
FROM s3('https://{{BUCKET}}.s3.{{REGION}}.amazonaws.com/warehouse/game_lake.db/item_events/*/*', 'ORC',
        extra_credentials(role_arn = '{{CH_ROLE}}'))
WHERE dt <= '2026-10-30')
ORDER BY source;
