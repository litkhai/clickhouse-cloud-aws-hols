-- Source schema in Aurora PostgreSQL (run as the master user).
-- Every value is '<key version>:' || base64(AES-256-CBC, PKCS#7) under a per-column data key with a fixed IV
-- per key version, so the same plaintext always gives the same ciphertext (equality lookups on ciphertext).
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS users (
    user_id                   text PRIMARY KEY,
    tenant_id                 text NOT NULL,
    external_user_id          text NOT NULL,
    encrypted_email           text NOT NULL,
    encrypted_phone_number    text NOT NULL,
    encrypted_user_properties jsonb NOT NULL,   -- {"name": "1:…", "plan": "1:…", …}: every value encrypted
    updated_at                timestamptz NOT NULL DEFAULT now()
);

-- What ClickHouse should end up with, per user: md5 of the sorted "key=value" pairs, where value is the
-- plaintext, or the stored ciphertext for a property the tenant keeps encrypted. Not in the publication.
CREATE TABLE IF NOT EXISTS lab_expected (user_id text PRIMARY KEY, tenant_id text, n int, props_md5 text, ver int);

-- ClickPipes user and publication (docs integrations/clickpipes/postgres/source/aurora, read 2026-11-04)
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'clickpipes_user') THEN
    EXECUTE format('CREATE USER clickpipes_user PASSWORD %L', current_setting('lab.cp_password'));
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO clickpipes_user;
GRANT SELECT ON users TO clickpipes_user;
GRANT rds_replication TO clickpipes_user;
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_publication WHERE pubname = 'clickpipes') THEN
    CREATE PUBLICATION clickpipes FOR TABLE users;
  END IF;
END $$;
ALTER TABLE users REPLICA IDENTITY FULL;

-- ---------------------------------------------------------------- synthetic data (deterministic per user number)
-- 40 properties, about 1.2 KB of plaintext; all values are strings, as the application stores them.
CREATE OR REPLACE FUNCTION lab_plain(i int, rev int DEFAULT 0) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
SELECT jsonb_build_object(
    'plan', (ARRAY['free', 'basic', 'pro', 'enterprise'])[1 + (i + rev) % 4],
    'visits', ((i::bigint * 7919 + rev * 13) % 500)::text,
    'lastVisitedAt', format('2026-%s-%sT%s:00:00Z', lpad((1 + i % 10)::text, 2, '0'), lpad((1 + i % 28)::text, 2, '0'), lpad((i % 24)::text, 2, '0')),
    'marketingOptIn', CASE WHEN i % 5 < 3 THEN 'true' ELSE 'false' END,
    'city', (ARRAY['서울', '부산', '인천', '대구', '광주', '대전', 'Tokyo', 'Singapore'])[1 + i % 8],
    'name', (ARRAY['김민준', '이서연', '박지호', '최수아', 'Alex Kim', 'Mina Park'])[1 + i % 6],
    'birthday', format('19%s-%s-%s', 60 + i % 40, lpad((1 + i % 12)::text, 2, '0'), lpad((1 + i % 28)::text, 2, '0')),
    'memo', '메모 ' || i)
 || (SELECT jsonb_object_agg(format('attr_%s', lpad(j::text, 2, '0')), substr(md5(i || ':' || j), 1, 12 + j % 17))
     FROM generate_series(0, 31) AS j)
$$;

CREATE OR REPLACE FUNCTION lab_email(i int) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'user' || i || '@example.com' $$;
CREATE OR REPLACE FUNCTION lab_phone(i int) RETURNS text LANGUAGE sql IMMUTABLE AS $$
SELECT format('010-%s-%s', 1000 + i % 9000, 1000 + (i * 7) % 9000) $$;

-- Properties a tenant keeps encrypted in ClickHouse (same rule as keys.py keep_for()).
CREATE OR REPLACE FUNCTION lab_keep(tenant text) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
SELECT CASE WHEN right(tenant, 1)::int % 2 = 0 THEN ARRAY['name', 'birthday'] ELSE ARRAY['name'] END $$;

-- The keys exist only as settings of the loading session (load.py), never in a table.
CREATE OR REPLACE FUNCTION lab_enc(v text, col text, ver int) RETURNS text LANGUAGE sql STABLE AS $$
SELECT ver || ':' || translate(encode(encrypt_iv(convert_to(v, 'UTF8'),
       decode(current_setting(format('lab.key_%s_%s', col, ver)), 'hex'),
       decode(current_setting(format('lab.iv_%s_%s', col, ver)), 'hex'), 'aes-cbc/pad:pkcs'), 'base64'), E'\n', '')
$$;

CREATE OR REPLACE FUNCTION lab_enc_props(p jsonb, ver int) RETURNS jsonb LANGUAGE sql STABLE AS $$
SELECT jsonb_object_agg(k, lab_enc(v, 'props', ver)) FROM jsonb_each_text(p) AS e(k, v) $$;

CREATE OR REPLACE FUNCTION lab_hash(p jsonb, e jsonb, tenant text) RETURNS text LANGUAGE sql STABLE AS $$
SELECT md5(string_agg(k || '=' || CASE WHEN k = ANY (lab_keep(tenant)) THEN e ->> k ELSE v END, chr(31) ORDER BY k COLLATE "C"))
FROM jsonb_each_text(p) AS t(k, v) $$;
