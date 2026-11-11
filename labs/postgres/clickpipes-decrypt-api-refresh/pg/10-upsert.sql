-- psycopg parameters (%(a)s …): a literal percent sign is written %%.
-- Users a..b encrypted with key version ver (rev changes plan and visits, for updates). An existing user_id is
-- updated, so the same statement makes inserts, updates and key rotation. lab_expected follows in the same transaction.
WITH g AS MATERIALIZED (
    SELECT i, 'u' || lpad(i::text, 9, '0') AS user_id, 't' || lpad((i %% 8)::text, 3, '0') AS tenant_id,
           lab_plain(i, %(rev)s) AS p
    FROM generate_series(%(a)s::int, %(b)s::int) AS i),
e AS MATERIALIZED (SELECT *, lab_enc_props(p, %(ver)s) AS ep FROM g),
ins AS (
    INSERT INTO users
    SELECT user_id, tenant_id, 'ext-' || i, lab_enc(lab_email(i), 'email', %(ver)s), lab_enc(lab_phone(i), 'phone', %(ver)s), ep, now()
    FROM e
    ON CONFLICT (user_id) DO UPDATE SET
        encrypted_email = EXCLUDED.encrypted_email, encrypted_phone_number = EXCLUDED.encrypted_phone_number,
        encrypted_user_properties = EXCLUDED.encrypted_user_properties, updated_at = EXCLUDED.updated_at)
INSERT INTO lab_expected
SELECT user_id, tenant_id, i, lab_hash(p, ep, tenant_id), %(ver)s FROM e
ON CONFLICT (user_id) DO UPDATE SET props_md5 = EXCLUDED.props_md5, ver = EXCLUDED.ver;
