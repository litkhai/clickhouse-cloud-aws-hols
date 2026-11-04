-- Same SELECTs as the views, over what the snapshot already loaded. Timed by run.sh (decrypt throughput).
INSERT INTO app.users_a
WITH unhex(kms_unwrap(edk)) AS k
SELECT user_id, tenant_id, external_user_id, dec_val(email_enc, k), dec_val(phone_enc, k),
       toJSONString(dec_props(properties, k)), updated_at, _peerdb_version, _peerdb_is_deleted
FROM raw.users FINAL
SETTINGS input_format_try_infer_dates = 0, input_format_try_infer_datetimes = 0;
