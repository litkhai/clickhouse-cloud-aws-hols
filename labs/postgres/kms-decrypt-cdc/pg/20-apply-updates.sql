-- users_stage holds re-encrypted rows for existing user_ids (new values, new data keys = key rotation).
UPDATE users u SET edk = s.edk, email_enc = s.email_enc, phone_enc = s.phone_enc,
                   properties = s.properties, updated_at = now()
FROM users_stage s WHERE u.user_id = s.user_id;
