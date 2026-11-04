-- SQL UDFs shared by every path. No key material here: the key is an argument.
-- A stored value is 'enc:v1:' || base64(iv(16 B) || AES-256-CBC ciphertext).
CREATE FUNCTION IF NOT EXISTS enc_blob AS (s) -> base64Decode(substring(s, 8));
CREATE FUNCTION IF NOT EXISTS dec_val AS (s, k) ->
    if(startsWith(s, 'enc:v1:'),
       decrypt('aes-256-cbc', substring(enc_blob(s), 17), k, substring(enc_blob(s), 1, 16)),
       s);
-- jsonb text (top level) -> Map(String, String), encrypted values decrypted, every value a string
-- (numbers and booleans keep their JSON text; nested objects stay as JSON text).
CREATE FUNCTION IF NOT EXISTS dec_props AS (j, k) ->
    mapFromArrays(
        arrayMap(kv -> kv.1, JSONExtractKeysAndValuesRaw(j)),
        arrayMap(kv -> dec_val(if(startsWith(kv.2, '"'), JSONExtractString(kv.2), kv.2), k),
                 JSONExtractKeysAndValuesRaw(j)));
