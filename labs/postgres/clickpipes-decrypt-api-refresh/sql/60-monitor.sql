-- What to alert on: refresh status and exception, how far the decrypted table trails raw, rows missing.
SELECT view, status, last_success_time, last_refresh_time, next_refresh_time, exception
FROM system.view_refreshes WHERE database = 'app';
SELECT (SELECT max(_peerdb_synced_at) FROM raw.users) - (SELECT max(_peerdb_synced_at) FROM app.users) AS behind_raw_s,
       (SELECT count() FROM raw.users FINAL WHERE _peerdb_is_deleted = 0) - (SELECT count() FROM app.users FINAL) AS rows_missing;
