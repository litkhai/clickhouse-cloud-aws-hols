#!/usr/bin/env bash
# Cost of regex field masking: patterns built per row (non-constant) vs generated literals (gen_mask_sql.py).
# Runs on its own against one service; creates nothing that outlives the session (temporary tables only).
# Needs: clickhouse client, python3, and CH_HOST CH_USER CH_PASSWORD.
set -euo pipefail
cd "$(dirname "$0")"
: "${CH_HOST:?}" "${CH_USER:?}" "${CH_PASSWORD:?}"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# The non-constant form: the patterns are concatenated from each key k inside arrayFold.
fold() {  # $1 = array of keys
  cat <<EOF
arrayFold((acc, k) -> replaceRegexpAll(replaceRegexpAll(acc,
    concat('"', regexpQuoteMeta(k), '"\\\\s*:\\\\s*(?:"(?:[^"\\\\\\\\]|\\\\\\\\.)*"|-?[0-9][0-9.eE+-]*|true|false|\\\\[[^\\\\[\\\\]]*\\\\]|\\\\{[^{}]*\\\\})'), concat('"', k, '":null')),
    concat('\\\\\\\\"', regexpQuoteMeta(k), '\\\\\\\\"\\\\s*:\\\\s*(?:\\\\\\\\"(?:[^\\\\\\\\]|\\\\\\\\\\\\\\\\\\\\\\\\.|\\\\\\\\\\\\\\\\[^\\\\\\\\"])*\\\\\\\\"|-?[0-9][0-9.eE+-]*|true|false|\\\\[[^\\\\[\\\\]]*\\\\]|\\\\{[^{}]*\\\\})'), concat('\\\\\\\\"', k, '\\\\\\\\":null')),
  $1, raw0)
EOF
}

# 1) Same result: 15 edge cases, one rule (endpoint /api/a, keys 연락처 and accountNumber).
printf 'endpoint,key\n/api/a,연락처\n/api/a,accountNumber\n' > "$work/one.csv"
gen_one=$(python3 gen_mask_sql.py "$work/one.csv")
cat > "$work/same.sql" <<EOF
SELECT case_name, o1 = o2 AS same,
       arrayExists(k -> match(o1, concat('"', k, '"\\\\s*:\\\\s*[^n\\\\s]')), ['연락처', 'accountNumber']) AS residual
FROM (
  SELECT case_name, $(fold "['연락처', 'accountNumber']") AS o1, $gen_one AS o2
  FROM (SELECT case_name, raw0, '/api/a' AS ep FROM values('case_name String, raw0 String',
    ('string',            '{"m":{"연락처":"010-1234-5678","x":1}}'),
    ('number',            '{"m":{"accountNumber":1234567890,"x":1}}'),
    ('escaped quote',     '{"m":{"연락처":"a\\\\"b,c","x":1}}'),
    ('spaces',            '{"m":{"연락처" : "010","x":1}}'),
    ('flat array',        '{"m":{"연락처":["010","011"],"x":1}}'),
    ('flat object',       '{"m":{"연락처":{"home":"010"},"x":1}}'),
    ('nested object',     '{"m":{"연락처":{"home":{"v":"010"}},"x":1}}'),
    ('array of arrays',   '{"m":{"연락처":[{"v":["010"]}],"x":1}}'),
    ('already null',      '{"m":{"연락처":null,"x":1}}'),
    ('same key twice',    '{"m":{"a":{"연락처":"010"},"b":{"연락처":"011"}}}'),
    ('key text in value', '{"m":{"note":"연락처: 010","x":1}}'),
    ('string-encoded',    '{"m":{"request":"{\\\\"연락처\\\\":\\\\"010\\\\",\\\\"x\\\\":1}"}}'),
    ('string-encoded esc quote', '{"m":{"request":"{\\\\"연락처\\\\":\\\\"a\\\\\\\\\\\\"b\\\\",\\\\"x\\\\":1}"}}'),
    ('string-encoded number', '{"m":{"request":"{\\\\"accountNumber\\\\":12345,\\\\"x\\\\":1}"}}'),
    ('unicode-escaped key', '{"m":{"\\\\uC5F0\\\\uB77D\\\\uCC98":"010"}}'))))
FORMAT PrettyCompactMonoBlock
EOF

# 2) Cost: 1,000,000 synthetic rows (~700 bytes), endpoints /api/0 … /api/299, rules for /api/0 … /api/199
#    (two keys each), so two thirds of the rows change.
python3 - "$work/rules.csv" <<'EOF'
import sys
with open(sys.argv[1], "w") as f:
    f.write("endpoint,key\n")
    for i in range(200):
        f.write(f"/api/{i},k{i}a\n/api/{i},k{i}b\n")
EOF
gen_200=$(python3 gen_mask_sql.py "$work/rules.csv")
map_200=$(python3 -c "print(', '.join(f\"'/api/{i}', ['k{i}a', 'k{i}b']\" for i in range(200)))")
cat > "$work/cost.sql" <<EOF
CREATE TEMPORARY TABLE src AS
SELECT concat('{"service":"svc-core","message":{"endpoint":"/api/', toString(number % 300), '","request":{"k', toString(number % 300),
              'a":"010-', toString(number % 10000), '","k', toString(number % 300), 'b":"v","memo":"', repeat('x', 500), '"}}}') AS raw0
FROM numbers(1000000);
SELECT 'read only, 1M rows', count() FROM src WHERE JSONExtractString(raw0, 'message', 'endpoint') != '' FORMAT TSV;
SELECT 'generated literals (200 rules), 1M rows', countIf(o != raw0) FROM
  (SELECT raw0, $gen_200 AS o FROM (SELECT raw0, JSONExtractString(raw0, 'message', 'endpoint') AS ep FROM src)) FORMAT TSV;
SELECT 'patterns built per row (200 rules), 100k rows', countIf(o != raw0) FROM
  (WITH map($map_200) AS mask_map, mask_map[JSONExtractString(raw0, 'message', 'endpoint')] AS mask_keys
   SELECT raw0, $(fold mask_keys) AS o FROM (SELECT raw0 FROM src LIMIT 100000)) FORMAT TSV;
SELECT 'max_threads', getSetting('max_threads') FORMAT TSV;
EOF

q() { clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" --password "$CH_PASSWORD" "$@"; }
echo "== same result (expect same = 1 everywhere)"
q --queries-file "$work/same.sql"
echo "== cost (seconds after each line)"
q --time --queries-file "$work/cost.sql"
