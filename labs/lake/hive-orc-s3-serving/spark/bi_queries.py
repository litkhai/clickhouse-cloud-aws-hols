"""Run the five BI queries (same logic as sql/40-bi-queries.sql) on Spark SQL over the Hive ORC tables.

Usage: spark-submit bi_queries.py <bucket> <runs>
Prints one RESULT line per query and run, and writes the result rows of the last run to
s3://<bucket>/results/spark/<query>/ (CSV) so they can be compared with ClickHouse.
"""
import sys
import time

from pyspark.sql import SparkSession

bucket, runs = sys.argv[1], int(sys.argv[2])
spark = SparkSession.builder.appName("bi_queries").enableHiveSupport().getOrCreate()

QUERIES = {
    "q1_dau_by_platform": """
        SELECT dt, platform, count(DISTINCT player_id) AS dau
        FROM game_lake.events_raw WHERE dt BETWEEN '2026-10-24' AND '2026-10-30'
        GROUP BY dt, platform ORDER BY dt, platform""",
    "q2_top_items_revenue": """
        SELECT item_id, sum(CAST(qty AS BIGINT) * price) AS revenue, count(*) AS n
        FROM game_lake.item_events WHERE event_type = 'purchase'
        GROUP BY item_id ORDER BY revenue DESC, item_id LIMIT 10""",
    "q3_one_day_by_server": """
        SELECT event_type, server_id, count(*) AS n
        FROM game_lake.events_raw WHERE dt = '2026-10-15'
        GROUP BY event_type, server_id ORDER BY n DESC, event_type, server_id LIMIT 20""",
    "q4_top_spenders": """
        SELECT player_id, sum(CAST(qty AS BIGINT) * price) AS spend
        FROM game_lake.item_events WHERE event_type IN ('purchase', 'gacha')
        GROUP BY player_id ORDER BY spend DESC, player_id LIMIT 20""",
    "q5_hourly_logins": """
        SELECT date_trunc('HOUR', event_time) AS h, count(*) AS n
        FROM game_lake.events_raw WHERE dt BETWEEN '2026-10-24' AND '2026-10-30' AND event_type = 'login'
        GROUP BY date_trunc('HOUR', event_time) ORDER BY h""",
}

for run in range(1, runs + 1):
    for name, sql in QUERIES.items():
        t0 = time.time()
        rows = spark.sql(sql).collect()
        print(f"RESULT {name} run={run} rows={len(rows)} seconds={time.time() - t0:.2f}")
        if run == runs:
            spark.createDataFrame(rows).coalesce(1).write.mode("overwrite").option("header", True) \
                .csv(f"s3://{bucket}/results/spark/{name}/")
