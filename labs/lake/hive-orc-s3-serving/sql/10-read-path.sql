-- Read path: can ClickHouse Cloud read the Hive tables (ORC on S3, catalog in Glue) where they are?
-- Run: ./ch_run.py sql/10-read-path.sql   (r4-r6 are expected to fail; their errors are the result)

-- name: r0_database
CREATE DATABASE IF NOT EXISTS hive_orc_lab;

-- name: r1_schema
-- The ORC schema plus `dt` from the dt=YYYY-MM-DD directories (use_hive_partitioning = 1, default on 26.x)
DESCRIBE s3('https://{{BUCKET}}.s3.{{REGION}}.amazonaws.com/warehouse/game_lake.db/events_raw/*/*', 'ORC',
            extra_credentials(role_arn = '{{CH_ROLE}}'));

-- name: r2_partitions
SELECT dt, count() AS rows, uniqExact(_path) AS files
FROM s3('https://{{BUCKET}}.s3.{{REGION}}.amazonaws.com/warehouse/game_lake.db/events_raw/*/*', 'ORC',
        extra_credentials(role_arn = '{{CH_ROLE}}'))
GROUP BY dt ORDER BY dt;

-- name: r3_pruning
-- A filter on the partition column should open only that day's files (see 90-query-stats: files read)
SELECT event_type, count() AS n
FROM s3('https://{{BUCKET}}.s3.{{REGION}}.amazonaws.com/warehouse/game_lake.db/events_raw/*/*', 'ORC',
        extra_credentials(role_arn = '{{CH_ROLE}}'))
WHERE dt = '2026-10-15'
GROUP BY event_type ORDER BY n DESC;

-- name: r4_hive_engine
-- Hive table engine (Hive Metastore thrift + HDFS). The address does not matter: the check comes first.
CREATE TABLE hive_orc_lab.hive_probe (player_id Int64, dt String)
ENGINE = Hive('thrift://10.255.255.1:9083', 'game_lake', 'events_raw') PARTITION BY dt;

-- name: r5_hdfs
SELECT count() FROM hdfs('hdfs://10.255.255.1:8020/warehouse/game_lake.db/events_raw/*/*', 'ORC');

-- name: r6_glue_catalog
-- DataLakeCatalog over Glue: does it list and read the Hive (non-Iceberg) tables?
CREATE DATABASE IF NOT EXISTS hive_orc_glue
ENGINE = DataLakeCatalog
SETTINGS catalog_type = 'glue', region = '{{REGION}}', aws_role_arn = '{{CH_ROLE}}';

-- name: r6_glue_show
SHOW TABLES FROM hive_orc_glue;

-- name: r6_glue_select
SELECT count() FROM hive_orc_glue.`game_lake.events_raw`;

-- name: r7_s3_engine
-- An S3 table engine over the same files: a named table over the lake, dt as a virtual column
CREATE TABLE IF NOT EXISTS hive_orc_lab.events_raw_s3
(
    event_id   Int64,
    event_time DateTime64(9),
    player_id  Int64,
    server_id  Int32,
    platform   String,
    event_type String,
    payload    String
)
ENGINE = S3('https://{{BUCKET}}.s3.{{REGION}}.amazonaws.com/warehouse/game_lake.db/events_raw/*/*', 'ORC',
            extra_credentials(role_arn = '{{CH_ROLE}}'));

-- name: r7_s3_engine_select
SELECT dt, count() AS n, uniqExact(player_id) AS players
FROM hive_orc_lab.events_raw_s3
WHERE dt BETWEEN '2026-10-14' AND '2026-10-16'
GROUP BY dt ORDER BY dt;

-- name: r8_glue_iceberg_show
-- Positive control: one day copied to an Iceberg table with Athena CTAS (README, step 3b).
-- The same catalog database then lists and reads it.
SHOW TABLES FROM hive_orc_glue;

-- name: r8_glue_iceberg_select
SELECT event_type, count() AS n FROM hive_orc_glue.`game_lake.events_iceberg` GROUP BY event_type ORDER BY n DESC;
