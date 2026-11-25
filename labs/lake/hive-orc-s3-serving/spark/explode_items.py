"""The transform job: explode the JSON items array of item events into one row per item.

Usage: spark-submit explode_items.py <bucket>
Reads game_lake.events_raw (all partitions), writes game_lake.item_events (Hive, ORC, ZLIB,
partitioned by dt). This is the batch form of a JSON-explode job a Spark Streaming pipeline runs.
"""
import sys
import time

from pyspark.sql import SparkSession

bucket = sys.argv[1]
spark = (SparkSession.builder.appName("explode_items")
         .config("hive.exec.dynamic.partition", "true")
         .config("hive.exec.dynamic.partition.mode", "nonstrict")
         .enableHiveSupport().getOrCreate())

spark.sql(f"""
CREATE EXTERNAL TABLE IF NOT EXISTS game_lake.item_events (
  event_id   BIGINT,
  event_time TIMESTAMP,
  player_id  BIGINT,
  server_id  INT,
  platform   STRING,
  event_type STRING,
  item_id    INT,
  qty        INT,
  price      INT)
PARTITIONED BY (dt STRING)
STORED AS ORC
LOCATION 's3://{bucket}/warehouse/game_lake.db/item_events'
TBLPROPERTIES ('orc.compress' = 'ZLIB')
""")

t0 = time.time()
spark.sql("""
INSERT OVERWRITE TABLE game_lake.item_events PARTITION (dt)
SELECT event_id, event_time, player_id, server_id, platform, event_type,
       it.item_id, it.qty, it.price, dt
FROM game_lake.events_raw
LATERAL VIEW explode(from_json(payload, 'items ARRAY<STRUCT<item_id: INT, qty: INT, price: INT>>').items) t AS it
WHERE event_type IN ('purchase', 'gacha', 'item_drop')
""")
elapsed = time.time() - t0
n = spark.sql("SELECT count(*) FROM game_lake.item_events").first()[0]
print(f"RESULT explode_items rows_out={n} seconds={elapsed:.1f}")
