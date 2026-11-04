-- Created after the snapshot, then backfilled from raw.users FINAL (sql/31-backfill.sql);
-- from then on every CDC insert into raw.users goes through both views.
-- The String -> JSON cast is inside the SELECT, with SETTINGS on the SELECT: only then does the view skip
-- date inference. A plain String into a JSON column (or a Map cast to JSON) is parsed with the inserting
-- session's settings — ClickPipes' — and "2026-04-02T03:00:00Z" became DateTime64(9) (measured 2026-11-04).
CREATE MATERIALIZED VIEW IF NOT EXISTS app.users_a_mv TO app.users_a AS
WITH unhex(kms_unwrap(edk)) AS k
SELECT user_id, tenant_id, external_user_id,
       dec_val(email_enc, k) AS email, dec_val(phone_enc, k) AS phone,
       CAST(toJSONString(dec_props(properties, k)), 'JSON') AS properties,
       updated_at, _peerdb_version, _peerdb_is_deleted
FROM raw.users
SETTINGS input_format_try_infer_dates = 0, input_format_try_infer_datetimes = 0;

CREATE MATERIALIZED VIEW IF NOT EXISTS app.users_b_mv TO app.users_b AS
WITH unhex(dictGet('keys.plain_key_dict', 'key_hex', hex(SHA256(edk)))) AS k
SELECT user_id, tenant_id, external_user_id,
       dec_val(email_enc, k) AS email, dec_val(phone_enc, k) AS phone,
       CAST(toJSONString(dec_props(properties, k)), 'JSON') AS properties,
       updated_at, _peerdb_version, _peerdb_is_deleted
FROM raw.users
WHERE dictHas('keys.plain_key_dict', hex(SHA256(edk)))
SETTINGS input_format_try_infer_dates = 0, input_format_try_infer_datetimes = 0;
