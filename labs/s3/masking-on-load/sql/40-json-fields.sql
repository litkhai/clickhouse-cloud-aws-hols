-- Deleting fields inside a JSON string column instead of masking whole rows.
-- Runs on its own (literal data only); creates mask_lab_json and two SQL UDFs, and drops them at the end.
--   clickhouse client … --queries-file sql/40-json-fields.sql
-- Every result set has an `ok` column; the last query throws if any case failed.

CREATE DATABASE IF NOT EXISTS mask_lab_json;
CREATE TABLE mask_lab_json.results (part String, case_name String, ok Bool) ENGINE = MergeTree ORDER BY (part, case_name);

-- 1) Top-level keys. ClickHouse has no function that removes a JSON key, so the object is rebuilt
--    from JSONExtractKeysAndValuesRaw without the keys to drop. Nothing to drop → the original string.
INSERT INTO mask_lab_json.results
WITH
    ['연락처'] AS drop_keys,
    JSONExtractKeysAndValuesRaw(req) AS kv,
    arrayFilter(x -> NOT has(drop_keys, x.1), kv) AS kept,
    if(length(kept) = length(kv), req,
       concat('{', arrayStringConcat(arrayMap(x -> concat(toJSONString(x.1), ':', x.2), kept), ','), '}')) AS out
SELECT '1-top-level', case_name, out = expected
FROM values('case_name String, req String, expected String',
    ('basic',       '{"연락처":"010-1234-5678","이름":"홍길동","amount":100}', '{"이름":"홍길동","amount":100}'),
    ('escaped',     '{"연락처":"a\\",b}","x":[1,{"y":2}]}',                     '{"x":[1,{"y":2}]}'),
    ('null value',  '{"연락처":null,"x":1}',                                   '{"x":1}'),
    ('spaces',      '{ "연락처" : "010", "x" : 1 }',                            '{"x":1}'),
    ('absent',      '{ "x" : 1 }',                                             '{ "x" : 1 }'),
    ('only key',    '{"연락처":"010"}',                                         '{}'),
    ('unicode key', '{"\\uC5F0\\uB77D\\uCC98":"010","x":1}',                    '{"x":1}'),
    -- not handled, left as they are: a nested key, an empty string, broken JSON
    ('nested',      '{"user":{"연락처":"010"},"x":1}',                          '{"user":{"연락처":"010"},"x":1}'),
    ('empty',       '',                                                        ''),
    ('invalid',     '{"연락처":"010"',                                          '{"연락처":"010"'));

-- 2) Nested class.field paths, as SQL UDFs. A class that holds an array of objects is handled element by element.
CREATE FUNCTION IF NOT EXISTS mask_lab_drop_keys AS (o, fs) ->
    if(length(arrayFilter(y -> has(fs, y.1), JSONExtractKeysAndValuesRaw(o))) = 0, o,
       concat('{', arrayStringConcat(arrayMap(y -> concat(toJSONString(y.1), ':', y.2),
                   arrayFilter(y -> NOT has(fs, y.1), JSONExtractKeysAndValuesRaw(o))), ','), '}'));
CREATE FUNCTION IF NOT EXISTS mask_lab_drop_paths AS (req, paths) ->
    if(length(arrayFilter(x -> has(arrayMap(p -> p.1, paths), x.1), JSONExtractKeysAndValuesRaw(req))) = 0, req,
       concat('{', arrayStringConcat(arrayMap(x -> concat(toJSONString(x.1), ':',
           if(NOT has(arrayMap(p -> p.1, paths), x.1), x.2,
              if(startsWith(x.2, '['),
                 concat('[', arrayStringConcat(arrayMap(e -> mask_lab_drop_keys(e, arrayMap(p -> p.2, arrayFilter(p -> p.1 = x.1, paths))),
                                                        JSONExtractArrayRaw(x.2)), ','), ']'),
                 mask_lab_drop_keys(x.2, arrayMap(p -> p.2, arrayFilter(p -> p.1 = x.1, paths)))))),
           JSONExtractKeysAndValuesRaw(req)), ','), '}'));

INSERT INTO mask_lab_json.results
WITH [('연락처정보', '연락처'), ('user', 'phone')] AS paths
SELECT '2-class-field', case_name, mask_lab_drop_paths(req, paths) = expected
FROM values('case_name String, req String, expected String',
    ('nested',        '{"연락처정보":{"연락처":"010","이메일":"a@b"},"amt":1}',                         '{"연락처정보":{"이메일":"a@b"},"amt":1}'),
    ('null value',    '{"연락처정보":{"연락처":null,"이메일":"a@b"}}',                                 '{"연락처정보":{"이메일":"a@b"}}'),
    ('two paths',     '{"user":{"phone":"010","name":"kim"},"연락처정보":{"연락처":"010"},"x":[1,2]}',   '{"user":{"name":"kim"},"연락처정보":{},"x":[1,2]}'),
    ('array of obj',  '{"user":[{"phone":"010","name":"a"},{"phone":"011","name":"b"}],"amt":2}',      '{"user":[{"name":"a"},{"name":"b"}],"amt":2}'),
    ('class absent',  '{ "amt" : 3 }',                                                               '{ "amt" : 3 }'),
    ('class scalar',  '{"user":"kim","amt":4}',                                                      '{"user":"kim","amt":4}'),
    ('top-level same name', '{"연락처":"top","연락처정보":{"이메일":"a@b"}}',                          '{"연락처":"top","연락처정보":{"이메일":"a@b"}}'),
    -- not handled, left as they are: a deeper path, broken JSON
    ('deeper',        '{"연락처정보":{"sub":{"연락처":"010"}}}',                                       '{"연락처정보":{"sub":{"연락처":"010"}}}'),
    ('invalid',       '{"연락처정보":{"연락처":"010"',                                                 '{"연락처정보":{"연락처":"010"'));

-- 3) Hundreds of rules: one row per (service, endpoint, class, field), looked up per row through a dictionary.
--    (A map literal inside the MV works as well for a one-off load; changing it means changing the MV.)
CREATE TABLE mask_lab_json.rules (service String, endpoint String, class String, field String) ENGINE = MergeTree ORDER BY (service, endpoint);
INSERT INTO mask_lab_json.rules SELECT * FROM values('service String, endpoint String, class String, field String',
    ('svc-core', '/api/report/usage-history', '연락처정보', '연락처'),
    ('svc-core', '/api/report/usage-history', 'user',      'phone'),
    ('svc-core', '/api/user/profile',          'user',      'rrn'));
CREATE DICTIONARY mask_lab_json.rules_dict (service String, endpoint String, classes Array(String), fields Array(String))
PRIMARY KEY service, endpoint
SOURCE(CLICKHOUSE(QUERY 'SELECT service, endpoint, groupArray(class), groupArray(field) FROM mask_lab_json.rules GROUP BY service, endpoint'))
LIFETIME(0)
LAYOUT(COMPLEX_KEY_HASHED());

INSERT INTO mask_lab_json.results
WITH arrayZip(dictGetOrDefault('mask_lab_json.rules_dict', 'classes', (service, endpoint), CAST([], 'Array(String)')),
              dictGetOrDefault('mask_lab_json.rules_dict', 'fields',  (service, endpoint), CAST([], 'Array(String)'))) AS paths
SELECT '3-rules', case_name, if(empty(paths), req, mask_lab_drop_paths(req, paths)) = expected
FROM values('case_name String, service String, endpoint String, req String, expected String',
    ('two rules',    'svc-core', '/api/report/usage-history', '{"연락처정보":{"연락처":"010","이메일":"a@b"},"user":[{"phone":"010","name":"a"}]}', '{"연락처정보":{"이메일":"a@b"},"user":[{"name":"a"}]}'),
    ('one rule',     'svc-core', '/api/user/profile',          '{"user":{"rrn":"900101","phone":"010"}}',                                       '{"user":{"phone":"010"}}'),
    ('no rule',      'svc-core', '/api/other',                 '{"연락처정보":{"연락처":"010"}}',                                                '{"연락처정보":{"연락처":"010"}}'));

-- The check to run after every batch: rows where a rule's path is still present (0 expected).
INSERT INTO mask_lab_json.results
WITH [('연락처정보', '연락처'), ('user', 'phone')] AS paths,
     mask_lab_drop_paths(req, paths) AS out,
     arrayExists(p -> JSONHas(out, p.1, p.2), paths)
       OR arrayExists(p -> arrayExists(e -> JSONHas(e, p.2), JSONExtractArrayRaw(out, p.1)), paths) AS field_left
SELECT '3-rules', concat('check: ', case_name), field_left = expected_left
FROM values('case_name String, req String, expected_left Bool',
    ('removed', '{"연락처정보":{"연락처":"010"},"user":[{"phone":"010"}]}', false),
    ('deeper path is not a rule path', '{"연락처정보":{"sub":{"연락처":"010"}}}', false));

-- 4) Alternative: a JSON column with SKIP paths never stores them — but for every row alike,
--    not inside arrays of objects, and not inside a JSON document that is itself encoded as a string.
INSERT INTO mask_lab_json.results
SELECT '4-json-skip', case_name,
       toString(CAST(j, 'JSON(SKIP request.`연락처정보`.`연락처`, SKIP request.user.phone)')) = expected
FROM values('case_name String, j String, expected String',
    ('nested',         '{"request":{"연락처정보":{"연락처":"010","이메일":"a@b"},"amt":1},"service":"svc"}', '{"request":{"amt":"1","연락처정보":{"이메일":"a@b"}},"service":"svc"}'),
    ('null value',     '{"request":{"연락처정보":{"연락처":null,"이메일":"a@b"}}}',                          '{"request":{"연락처정보":{"이메일":"a@b"}}}'),
    ('other path',     '{"request":{"user":{"phone":"010","name":"kim"},"연락처":"top"}}',                  '{"request":{"user":{"name":"kim"},"연락처":"top"}}'),
    ('array of obj (kept)', '{"request":{"user":[{"phone":"010","name":"a"},{"phone":"011","name":"b"}]}}', '{"request":{"user":[{"name":"a","phone":"010"},{"name":"b","phone":"011"}]}}'),
    ('string-encoded (kept)', '{"request":"{\\"연락처정보\\":{\\"연락처\\":\\"010\\"}}"}',                   '{"request":"{\\"연락처정보\\":{\\"연락처\\":\\"010\\"}}"}'));

SELECT part, countIf(ok) AS passed, count() AS cases, groupArrayIf(case_name, NOT ok) AS failed
FROM mask_lab_json.results GROUP BY part ORDER BY part
FORMAT PrettyCompactMonoBlock;
SELECT throwIf(countIf(NOT ok) > 0, 'a JSON field case failed') FROM mask_lab_json.results FORMAT Null;

DROP DATABASE mask_lab_json SYNC;
DROP FUNCTION mask_lab_drop_paths;
DROP FUNCTION mask_lab_drop_keys;
