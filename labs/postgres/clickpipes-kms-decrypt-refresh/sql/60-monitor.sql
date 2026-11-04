-- What to alert on when decryption runs in refreshable MVs: refresh status and how far each table trails raw.
SELECT view, status, last_success_time, last_refresh_time, next_refresh_time, exception
FROM system.view_refreshes WHERE database = 'app' ORDER BY view;

SELECT 'users_kms' AS target,
       (SELECT max(_peerdb_synced_at) FROM raw.users) - (SELECT max(_peerdb_synced_at) FROM app.users_kms) AS behind_raw_s,
       (SELECT count() FROM raw.users FINAL WHERE _peerdb_is_deleted = 0) - (SELECT count() FROM app.users_kms FINAL) AS rows_missing
UNION ALL
SELECT 'users_dict',
       (SELECT max(_peerdb_synced_at) FROM raw.users) - (SELECT max(_peerdb_synced_at) FROM app.users_dict),
       (SELECT count() FROM raw.users FINAL WHERE _peerdb_is_deleted = 0) - (SELECT count() FROM app.users_dict FINAL);
