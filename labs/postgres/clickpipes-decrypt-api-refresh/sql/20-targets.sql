-- Serving table, filled by the refreshable MV (sql/30-rmv.sql) from raw.users, the ClickPipes CDC table.
-- Email and phone stay ciphertext (the application looks them up by ciphertext); user_properties holds plaintext
-- strings, except the properties the tenant keeps encrypted, which keep their '<version>:<base64>' value.
CREATE DATABASE IF NOT EXISTS app;
CREATE TABLE IF NOT EXISTS app.users (
    user_id String, tenant_id String, external_user_id String,
    encrypted_email String, encrypted_phone_number String,
    user_properties JSON,
    updated_at DateTime64(6), _peerdb_synced_at DateTime64(9), _peerdb_version UInt64, _peerdb_is_deleted UInt8,
    INDEX email_bf encrypted_email TYPE bloom_filter GRANULARITY 1,
    INDEX phone_bf encrypted_phone_number TYPE bloom_filter GRANULARITY 1
) ENGINE = ReplacingMergeTree(_peerdb_version, _peerdb_is_deleted) ORDER BY user_id;

CREATE DATABASE IF NOT EXISTS lab;
CREATE TABLE IF NOT EXISTS lab.expected (user_id String, tenant_id String, n UInt32, props_md5 String, ver UInt8)
ENGINE = MergeTree ORDER BY user_id;
