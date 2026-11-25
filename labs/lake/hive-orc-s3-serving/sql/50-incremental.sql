-- Incremental serving: a refreshable MV appends partitions newer than what MergeTree holds.
-- Run r1 after the 30-day load, write one more day on EMR (03-emr-steps.sh day31), then r2-r4.

-- name: i1_rmv
CREATE MATERIALIZED VIEW IF NOT EXISTS hive_orc_lab.load_new_days
REFRESH EVERY 1 HOUR APPEND TO hive_orc_lab.events AS
SELECT event_id, toDateTime(event_time) AS event_time, player_id, server_id, platform, event_type,
       payload, toDate(dt) AS dt
FROM s3('https://{{BUCKET}}.s3.{{REGION}}.amazonaws.com/warehouse/game_lake.db/events_raw/*/*', 'ORC',
        extra_credentials(role_arn = '{{CH_ROLE}}'))
WHERE toDate(dt) > (SELECT max(dt) FROM hive_orc_lab.events);

-- name: i2_refresh
SYSTEM REFRESH VIEW hive_orc_lab.load_new_days;

-- name: i3_wait
SYSTEM WAIT VIEW hive_orc_lab.load_new_days;

-- name: i4_status
SELECT view, status, last_success_time, last_refresh_time, next_refresh_time, read_rows, written_rows, exception
FROM system.view_refreshes WHERE database = 'hive_orc_lab';

-- name: i5_days
SELECT * FROM (
    SELECT 'events' AS t, dt, count() AS rows FROM hive_orc_lab.events WHERE dt >= '2026-10-29' GROUP BY dt
    UNION ALL
    SELECT 'item_events' AS t, dt, count() AS rows FROM hive_orc_lab.item_events WHERE dt >= '2026-10-29' GROUP BY dt)
ORDER BY t, dt;
