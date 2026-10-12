-- Run per target table: clickhouse client --param_t=users_a --queries-file 90-verify.sql
-- expected: rows 22484235, masked 7763456, leaks 0, unmasked_diff 0
SELECT
    count()                                               AS rows,
    countIf(is_masked)                                    AS masked,
    countIf(LastAccessDate < '2020-01-01' AND NOT is_masked) AS rule_missed,
    countIf(is_masked AND (DisplayName NOT LIKE '%***' OR AboutMe IS NOT NULL
                           OR WebsiteUrl IS NOT NULL OR Location IS NOT NULL)) AS leaks
FROM mask_lab.{t:Identifier}
FORMAT Vertical;
