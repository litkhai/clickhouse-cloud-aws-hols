## Notes (hand-written from the 2026-10-09 runs; appended to every regenerated REHEARSAL.md)

The runs behind the numbers: the full `rehearse.sh --sf 1` above, and screening runs of `run.py` against the
same containers with an 8 s timeout (earlier the same day, same host, same images, same data). Where a line
cites a screening run it says so. Nothing here was run on Aurora or ClickHouse Cloud.

### What the rehearsal changed in the scripts

| Finding | Evidence | What the scripts do |
|---|---|---|
| ClickHouse `Date` cannot hold `date_dim.d_date` (starts 1900-01-02) | `INSERT` fails: `Input value -25566 is out of allowed Date range` | `20-clickhouse-load.sh` loads `d_date` as `Date32` |
| The pinned ClickHouse DDL has no `Nullable`; `INSERT ... SELECT` turns NULL into 0 / empty / 1970-01-01 | Screening run, pinned DDL with only `Date32`: P 50 match, 36 mismatch, 1 syntax, 16 error of 103. With the three adaptations: 87 / 6 / 1 / 9 (before the query30 patch). The lost NULLs are visible in the counts, e.g. query97 | columns without `NOT NULL` become `Nullable(T)` |
| `substr()` is pushed down as `substringUTF8`, which rejects `FixedString` | queries 08, 15, 19, 45, 85: `Illegal type FixedString(10) of first argument of function substringUTF8` | `FixedString(N)` becomes `String` (the Parquet columns are variable-length strings) |
| `CH_DDL=pinned` | | loads the pinned DDL with only the `Date32` change, to measure the effect again |
| query30 selects `c_last_review_date`, dsdgen writes `c_last_review_date_sk` | `Binder Error` on DuckDB 1.5.6 (R fails too), `column "c_last_review_date" does not exist` on PostgreSQL and pg_clickhouse | `patches/query30.diff`, applied by `02-queries.sh` to every target including R |
| `COPY ... TO` an existing Parquet directory fails | `Directory ... is not empty` | `01-generate.sh` writes with `OVERWRITE` |
| `SHOW pg_clickhouse.session_settings` fails before the extension is loaded in the session | `unrecognized configuration parameter` | `21-pgfront-setup.sh` calls `clickhouse_server_version()` first |
| `CREATE TABLE sf<N>_s3.<t> AS s3(...)` creates a `Proxy` table (the table function), not an `ENGINE = S3` table | `system.tables.engine = Proxy` on 26.9.13.15, also seen through `IMPORT FOREIGN SCHEMA` (`engine 'Proxy'`) | used for both `file()` (rehearsal) and `s3()` (real run); `ENGINE = S3(...)` itself was not run |

### Differences that are not script bugs (for the lead to decide)

Counts below are from the full run (60 s timeout) unless marked.

1. **int / int is not the same in DuckDB and PostgreSQL.** R (DuckDB) divides as real numbers, PostgreSQL 18 truncates. Plain PostgreSQL differs from R on queries 21, 34, 73, 78, 83 (row-level: query78 `ratio` 2.29 in R, 2.00 in PostgreSQL). Aurora is PostgreSQL, so it will differ from R on the same queries. P differs from R on 34 and 73 (same answer as PostgreSQL) but not on 21, 78, 83 (pushed down as ClickHouse `/`, which is real division). Untested options: a cast in those queries (a `patches/*.diff` for every target), or accepting these as "differs from R, equals PostgreSQL".
2. **pg_clickhouse returns a wrong answer for `EXISTS` with a non-equality condition**: queries 16 and 94 (1 row each, order counts 209 vs 233 and 23 vs 32 against R and against plain PostgreSQL, which agree). `EXPLAIN (VERBOSE)` of query94 shows `LEFT SEMI JOIN sf1.web_sales r5 ON (r1.ws_order_number = r5.ws_order_number) WHERE (r1.ws_warehouse_sk <> r5.ws_warehouse_sk)`; ClickHouse's `LEFT SEMI JOIN` keeps one right row per left row, so filtering on it afterwards loses matches. Cause is inferred from that plan, not confirmed.
3. **query44** differs (10 rows, same ranks, other products): the remote SQL has `avg(ss_net_profit) > (0.9 * {p1:Decimal})`, the scalar subquery value goes over as a `Decimal` parameter without a scale. Plain PostgreSQL matches R. Suspected, not confirmed.
4. **pg_clickhouse errors**: query64 `Syntax error: failed at position 388 (ALL)` in the generated ClickHouse SQL; query75 `Data types Variant/Dynamic are not allowed in ORDER BY keys`.
5. **Timeouts at 60 s on P**: queries 01, 04, 11 (`EXPLAIN` shows partial pushdown for all three). `statement_timeout` cancels pg_clickhouse queries (60.002, 60.006, 60.007 s in the last full run). Plain PostgreSQL without indexes times out on the same three. At 600 s they may finish; not measured.
6. **Collation of the front-end database matters.** Screening run, front end in a database with the image default `en_US.utf8`: query18 mismatches (ORDER BY text ... LIMIT 100 picks `Lake County` rows where R has `La Porte County` rows, a collation difference) and query57 fails with `mergejoin input data is out of order` (inferred: ClickHouse returns binary order, PostgreSQL expects en_US order). In a `C`-collation database (this run) both match R. Aurora's database will have its own collation; the same effect is possible there for ORDER BY ... LIMIT queries (not measured).
7. P pushdown: only the full/partial counts above are measured; what a partial plan costs on ClickHouse Cloud is not.

### Not covered by the rehearsal

Aurora (`10-aurora-setup.sh` was only run with `--dry-run`, and `run.py` targets A-E have not connected to anything), S3 (`s3://` destination of `01-generate.sh` and the `s3()` source with `extra_credentials` were printed with `--dry-run`, not executed), TLS (`--secure`, `PGFRONT_SSLMODE=require`, `secure 'on'` on the server), a ClickHouse Managed Postgres service (extension update path, `GRANT` on `clickhouse_perform`), `--cold reboot`, serverless, anything above SF1, timings.
