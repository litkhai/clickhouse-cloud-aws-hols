-- Refresh queries that called the UDF: rows read, duration, rows/s (query_log).
SYSTEM FLUSH LOGS;
SELECT event_time, query_duration_ms / 1000 AS s, written_rows, round(written_rows / greatest(query_duration_ms / 1000, 0.001)) AS rows_per_s,
       type, substring(exception, 1, 120) AS exception
FROM system.query_log
WHERE has(used_executable_user_defined_functions, 'api_decrypt_props') AND query_kind = 'Insert' AND type != 'QueryStart'
  AND event_time > now() - INTERVAL {minutes:UInt32} MINUTE AND (written_rows > 0 OR type != 'QueryFinish')
ORDER BY event_time;
