-- BI queries, same logic as spark/bi_queries.py. q*_mt read MergeTree; q*_s3 read the ORC files.
-- Run: ./ch_run.py sql/40-bi-queries.sql --runs 3   (the query cache is off for every query)

-- name: q1_mt
SELECT dt, platform, uniqExact(player_id) AS dau
FROM hive_orc_lab.events WHERE dt BETWEEN '2026-10-24' AND '2026-10-30'
GROUP BY dt, platform ORDER BY dt, platform
SETTINGS use_query_cache = 0;

-- name: q2_mt
SELECT item_id, sum(toUInt64(qty) * price) AS revenue, count() AS n
FROM hive_orc_lab.item_events WHERE event_type = 'purchase' AND dt <= '2026-10-30'
GROUP BY item_id ORDER BY revenue DESC, item_id LIMIT 10
SETTINGS use_query_cache = 0;

-- name: q3_mt
SELECT event_type, server_id, count() AS n
FROM hive_orc_lab.events WHERE dt = '2026-10-15'
GROUP BY event_type, server_id ORDER BY n DESC, event_type, server_id LIMIT 20
SETTINGS use_query_cache = 0;

-- name: q4_mt
SELECT player_id, sum(toUInt64(qty) * price) AS spend
FROM hive_orc_lab.item_events WHERE event_type IN ('purchase', 'gacha') AND dt <= '2026-10-30'
GROUP BY player_id ORDER BY spend DESC, player_id LIMIT 20
SETTINGS use_query_cache = 0;

-- name: q5_mt
SELECT toStartOfHour(event_time) AS h, count() AS n
FROM hive_orc_lab.events WHERE dt BETWEEN '2026-10-24' AND '2026-10-30' AND event_type = 'login'
GROUP BY h ORDER BY h
SETTINGS use_query_cache = 0;

-- name: q1_s3
SELECT dt, platform, uniqExact(player_id) AS dau
FROM s3('https://{{BUCKET}}.s3.{{REGION}}.amazonaws.com/warehouse/game_lake.db/events_raw/*/*', 'ORC',
        extra_credentials(role_arn = '{{CH_ROLE}}'))
WHERE dt BETWEEN '2026-10-24' AND '2026-10-30'
GROUP BY dt, platform ORDER BY dt, platform
SETTINGS use_query_cache = 0;

-- name: q2_s3
SELECT item_id, sum(toUInt64(qty) * price) AS revenue, count() AS n
FROM s3('https://{{BUCKET}}.s3.{{REGION}}.amazonaws.com/warehouse/game_lake.db/item_events/*/*', 'ORC',
        extra_credentials(role_arn = '{{CH_ROLE}}'))
WHERE event_type = 'purchase' AND dt <= '2026-10-30'
GROUP BY item_id ORDER BY revenue DESC, item_id LIMIT 10
SETTINGS use_query_cache = 0;

-- name: q3_s3
SELECT event_type, server_id, count() AS n
FROM s3('https://{{BUCKET}}.s3.{{REGION}}.amazonaws.com/warehouse/game_lake.db/events_raw/*/*', 'ORC',
        extra_credentials(role_arn = '{{CH_ROLE}}'))
WHERE dt = '2026-10-15'
GROUP BY event_type, server_id ORDER BY n DESC, event_type, server_id LIMIT 20
SETTINGS use_query_cache = 0;

-- name: q4_s3
SELECT player_id, sum(toUInt64(qty) * price) AS spend
FROM s3('https://{{BUCKET}}.s3.{{REGION}}.amazonaws.com/warehouse/game_lake.db/item_events/*/*', 'ORC',
        extra_credentials(role_arn = '{{CH_ROLE}}'))
WHERE event_type IN ('purchase', 'gacha') AND dt <= '2026-10-30'
GROUP BY player_id ORDER BY spend DESC, player_id LIMIT 20
SETTINGS use_query_cache = 0;

-- name: q5_s3
SELECT toStartOfHour(event_time) AS h, count() AS n
FROM s3('https://{{BUCKET}}.s3.{{REGION}}.amazonaws.com/warehouse/game_lake.db/events_raw/*/*', 'ORC',
        extra_credentials(role_arn = '{{CH_ROLE}}'))
WHERE dt BETWEEN '2026-10-24' AND '2026-10-30' AND event_type = 'login'
GROUP BY h ORDER BY h
SETTINGS use_query_cache = 0;
