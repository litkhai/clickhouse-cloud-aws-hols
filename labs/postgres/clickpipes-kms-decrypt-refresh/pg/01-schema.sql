-- Source schema in Aurora PostgreSQL (run as the master user).
CREATE TABLE IF NOT EXISTS users (
    user_id          text PRIMARY KEY,
    tenant_id        text NOT NULL,
    edk              text NOT NULL,          -- KMS-encrypted data key (base64), envelope encryption
    external_user_id text,
    email_enc        text,                   -- 'enc:v1:' || base64(iv || AES-256-CBC)
    phone_enc        text,
    properties       jsonb NOT NULL,         -- some values inside are 'enc:v1:…'
    updated_at       timestamptz NOT NULL DEFAULT now()
);
-- ClickPipes user and publication (docs integrations/clickpipes/postgres/source/aurora, read 2026-11-04)
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'clickpipes_user') THEN
    EXECUTE format('CREATE USER clickpipes_user PASSWORD %L', current_setting('lab.cp_password'));
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO clickpipes_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO clickpipes_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO clickpipes_user;
GRANT rds_replication TO clickpipes_user;
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_publication WHERE pubname = 'clickpipes') THEN
    CREATE PUBLICATION clickpipes FOR TABLE users;
  END IF;
END $$;
-- Deletes carry the whole old row (edk included), so the decrypting views never see a row without a key.
ALTER TABLE users REPLICA IDENTITY FULL;
