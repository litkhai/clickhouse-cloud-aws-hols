-- Every 10 s: send what arrived since the target's watermark to the decrypt API (through the UDF) and APPEND it.
-- Same watermark as clickpipes-kms-decrypt-refresh: one minute of overlap so a late-committed ClickPipes insert
-- is not skipped, and an anti-join on (user_id, _peerdb_version) so nothing is decrypted twice.
-- A failed refresh (API down, token refused) leaves the watermark, so the next refresh retries the same rows.
-- max_block_size bounds the rows per UDF process (one process per block).
CREATE MATERIALIZED VIEW IF NOT EXISTS app.users_rmv
REFRESH EVERY 10 SECOND APPEND TO app.users AS
SELECT user_id, tenant_id, external_user_id, encrypted_email, encrypted_phone_number,
       CAST(p, 'JSON') AS user_properties,
       updated_at, _peerdb_synced_at, _peerdb_version, _peerdb_is_deleted
FROM (
    SELECT *, api_decrypt_props(tenant_id, encrypted_user_properties) AS p
    FROM raw.users
    WHERE _peerdb_synced_at >= (SELECT max(_peerdb_synced_at) FROM app.users) - INTERVAL 1 MINUTE
      AND (user_id, _peerdb_version) NOT IN (
          SELECT user_id, _peerdb_version FROM app.users
          WHERE _peerdb_synced_at >= (SELECT max(_peerdb_synced_at) FROM app.users) - INTERVAL 1 MINUTE)
)
SETTINGS input_format_try_infer_dates = 0, input_format_try_infer_datetimes = 0, max_block_size = 8192;
