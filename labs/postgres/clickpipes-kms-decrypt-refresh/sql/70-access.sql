-- Mitigation for "any SQL user can call an executable UDF": the UDF returns plaintext only, so a caller needs the
-- ciphertext, and only the refresh's definer reads raw.users. Serving users get the decrypted tables, nothing else.
CREATE USER IF NOT EXISTS analyst IDENTIFIED WITH sha256_password BY {p:String};
GRANT SELECT ON app.users_kms TO analyst;
