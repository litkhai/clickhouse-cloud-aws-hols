-- Ciphertext lookups, as the application does them: encrypt the input with the same key and fixed IV
-- (lookup.py prints the parameters for every key version), then compare ciphertexts.
-- 1. One user by email, every key version (a rotated user only matches its own version).
SELECT 'email, all versions' AS q, user_id, tenant_id, splitByChar(':', encrypted_email)[1] AS ver
FROM app.users FINAL WHERE encrypted_email IN {emails:Array(String)};
SELECT 'email, version 1 only' AS q, count() FROM app.users FINAL WHERE encrypted_email = {emails:Array(String)}[1];
-- 2. A condition on a property the tenant keeps encrypted: = and <> on the ciphertext.
SELECT 'name = (kept encrypted)' AS q, count() AS users, uniqExact(tenant_id) AS tenants
FROM app.users FINAL WHERE user_properties.name::String IN {names:Array(String)};
SELECT 'name <> (kept encrypted)' AS q, count() FROM app.users FINAL WHERE user_properties.name::String NOT IN {names:Array(String)};
SELECT 'expected from the generator' AS q, countIf(n % 6 = 0) AS name_eq, countIf(n % 6 != 0) AS name_ne FROM lab.expected;
-- 3. A plaintext condition next to it (decrypted property, cast at query time).
SELECT 'plan = pro AND visits >= 250' AS q, count() FROM app.users FINAL
WHERE user_properties.plan::String = 'pro' AND toUInt32OrZero(user_properties.visits::String) >= 250;
