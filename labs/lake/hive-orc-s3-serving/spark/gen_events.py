"""Write game-log-like events into a Hive table (ORC, ZLIB, partitioned by dt) on S3.

Usage: spark-submit gen_events.py <bucket> <first_day YYYY-MM-DD> <days> <rows_per_day>
The table is a Hive external table in the Glue database `game_lake` (Glue is the Hive metastore
on this cluster). Each day is written by 4 tasks, so each dt= directory holds 4 ORC files.
Re-running with the same days overwrites those partitions only.
"""
import sys
import time

from pyspark.sql import SparkSession

bucket, first_day, days, per_day = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
spark = (SparkSession.builder.appName(f"gen_events {first_day} x{days}")
         .config("hive.exec.dynamic.partition", "true")
         .config("hive.exec.dynamic.partition.mode", "nonstrict")
         .enableHiveSupport().getOrCreate())

spark.sql(f"""
CREATE EXTERNAL TABLE IF NOT EXISTS game_lake.events_raw (
  event_id   BIGINT,
  event_time TIMESTAMP,
  player_id  BIGINT,
  server_id  INT,
  platform   STRING,
  event_type STRING,
  payload    STRING)
PARTITIONED BY (dt STRING)
STORED AS ORC
LOCATION 's3://{bucket}/warehouse/game_lake.db/events_raw'
TBLPROPERTIES ('orc.compress' = 'ZLIB')
""")

# Day offset of the first id, so a later run (one more day) continues the id sequence.
offset = int(spark.sql(f"SELECT datediff(DATE'{first_day}', DATE'2026-10-01')").first()[0])
start, end = offset * per_day, (offset + days) * per_day
spark.range(start, end, numPartitions=days * 4).createOrReplaceTempView("ids")

# Event mix: 30% login, 15% stage_clear, 15% pvp_match, 15% item_drop, 10% purchase, 10% gacha,
# 5% logout. Item events carry a JSON array of items (purchase 1-3, item_drop 1-4, gacha 1 or 10).
spark.sql(f"""
CREATE OR REPLACE TEMP VIEW ev AS
SELECT id,
       date_format(date_add(DATE'2026-10-01', CAST(id DIV {per_day} AS INT)), 'yyyy-MM-dd') AS dt,
       pmod(xxhash64(id, 2), 2000000) + 1 AS player_id,
       pmod(xxhash64(id, 3), 100)          AS r
FROM ids
""")
spark.sql("""
CREATE OR REPLACE TEMP VIEW ev2 AS
SELECT *,
       CASE WHEN r < 30 THEN 'login' WHEN r < 45 THEN 'stage_clear' WHEN r < 60 THEN 'pvp_match'
            WHEN r < 75 THEN 'item_drop' WHEN r < 85 THEN 'purchase' WHEN r < 95 THEN 'gacha'
            ELSE 'logout' END AS event_type,
       CASE WHEN r BETWEEN 60 AND 74 THEN 1 + CAST(pmod(xxhash64(id, 4), 4) AS INT)
            WHEN r BETWEEN 75 AND 84 THEN 1 + CAST(pmod(xxhash64(id, 4), 3) AS INT)
            WHEN r BETWEEN 85 AND 94 THEN IF(pmod(xxhash64(id, 4), 2) = 0, 1, 10)
            ELSE 0 END AS n_items
FROM ev
""")

t0 = time.time()
spark.sql("""
INSERT OVERWRITE TABLE game_lake.events_raw PARTITION (dt)
SELECT id AS event_id,
       timestamp_seconds(unix_timestamp(dt, 'yyyy-MM-dd') + pmod(xxhash64(id, 1), 86400)) AS event_time,
       player_id,
       CAST(pmod(player_id, 64) + 1 AS INT) AS server_id,
       CASE WHEN pmod(player_id, 10) < 6 THEN 'android' WHEN pmod(player_id, 10) < 9 THEN 'ios' ELSE 'pc' END AS platform,
       event_type,
       IF(n_items > 0,
          to_json(named_struct(
            'session_id', hex(xxhash64(player_id, dt)),
            'stage', CAST(pmod(xxhash64(id, 5), 300) + 1 AS INT),
            'currency', 'KRW',
            'items', transform(sequence(1, n_items), i -> named_struct(
                'item_id', CAST(pmod(xxhash64(id, i), 5000) + 1 AS INT),
                'qty',     CAST(pmod(xxhash64(id, i, 7), 5) + 1 AS INT),
                'price',   CASE event_type WHEN 'purchase' THEN CAST((pmod(xxhash64(id, i, 8), 20) + 1) * 1100 AS INT)
                                           WHEN 'gacha' THEN 300 ELSE 0 END)))),
          to_json(named_struct(
            'session_id', hex(xxhash64(player_id, dt)),
            'stage', CAST(pmod(xxhash64(id, 5), 300) + 1 AS INT),
            'duration_s', CAST(pmod(xxhash64(id, 6), 1800) AS INT)))) AS payload,
       dt
FROM ev2
""")
print(f"RESULT gen_events rows={end - start} days={days} first_day={first_day} seconds={time.time() - t0:.1f}")
