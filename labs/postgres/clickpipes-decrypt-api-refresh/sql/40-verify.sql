-- app.users FINAL against lab.expected (exported from Aurora by load.py expected): same md5 of the sorted
-- key=value pairs, where kept-encrypted properties must still be the stored ciphertext.
SELECT (SELECT count() FROM lab.expected) AS expected,
       count() AS rows,
       countIf(e.user_id = '') AS unexpected_rows,
       countIf(lower(hex(MD5(arrayStringConcat(
           arrayMap(kv -> concat(kv.1, '=', kv.2),
                    arraySort(kv -> kv.1, JSONExtractKeysAndValues(toJSONString(u.user_properties), 'String'))),
           '\x1F')))) = e.props_md5) AS props_ok
FROM app.users AS u FINAL
LEFT JOIN lab.expected AS e USING user_id
SETTINGS join_use_nulls = 0;

-- Every property path should be a String (no date or number inference).
SELECT length(mapKeys(t)) AS paths, arrayDistinct(arrayFlatten(mapValues(t))) AS types
FROM (SELECT distinctJSONPathsAndTypes(user_properties) AS t FROM app.users);
