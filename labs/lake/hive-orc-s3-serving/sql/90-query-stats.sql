-- Duration, rows, bytes and S3 files of every statement ch_run.py ran (query_id hol-…), from both replicas.
-- Run soon after the statements: Cloud may replace replicas, and query_log goes with them.
-- name: stats
SELECT query_id,
       hostName() AS replica,
       event_time,
       round(query_duration_ms / 1000, 2) AS seconds,
       read_rows,
       formatReadableSize(read_bytes) AS read,
       written_rows,
       formatReadableSize(memory_usage) AS memory,
       ProfileEvents['EngineFileLikeReadFiles'] AS files_read,
       ProfileEvents['S3GetObject'] AS s3_get,
       ProfileEvents['S3ListObjects'] AS s3_list,
       ProfileEvents['UserTimeMicroseconds'] / 1e6 AS cpu_user_s,
       exception_code
FROM clusterAllReplicas(default, system.query_log)
WHERE query_id LIKE 'hol-%' AND query_id NOT LIKE 'hol-stats-%' AND type IN ('QueryFinish', 'ExceptionBeforeStart', 'ExceptionWhileProcessing')
  AND event_date >= today() - 1
ORDER BY event_time
FORMAT TSVWithNames;
