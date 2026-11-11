-- Does the bloom filter skip granules for a ciphertext lookup? (without and with FINAL)
EXPLAIN indexes = 1 SELECT user_id FROM app.users WHERE encrypted_email = {emails:Array(String)}[1];
SELECT user_id FROM app.users WHERE encrypted_email = {emails:Array(String)}[1] SETTINGS log_comment = 'lookup-nofinal';
SELECT user_id FROM app.users FINAL WHERE encrypted_email = {emails:Array(String)}[1] SETTINGS log_comment = 'lookup-final';
SYSTEM FLUSH LOGS;
SELECT log_comment, read_rows, query_duration_ms FROM system.query_log
WHERE log_comment LIKE 'lookup-%' AND type = 'QueryFinish' AND event_time > now() - INTERVAL 5 MINUTE ORDER BY event_time;
