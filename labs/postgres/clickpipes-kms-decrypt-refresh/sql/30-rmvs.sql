-- Refreshable MVs: every 10 s, decrypt what arrived since the target's watermark and APPEND it.
-- The window starts one minute before max(_peerdb_synced_at) so a ClickPipes insert that committed late
-- (the initial load inserts in parallel) is not skipped, and the anti-join on (user_id, _peerdb_version)
-- keeps rows already decrypted out of the window — without it every refresh re-decrypted the last minute
-- (the whole 1,000,000-row snapshot here, measured 2026-11-04).
-- A failed refresh leaves the watermark where it was, so the next one retries the same rows.
CREATE MATERIALIZED VIEW IF NOT EXISTS app.users_kms_rmv
REFRESH EVERY 10 SECOND APPEND TO app.users_kms AS
SELECT user_id, tenant_id, external_user_id,
       JSONExtractString(r, 'email') AS email, JSONExtractString(r, 'phone') AS phone,
       CAST(JSONExtractRaw(r, 'properties'), 'JSON') AS properties,
       updated_at, _peerdb_synced_at, _peerdb_version, _peerdb_is_deleted
FROM (
    SELECT *, kms_decrypt_row(edk, email_enc, phone_enc, properties) AS r
    FROM raw.users
    WHERE _peerdb_synced_at >= (SELECT max(_peerdb_synced_at) FROM app.users_kms) - INTERVAL 1 MINUTE
      AND (user_id, _peerdb_version) NOT IN (
          SELECT user_id, _peerdb_version FROM app.users_kms
          WHERE _peerdb_synced_at >= (SELECT max(_peerdb_synced_at) FROM app.users_kms) - INTERVAL 1 MINUTE)
)
SETTINGS input_format_try_infer_dates = 0, input_format_try_infer_datetimes = 0;

CREATE MATERIALIZED VIEW IF NOT EXISTS app.users_dict_rmv
REFRESH EVERY 10 SECOND APPEND TO app.users_dict AS
SELECT user_id, tenant_id, external_user_id,
       dec_val(email_enc, k) AS email, dec_val(phone_enc, k) AS phone,
       CAST(toJSONString(dec_props(properties, k)), 'JSON') AS properties,
       updated_at, _peerdb_synced_at, _peerdb_version, _peerdb_is_deleted
FROM (
    SELECT *, unhex(dictGet('keys.plain_key_dict', 'key_hex', hex(SHA256(edk)))) AS k
    FROM raw.users
    WHERE _peerdb_synced_at >= (SELECT max(_peerdb_synced_at) FROM app.users_dict) - INTERVAL 1 MINUTE
      AND (user_id, _peerdb_version) NOT IN (
          SELECT user_id, _peerdb_version FROM app.users_dict
          WHERE _peerdb_synced_at >= (SELECT max(_peerdb_synced_at) FROM app.users_dict) - INTERVAL 1 MINUTE)
      AND dictHas('keys.plain_key_dict', hex(SHA256(edk)))
)
SETTINGS input_format_try_infer_dates = 0, input_format_try_infer_datetimes = 0;
