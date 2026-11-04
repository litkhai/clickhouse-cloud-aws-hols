INSERT INTO app.users_b
WITH unhex(dictGet('keys.plain_key_dict', 'key_hex', hex(SHA256(edk)))) AS k
SELECT user_id, tenant_id, external_user_id, dec_val(email_enc, k), dec_val(phone_enc, k),
       toJSONString(dec_props(properties, k)), updated_at, _peerdb_version, _peerdb_is_deleted
FROM raw.users FINAL
WHERE dictHas('keys.plain_key_dict', hex(SHA256(edk)))
SETTINGS input_format_try_infer_dates = 0, input_format_try_infer_datetimes = 0;
