-- Serving tables, filled by refreshable MVs (sql/30-rmvs.sql) from raw.users, the ClickPipes CDC table.
-- No view sits on the pipe's INSERT: ClickPipes only lands ciphertext, so a decryption failure cannot stop CDC.
-- Every property value is a string; typed conditions cast at query time.
CREATE DATABASE IF NOT EXISTS app;
CREATE DATABASE IF NOT EXISTS keys;

-- K: decrypted by the kms_decrypt_row UDF (KMS Decrypt inside the UDF; the key never reaches SQL)
CREATE TABLE IF NOT EXISTS app.users_kms (
    user_id String, tenant_id String, external_user_id String,
    email String, phone String, properties JSON,
    updated_at DateTime64(6), _peerdb_synced_at DateTime64(9), _peerdb_version UInt64, _peerdb_is_deleted UInt8
) ENGINE = ReplacingMergeTree(_peerdb_version, _peerdb_is_deleted) ORDER BY user_id;

-- D: decrypted with plaintext data keys kept in ClickHouse (table + dictionary, keyed by hex(SHA256(edk)))
CREATE TABLE IF NOT EXISTS keys.plain_keys (key_ref String, key_hex String) ENGINE = ReplacingMergeTree ORDER BY key_ref;
CREATE DICTIONARY IF NOT EXISTS keys.plain_key_dict (key_ref String, key_hex String)
    PRIMARY KEY key_ref
    SOURCE(CLICKHOUSE(DATABASE 'keys' TABLE 'plain_keys'))
    LIFETIME(MIN 10 MAX 20) LAYOUT(COMPLEX_KEY_HASHED());
CREATE TABLE IF NOT EXISTS app.users_dict AS app.users_kms;
