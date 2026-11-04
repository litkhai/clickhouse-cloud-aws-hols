-- Decrypted copies of raw.users (the ClickPipes CDC table, ciphertext only).
-- Every value inside properties is a string (numbers and booleans keep their JSON text), so typed
-- conditions cast at query time: toFloat64OrNull(properties.visits.:String), parseDateTime64BestEffortOrNull(...).
CREATE DATABASE IF NOT EXISTS app;
CREATE DATABASE IF NOT EXISTS keys;

-- A: key unwrapped by the kms_unwrap UDF (KMS Decrypt from inside ClickHouse Cloud)
CREATE TABLE IF NOT EXISTS app.users_a (
    user_id String, tenant_id String, external_user_id String,
    email String, phone String, properties JSON,
    updated_at DateTime64(6), _peerdb_version UInt64, _peerdb_is_deleted UInt8
) ENGINE = ReplacingMergeTree(_peerdb_version, _peerdb_is_deleted) ORDER BY user_id;

-- B: plaintext data key kept in ClickHouse (table + dictionary), no KMS call at ingest.
--    key_ref = hex(SHA256(edk)): a rotated key gets a new id instead of overwriting the old one.
CREATE TABLE IF NOT EXISTS keys.plain_keys (key_ref String, key_hex String) ENGINE = ReplacingMergeTree ORDER BY key_ref;
CREATE DICTIONARY IF NOT EXISTS keys.plain_key_dict (key_ref String, key_hex String)
    PRIMARY KEY key_ref
    SOURCE(CLICKHOUSE(DATABASE 'keys' TABLE 'plain_keys'))
    LIFETIME(MIN 60 MAX 120) LAYOUT(COMPLEX_KEY_HASHED());
CREATE TABLE IF NOT EXISTS app.users_b AS app.users_a;
