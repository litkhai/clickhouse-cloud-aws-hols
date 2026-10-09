# Comparison — Aurora `aurora_analytics` vs pg_clickhouse → ClickHouse Cloud (2026-10-09)

[English](#english) | [한국어](#한국어)

## English

This is the frank reading of [RESULTS.md](RESULTS.md): the same measurements, with where each side won and lost,
inferred causes (marked as such) and list-price arithmetic. Every number is from the 2026-10-09 runs under the
conditions in RESULTS.md. Derived from TPC-DS; not comparable to published TPC-DS results. Default settings on
every target, no tuning, one cold and one warm run per query — single queries can move between runs.

### Bottom line, per question

1. **Does aurora_analytics work on db.t4g?** Yes. t4g.medium and t4g.large: SF1 100/103, SF10 94/103, no out-of-memory; SF100 on t4g.large reached 75 of 103 in 3 h and finished 53 (20 timeouts, 2 OOM). 4 GiB and 8 GiB were within 1–2 % of each other at the median.
2. **Same vCPU (8), SF100 — who finished more?** Aurora r8gd.2xlarge 92/103, the ClickHouse path 78/103. Aurora finished 18 queries the ClickHouse path did not; the reverse was 4.
3. **Who is faster?** It depends on the cache.
   - Cold (first run): the ClickHouse path, about 2.9x in total over the 74 common queries (1,337 s vs 3,860 s), geomean 11.3 s vs 21.1 s.
   - Warm (repeat): Aurora per query, geomean 3.05 s vs 8.09 s, 3x or more faster on 37 of 74 (ClickHouse 3x or more faster on 6); the totals are equal (1,130 s vs 1,140 s) because ClickHouse wins the few heavy ones by a lot (q66 22.7x, q36 16.3x).
   - SF10 (2 vCPU t4g vs 8 GiB replicas): same pattern — cold total 1,589 s vs 758 s, warm geomean 2.52 s vs 4.17 s.
4. **Are the answers right?** Aurora follows PostgreSQL semantics (98 of 99 comparable SF1 queries equal plain PostgreSQL 18). The ClickHouse path returned different answers on q16, q94 (`EXISTS` with a non-equality condition) and q44 against both references, at every scale.
5. **Glue catalog + Iceberg?** Both work: Aurora `IMPORT FOREIGN SCHEMA` and ClickHouse `DataLakeCatalog` each saw all 24 tables with the right row counts. On Iceberg at SF10: Aurora r8gd 100/103, the ClickHouse path 86/103 (two new errors reading Iceberg on 26.6.1, q34 and q73).

### Where the ClickHouse path lost, and why (inferred unless measured)

- **Through pg_clickhouse, not ClickHouse itself.** Only 28 of 103 SF100 queries were pushed down entirely (EXPLAIN VERBOSE, measured). The others leave joins, aggregates or sorts in the Postgres front end and pull intermediate rows over TLS; 15 of the 16 SF100 timeouts are partial-pushdown queries (measured: the plan class; that the pulled rows are the cause is inferred, not timed per operator).
- **Generated SQL:** 6 errors at every scale — correlated subqueries (q06, q32, q41, q92: "Resolved identifier … in parent scope" on 26.6.1; not seen on 26.9 + pg_clickhouse 0.11 in the local rehearsal), `ALL INNER JOIN` syntax (q64), Decimal/Float64 supertype (q75).
- **Join memory:** q17, q25, q29 at SF100 — three-way fact-table joins pushed down entirely — hit the 28.8 GiB server limit; the default hash join does not spill (a `join_algorithm` change was not tried).
- **Per-query floor:** warm light queries cost seconds on the ClickHouse path where Aurora's cache answers in a fraction of a second (q31 24.8x, q83 22.3x); the front-end → ClickHouse round trip is the likely floor (not measured separately).
- **Memory was not equal:** E has 64 GiB; one ClickHouse replica 32 GiB.

### Where Aurora lost, and why

- **Cold reads from S3:** every first run re-reads Parquet from S3 into the local cache; cold totals are 2–3x the ClickHouse path's at SF10 and SF100.
- **Heavy aggregation / window queries:** q66, q36, q86, q88 warm 5–23x slower than ClickHouse.
- **Operational:** `statement_timeout` and `pg_cancel_backend()` do not stop a running query; only `pg_terminate_backend()` does. Analytics shares CPU with OLTP on the same instance (99.7 % CPU on t4g; OLTP latency not measured). T4g Unlimited: both t4g borrowed ~27 CPU credits during run 1 ($0.09 per vCPU-hour above baseline over 24 h).
- **Scaling = resizing the OLTP instance.**

### List-price arithmetic (SF100, the 74 common queries; front end excluded)

| | Aurora r8gd.2xlarge ($1.502/h) | ClickHouse 32 GiB × 2 ($3.84/h) |
|---|---|---|
| cold pass | 3,860 s → $1.61 | 1,337 s → $1.43 |
| warm pass | 1,130 s → $0.47 | 1,140 s → $1.22 |

Instance-time only, as if nothing else ran; the ClickHouse figure excludes the Managed Postgres front end, Aurora's excludes storage and I/O. A query runs on one ClickHouse replica; the second replica is the minimum for the first service of a warehouse on this organisation (API spec), so a 1-replica price would halve the ClickHouse column. Not a TCO.

### Per-query numbers

Seconds of the cold and warm run; `timeout` / `OOM` / `error` = the cold run failed (no warm run); `≠R` = answer differs from the DuckDB reference; `—` = not run (B reached its 3-hour cap at q71).

#### SF100, seconds (300 s limit; B capped at 3 h)

| query | B cold | B warm | E cold | E warm | P cold | P warm |
|---|---|---|---|---|---|---|
| q01 | 12.2 | 3.9 | 3.8 | 0.8 | timeout |  |
| q02 | 182.1 | 25.7 | 57.4 | 4.2 | timeout |  |
| q03 | 261.5 | 22.5 | 81.8 | 3.4 | 10.0 | 8.0 |
| q04 | timeout |  | timeout |  | timeout |  |
| q05 | timeout |  | timeout |  | timeout |  |
| q06 | 10.6 | 3.1 | 3.9 | 1.0 | error |  |
| q07 | 106.3 | 10.6 | 29.2 | 2.0 | 11.1 | 5.7 |
| q08 | 13.4 | 2.1 | 4.7 | 0.7 | 7.3 | 6.8 |
| q09 | timeout |  | 119.1 | 26.4 | 11.4 | 11.3 |
| q10 | 24.7 | 2.7 | 8.6 | 0.9 | 16.8 | 15.6 |
| q11 | timeout |  | timeout |  | timeout |  |
| q12 | 3.1 | 0.7 | 1.3 | 0.3 | 1.4 | 0.6 |
| q13 | 113.5 | 19.2 | 32.9 | 3.2 | 16.7 | 8.8 |
| q14_1 | timeout |  | timeout |  | timeout |  |
| q14_2 | timeout |  | timeout |  | timeout |  |
| q15 | 10.6 | 2.1 | 3.3 | 0.6 | 12.0 | 11.5 |
| q16 | 31.8 | 4.0 | 9.7 | 0.9 | 19.4 ≠R | 16.2 |
| q17 | 48.9 | 9.7 | 12.5 | 1.7 | OOM |  |
| q18 | 63.0 | 7.8 | 19.3 | 1.7 | 7.7 | 4.6 |
| q19 | 19.6 | 3.1 | 6.0 | 0.8 | 11.1 | 7.4 |
| q20 | 5.8 | 0.9 | 1.7 | 0.3 | 2.0 | 0.9 |
| q21 | 5.3 ≠R | 2.2 | 2.6 ≠R | 0.6 | 4.9 | 3.2 |
| q22 | 77.3 | 63.5 | 18.8 | 13.2 | 72.5 | 71.4 |
| q23_1 | OOM |  | 147.3 | 50.0 | 36.7 | 37.0 |
| q23_2 | OOM |  | 142.5 | 50.3 | 47.4 | 47.0 |
| q24_1 | timeout |  | 110.2 | 9.9 | 12.3 | 6.1 |
| q24_2 | timeout |  | 111.8 | 9.8 | 10.7 | 5.9 |
| q25 | 31.9 | 6.0 | 10.6 | 1.3 | OOM |  |
| q26 | 57.2 | 6.2 | 16.7 | 1.3 | 5.2 | 3.0 |
| q27 | 106.7 | 10.6 | 31.9 | 1.9 | 10.7 | 5.9 |
| q28 | timeout |  | 101.2 | 20.6 | 18.4 | 13.4 |
| q29 | 121.5 | 15.4 | 35.1 | 2.8 | OOM |  |
| q30 | 7.2 | 2.4 | 2.4 | 0.7 | timeout |  |
| q31 | 53.9 | 10.1 | 15.1 | 1.9 | 50.0 | 47.6 |
| q32 | 8.8 | 1.5 | 2.9 | 0.5 | error |  |
| q33 | 17.5 | 2.8 | 5.7 | 1.1 | 9.4 | 4.5 |
| q34 | 183.5 ≠R | 17.1 | 54.3 ≠R | 2.9 | 12.7 ≠R | 8.2 |
| q35 | 62.7 | 15.3 | 19.2 | 3.0 | timeout |  |
| q36 | timeout |  | 283.7 | 162.7 | 14.4 | 10.0 |
| q37 | 73.1 | 6.6 | 28.8 | 1.3 | 5.9 | 4.6 |
| q38 | 94.3 | 26.6 | 28.1 | 4.5 | 70.9 | 64.0 |
| q39_1 | 9.6 | 6.9 | 3.3 | 1.7 | 16.1 | 13.7 |
| q39_2 | 9.8 | 7.2 | 3.2 | 1.7 | 14.6 | 13.3 |
| q40 | 25.8 | 4.0 | 7.8 | 1.1 | 7.0 | 5.9 |
| q41 | 0.6 | 0.2 | 0.4 | 0.1 | error |  |
| q42 | 12.8 | 1.6 | 4.2 | 0.4 | 7.2 | 5.1 |
| q43 | 61.0 | 7.9 | 17.7 | 1.3 | 22.7 | 24.7 |
| q44 | timeout |  | 172.1 | 22.4 | 8.1 ≠R | 4.8 |
| q45 | 8.1 | 2.4 | 2.9 | 0.7 | 3.9 | 3.3 |
| q46 | 254.8 | 30.6 | 77.2 | 5.0 | 13.3 | 15.7 |
| q47 | timeout |  | 300.2 | 201.3 | 78.6 | 77.8 |
| q48 | 96.3 | 17.4 | 27.9 | 2.9 | 13.5 | 7.6 |
| q49 | timeout |  | timeout |  | 16.8 ≠R | 8.1 |
| q50 | timeout |  | 87.9 | 6.2 | 17.2 | 12.9 |
| q51 | 162.3 | 94.0 | 34.0 | 14.6 | 107.8 | 105.4 |
| q52 | 13.8 | 1.5 | 3.9 | 0.4 | 7.0 | 5.1 |
| q53 | 75.5 | 6.6 | 20.2 | 1.2 | 7.2 | 5.4 |
| q54 | 28.4 | 4.6 | 9.2 | 1.4 | timeout |  |
| q55 | 14.0 | 1.5 | 3.9 | 0.4 | 7.0 | 5.2 |
| q56 | 16.4 | 2.7 | 5.4 | 1.2 | 6.8 | 4.4 |
| q57 | timeout |  | 214.6 | 155.9 | 38.3 | 37.4 |
| q58 | 14.1 | 3.4 | 5.1 | 1.2 | 8.7 | 5.1 |
| q59 | timeout |  | 85.2 | 6.4 | 14.4 | 9.9 |
| q60 | 25.9 | 3.9 | 7.9 | 1.3 | 8.2 | 5.6 |
| q61 | 23.9 | 5.7 | 6.8 | 1.6 | 13.4 | 10.1 |
| q62 | 28.1 | 7.2 | 8.1 | 1.4 | 3.0 | 2.3 |
| q63 | 73.6 | 6.9 | 20.6 | 1.2 | 6.3 | 4.1 |
| q64 | timeout |  | 109.6 | 10.9 | error |  |
| q65 | 105.0 | 37.5 | 22.7 | 4.0 | 64.6 | 61.3 |
| q66 | 301.2 ≠R | 302.4 | 266.6 | 148.5 | 9.7 | 6.5 |
| q67 | timeout |  | timeout |  | timeout |  |
| q68 | timeout |  | 79.7 | 5.5 | 18.3 | 9.6 |
| q69 | 24.5 | 3.3 | 7.5 | 1.0 | 10.6 | 9.6 |
| q70 | timeout |  | timeout |  | 99.3 | 98.3 |
| q71 | 28.3 | 3.7 | 8.6 | 1.1 | 22.6 | 22.2 |
| q72 | — | — | 73.6 | 14.6 | timeout |  |
| q73 | — | — | 50.4 ≠R | 2.9 | 12.5 ≠R | 8.1 |
| q74 | — | — | timeout |  | timeout |  |
| q75 | — | — | 95.8 | 8.7 | error |  |
| q76 | — | — | 279.2 | 22.5 | 10.6 | 8.1 |
| q77 | — | — | timeout |  | 17.3 | 10.7 |
| q78 | — | — | 66.7 | 15.7 | timeout |  |
| q79 | — | — | 75.8 | 5.2 | 17.4 | 10.0 |
| q80 | — | — | timeout |  | 23.8 | 15.2 |
| q81 | — | — | 3.2 | 0.9 | timeout |  |
| q82 | — | — | 42.0 | 2.3 | 5.1 | 3.8 |
| q83 | — | — | 2.4 ≠R | 1.0 | 22.8 | 22.1 |
| q84 | — | — | 6.1 | 0.7 | 1.6 | 0.6 |
| q85 | — | — | 15.8 | 2.4 | 3.2 | 1.5 |
| q86 | — | — | 79.8 | 73.2 | 12.1 | 11.3 |
| q87 | — | — | 27.2 | 5.0 | 65.6 | 63.9 |
| q88 | — | — | 91.3 | 26.1 | 25.4 | 5.0 |
| q89 | — | — | 20.9 | 1.4 | 5.6 | 5.0 |
| q90 | — | — | 20.6 | 1.2 | 1.6 | 1.6 |
| q91 | — | — | 1.9 | 0.6 | 1.1 | 0.4 |
| q92 | — | — | 1.5 | 0.4 | error |  |
| q93 | — | — | 96.6 | 9.0 | 10.8 | 6.2 |
| q94 | — | — | 17.4 | 1.1 | 8.6 ≠R | 7.2 |
| q95 | — | — | 33.4 | 18.3 | timeout |  |
| q96 | — | — | 69.0 | 3.2 | 4.7 | 2.2 |
| q97 | — | — | 25.0 | 4.6 | 53.0 | 52.5 |
| q98 | — | — | 2.6 | 0.5 | 4.6 | 2.3 |
| q99 | — | — | 14.9 | 2.6 | 5.7 | 4.9 |

#### SF10, seconds (120 s limit), run 1 Parquet

| query | A cold | A warm | B cold | B warm | P (8 GiB) cold | P (8 GiB) warm |
|---|---|---|---|---|---|---|
| q01 | 1.8 | 0.6 | 2.3 | 0.6 | timeout |  |
| q02 | 15.6 | 2.8 | 18.9 | 2.8 | 43.3 | 43.3 |
| q03 | 24.9 | 2.1 | 26.8 | 2.1 | 5.3 | 1.8 |
| q04 | timeout |  | timeout |  | timeout |  |
| q05 | timeout |  | timeout |  | timeout |  |
| q06 | 2.1 | 0.8 | 2.6 | 0.9 | error |  |
| q07 | 11.2 | 1.5 | 11.9 | 1.5 | 7.0 | 3.0 |
| q08 | 2.3 | 0.7 | 2.5 | 0.7 | 4.9 | 1.5 |
| q09 | 41.4 | 15.9 | 43.4 | 16.2 | 8.1 | 6.5 |
| q10 | 4.6 | 1.1 | 4.1 | 1.1 | 4.3 | 2.6 |
| q11 | timeout |  | timeout |  | timeout |  |
| q12 | 1.2 | 0.3 | 1.1 | 0.4 | 0.9 | 0.4 |
| q13 | 12.2 | 2.1 | 12.2 | 2.1 | 13.8 | 4.5 |
| q14_1 | timeout |  | timeout |  | 37.2 | 36.4 |
| q14_2 | 120.3 ≠R | 122.4 | 120.3 ≠R | 122.4 | 37.7 | 34.9 |
| q15 | 1.7 | 0.5 | 2.1 | 0.6 | 4.0 | 3.9 |
| q16 | 3.8 | 0.8 | 4.3 | 0.8 | 4.5 ≠R | 3.5 |
| q17 | 5.4 | 1.3 | 5.4 | 1.3 | 12.0 | 7.8 |
| q18 | 8.1 | 1.6 | 8.1 | 1.7 | 4.5 | 2.4 |
| q19 | 3.3 | 0.8 | 3.2 | 0.9 | 6.0 | 2.9 |
| q20 | 1.1 | 0.4 | 1.1 | 0.4 | 1.0 | 0.5 |
| q21 | 2.0 ≠R | 0.8 | 2.2 ≠R | 0.8 | 9.5 | 8.0 |
| q22 | 15.1 | 11.2 | 15.0 | 11.7 | 31.7 | 30.8 |
| q23_1 | 60.0 | 28.5 | 58.2 | 26.8 | 14.5 | 16.6 |
| q23_2 | 59.3 | 29.6 | 59.7 | 27.1 | 19.0 | 18.7 |
| q24_1 | 40.6 | 6.6 | 40.0 | 5.7 | 8.2 | 4.0 |
| q24_2 | 40.8 | 6.5 | 39.0 | 6.4 | 6.4 | 3.8 |
| q25 | 4.3 | 1.3 | 4.4 | 1.2 | 11.5 | 8.9 |
| q26 | 6.2 | 1.1 | 6.9 | 1.1 | 2.7 | 1.8 |
| q27 | 11.0 | 1.6 | 10.9 | 1.8 | 6.0 | 3.3 |
| q28 | 37.6 | 12.9 | 37.4 | 12.4 | 11.4 | 6.5 |
| q29 | 11.9 | 2.1 | 12.8 | 2.4 | 12.5 | 7.7 |
| q30 | 2.0 | 0.7 | 2.0 | 0.8 | timeout |  |
| q31 | 5.7 | 1.4 | 6.1 | 1.4 | 37.9 | 35.5 |
| q32 | 1.4 | 0.5 | 1.4 | 0.5 | error |  |
| q33 | 3.3 | 1.4 | 3.6 | 1.3 | 5.8 | 1.9 |
| q34 | 17.0 ≠R | 1.9 | 17.3 ≠R | 2.0 | 5.9 ≠R | 3.2 |
| q35 | 6.9 | 2.0 | 7.3 | 2.1 | timeout |  |
| q36 | 78.9 | 55.1 | 79.6 | 47.4 | 8.1 | 3.4 |
| q37 | 6.7 | 1.1 | 8.4 | 1.1 | 7.8 | 6.3 |
| q38 | 9.5 | 3.0 | 10.0 | 3.0 | 14.1 | 12.4 |
| q39_1 | 2.4 | 1.5 | 2.6 | 1.5 | 16.0 | 19.8 |
| q39_2 | 2.5 | 1.4 | 2.5 | 1.5 | 14.6 | 21.0 |
| q40 | 3.0 | 0.7 | 3.6 | 0.8 | 2.9 | 2.0 |
| q41 | 0.4 | 0.2 | 0.4 | 0.2 | error |  |
| q42 | 1.7 | 0.4 | 1.7 | 0.4 | 4.3 | 1.2 |
| q43 | 6.0 | 0.8 | 6.0 | 0.8 | 5.4 | 4.1 |
| q44 | 37.6 | 11.2 | 38.3 | 11.6 | 11.7 ≠R | 3.7 |
| q45 | 2.1 | 0.8 | 2.3 | 0.8 | 2.9 | 2.7 |
| q46 | 24.0 | 3.2 | 24.3 | 3.3 | 7.4 | 3.4 |
| q47 | 108.9 | 85.8 | 103.4 | 90.1 | 14.4 | 12.0 |
| q48 | 9.7 | 2.0 | 9.6 | 2.1 | 12.5 | 5.3 |
| q49 | 103.6 | 44.2 | 109.0 | 42.2 | 4.2 | 11.0 |
| q50 | 29.9 | 4.0 | 30.3 | 4.0 | 8.1 | 5.5 |
| q51 | 17.7 | 11.3 | 17.7 | 11.0 | 15.5 | 18.4 |
| q52 | 1.8 | 0.4 | 1.8 | 0.4 | 4.5 | 1.3 |
| q53 | 7.6 | 0.9 | 7.5 | 1.2 | 4.6 | 2.2 |
| q54 | 4.5 | 1.3 | 5.1 | 1.2 | 38.1 | 34.7 |
| q55 | 1.8 | 0.4 | 1.6 | 0.4 | 4.1 | 1.3 |
| q56 | 3.4 | 1.3 | 3.8 | 1.5 | 5.5 | 2.2 |
| q57 | 55.3 | 39.8 | 57.4 | 39.8 | 6.7 | 6.4 |
| q58 | 2.8 | 1.4 | 3.2 | 1.5 | 2.2 | 5.9 |
| q59 | 27.6 | 4.2 | 28.1 | 4.3 | 6.2 | 3.5 |
| q60 | 3.8 | 1.5 | 4.4 | 1.5 | 5.8 | 1.9 |
| q61 | 3.7 | 1.4 | 3.8 | 1.5 | 9.9 | 14.1 |
| q62 | 3.5 | 1.0 | 3.4 | 1.1 | 1.5 | 1.1 |
| q63 | 7.4 | 0.9 | 7.5 | 1.0 | 4.8 | 1.7 |
| q64 | 41.7 | 6.3 | 41.4 | 6.6 | error |  |
| q65 | 9.2 | 2.9 | 9.1 | 3.2 | 9.3 | 11.7 |
| q66 | 69.5 | 36.0 | 68.8 | 40.9 | 6.9 | 4.2 |
| q67 | timeout |  | timeout |  | 39.0 | 35.5 |
| q68 | 27.7 | 3.3 | 27.5 | 3.5 | 4.1 | 7.7 |
| q69 | 4.0 | 1.1 | 3.7 | 1.0 | 2.5 | 2.1 |
| q70 | timeout |  | timeout |  | 14.5 | 10.7 |
| q71 | 4.0 | 1.0 | 3.7 | 1.1 | 3.8 | 5.8 |
| q72 | 40.1 | 18.9 | 38.5 | 19.7 | timeout |  |
| q73 | 17.0 | 1.9 | 17.0 | 1.9 | 5.8 | 3.0 |
| q74 | timeout |  | timeout |  | timeout |  |
| q75 | 34.2 | 5.9 | 32.3 | 6.0 | error |  |
| q76 | 67.2 | 7.9 | 67.2 | 7.8 | 7.6 | 2.3 |
| q77 | timeout |  | timeout |  | 7.1 | 2.6 |
| q78 | 29.5 | 13.6 | 26.2 | 9.6 | 43.9 | 43.4 |
| q79 | 23.2 | 3.2 | 24.4 | 3.3 | 8.1 | 3.9 |
| q80 | timeout |  | timeout |  | 16.3 | 9.1 |
| q81 | 2.3 | 0.8 | 2.4 | 0.9 | timeout |  |
| q82 | 11.8 | 1.9 | 11.8 | 1.8 | 8.9 | 7.3 |
| q83 | 2.4 ≠R | 1.2 | 2.8 ≠R | 1.2 | 3.1 | 2.4 |
| q84 | 2.9 | 0.8 | 3.2 | 0.8 | 1.3 | 0.7 |
| q85 | 6.3 | 1.6 | 6.8 | 1.6 | 1.9 | 1.8 |
| q86 | 16.9 | 11.7 | 17.8 | 11.7 | 1.7 | 1.5 |
| q87 | 9.6 | 3.3 | 10.3 | 3.8 | 14.9 | 11.1 |
| q88 | 35.9 | 16.5 | 36.8 | 17.2 | 14.3 | 12.6 |
| q89 | 7.7 | 1.1 | 7.7 | 1.1 | 5.3 | 2.0 |
| q90 | 6.3 | 1.1 | 7.3 | 1.1 | 0.9 | 0.6 |
| q91 | 2.0 | 0.7 | 2.2 | 0.7 | 1.0 | 0.3 |
| q92 | 1.2 | 0.5 | 1.1 | 0.5 | error |  |
| q93 | 32.3 | 4.7 | 33.5 | 5.0 | 6.0 | 3.5 |
| q94 | 6.6 | 1.1 | 6.3 | 1.0 | 3.3 ≠R | 1.9 |
| q95 | 14.0 | 9.4 | 14.3 | 9.9 | timeout |  |
| q96 | 21.7 | 2.0 | 22.0 | 2.1 | 4.0 | 1.2 |
| q97 | 10.7 | 4.1 | 9.2 | 3.2 | 8.3 | 6.7 |
| q98 | 1.4 | 0.5 | 1.5 | 0.6 | 4.5 | 1.4 |
| q99 | 5.6 | 1.7 | 6.1 | 1.8 | 2.8 | 2.2 |

#### SF10 on Glue + Iceberg, seconds (120 s limit), run 3

| query | B cold | B warm | E cold | E warm | P (32 GiB) cold | P (32 GiB) warm |
|---|---|---|---|---|---|---|
| q01 | 2.0 | 0.8 | 1.6 | 0.4 | timeout |  |
| q02 | 5.8 | 2.6 | 2.3 | 0.7 | 40.8 | 41.4 |
| q03 | 4.7 | 1.3 | 1.9 | 0.4 | 0.9 | 0.5 |
| q04 | timeout |  | timeout |  | timeout |  |
| q05 | timeout |  | 70.2 | 65.2 | 103.2 | 101.6 |
| q06 | 4.8 | 1.2 | 1.9 | 0.6 | error |  |
| q07 | 9.1 | 2.7 | 3.0 | 0.7 | 1.5 | 0.8 |
| q08 | 4.9 | 1.3 | 2.0 | 0.6 | 1.5 | 1.2 |
| q09 | 14.7 | 11.8 | 3.6 | 2.7 | 2.0 | 1.5 |
| q10 | 7.3 | 1.9 | 3.0 | 0.8 | 2.1 | 1.5 |
| q11 | timeout |  | timeout |  | timeout |  |
| q12 | 2.4 | 0.6 | 1.2 | 0.3 | 0.7 | 0.4 |
| q13 | 11.7 | 4.4 | 3.6 | 1.1 | 2.4 | 1.3 |
| q14_1 | timeout |  | 113.9 | 111.5 | 38.8 | 38.2 |
| q14_2 | timeout |  | 99.0 | 95.9 | 35.8 | 36.0 |
| q15 | 3.6 | 0.9 | 1.4 | 0.4 | 1.0 | 0.6 |
| q16 | 6.4 | 1.9 | 2.2 | 0.6 | 2.4 ≠R | 1.7 |
| q17 | 9.7 | 2.9 | 3.2 | 1.0 | 3.1 | 2.0 |
| q18 | 7.6 | 2.3 | 2.8 | 0.8 | 2.0 | 1.0 |
| q19 | 7.2 | 2.1 | 2.3 | 0.7 | 1.4 | 0.7 |
| q20 | 3.1 | 0.7 | 1.2 | 0.3 | 0.8 | 0.5 |
| q21 | 7.9 ≠R | 2.6 | 2.2 ≠R | 0.8 | 2.4 ≠R | 2.2 |
| q22 | 26.8 | 21.1 | 6.7 | 5.5 | 25.8 | 24.2 |
| q23_1 | 37.8 | 28.4 | 6.7 | 4.0 | 5.2 | 3.7 |
| q23_2 | 37.8 | 29.7 | 6.7 | 4.1 | 4.4 | 4.4 |
| q24_1 | 10.4 | 4.7 | 3.4 | 1.4 | 1.9 | 1.2 |
| q24_2 | 10.2 | 4.6 | 3.2 | 1.3 | 1.9 | 1.2 |
| q25 | 10.2 | 3.5 | 3.5 | 1.0 | 3.0 | 2.1 |
| q26 | 6.0 | 1.6 | 2.0 | 0.5 | 1.2 | 0.6 |
| q27 | 8.8 | 2.5 | 2.4 | 0.6 | 1.5 | 0.8 |
| q28 | 12.5 | 9.7 | 2.7 | 1.9 | 1.8 | 1.2 |
| q29 | 10.1 | 3.3 | 3.3 | 1.0 | 2.9 | 2.0 |
| q30 | 2.2 | 0.7 | 1.4 | 0.5 | timeout |  |
| q31 | 7.5 | 2.4 | 2.3 | 0.7 | 29.3 | 29.0 |
| q32 | 3.6 | 1.3 | 1.3 | 0.4 | error |  |
| q33 | 10.7 | 3.2 | 3.4 | 1.2 | 1.9 | 1.0 |
| q34 | 6.4 ≠R | 2.2 | 2.2 ≠R | 0.7 | error |  |
| q35 | 7.9 | 3.0 | 2.8 | 1.0 | timeout |  |
| q36 | 55.3 | 50.1 | 20.9 | 19.4 | 3.0 | 2.3 |
| q37 | 9.2 | 3.0 | 2.3 | 0.7 | 5.6 | 3.0 |
| q38 | 8.0 | 3.7 | 2.5 | 1.0 | 6.5 | 6.2 |
| q39_1 | 9.7 | 4.5 | 2.4 | 1.2 | 4.6 | 3.3 |
| q39_2 | 10.1 | 4.4 | 2.4 | 1.2 | 4.3 | 3.3 |
| q40 | 4.6 | 1.2 | 1.8 | 0.5 | 1.1 | 0.6 |
| q41 | 0.5 | 0.2 | 0.4 | 0.1 | error |  |
| q42 | 4.2 | 1.0 | 1.3 | 0.3 | 0.7 | 0.3 |
| q43 | 4.0 | 1.2 | 1.3 | 0.3 | 0.7 | 0.5 |
| q44 | 12.4 | 8.3 | 4.2 | 2.7 | 1.7 ≠R | 1.4 |
| q45 | 3.2 | 1.2 | 1.5 | 0.5 | 0.6 | 0.5 |
| q46 | 10.3 | 3.7 | 3.2 | 1.0 | 1.8 | 1.4 |
| q47 | 87.2 | 83.2 | 30.3 | 29.3 | 13.0 | 13.0 |
| q48 | 9.2 | 3.5 | 2.8 | 1.0 | 1.7 | 0.9 |
| q49 | 53.6 | 42.8 | 20.4 | 16.7 | 4.4 | 4.0 |
| q50 | 7.9 | 3.2 | 2.3 | 0.8 | 1.5 | 1.0 |
| q51 | 16.3 | 12.1 | 3.7 | 2.5 | 14.7 | 14.5 |
| q52 | 4.5 | 1.0 | 1.3 | 0.3 | 0.7 | 0.3 |
| q53 | 5.7 | 1.5 | 1.7 | 0.4 | 1.3 | 1.0 |
| q54 | 11.7 | 2.7 | 3.1 ≠R | 0.9 | 34.9 | 35.9 |
| q55 | 6.4 | 1.1 | 1.4 | 0.3 | 0.7 | 0.4 |
| q56 | 9.7 | 2.6 | 3.2 | 1.1 | 2.0 | 1.1 |
| q57 | 44.3 | 42.5 | 16.2 | 15.2 | 7.4 | 6.9 |
| q58 | 8.2 | 3.1 | 2.9 | 1.0 | 2.3 | 1.8 |
| q59 | 6.7 | 3.7 | 1.9 | 0.9 | 1.4 | 1.0 |
| q60 | 11.0 | 3.2 | 3.5 | 1.2 | 1.9 | 1.0 |
| q61 | 10.1 | 4.3 | 3.2 | 1.3 | 1.9 | 1.2 |
| q62 | 3.3 | 1.2 | 1.4 | 0.4 | 0.7 | 0.5 |
| q63 | 5.7 | 1.4 | 1.7 | 0.5 | 1.2 | 0.8 |
| q64 | 20.1 | 8.2 | 6.4 | 2.4 | error |  |
| q65 | 9.1 | 5.4 | 2.4 | 1.2 | 7.6 | 7.2 |
| q66 | 44.3 | 38.8 | 16.9 | 15.3 | 2.0 | 1.5 |
| q67 | timeout |  | 52.6 | 51.3 | 35.2 | 34.6 |
| q68 | 11.4 | 4.1 | 3.5 | 1.1 | 2.0 | 1.3 |
| q69 | 7.0 | 2.0 | 2.7 | 0.7 | 1.9 | 1.4 |
| q70 | timeout |  | 46.3 | 45.5 | 10.0 | 9.9 |
| q71 | 10.5 | 2.6 | 3.3 | 0.9 | 3.3 | 3.0 |
| q72 | 35.3 | 26.1 | 8.0 | 5.4 | timeout |  |
| q73 | 6.3 | 2.2 | 2.2 | 0.6 | error |  |
| q74 | timeout |  | timeout |  | timeout |  |
| q75 | 16.5 | 7.0 | 5.4 | 1.8 | error |  |
| q76 | 15.0 | 6.9 | 5.6 | 2.9 | 1.7 | 1.5 |
| q77 | 120.4 ≠R | 122.1 | 49.8 | 46.3 | 2.8 | 2.0 |
| q78 | 24.4 | 14.2 | 5.3 | 2.4 | 41.4 | 41.2 |
| q79 | 10.0 | 3.7 | 3.0 | 0.9 | 2.2 | 1.7 |
| q80 | timeout |  | 73.9 | 69.8 | 4.0 | 3.1 |
| q81 | 2.4 | 0.9 | 1.3 | 0.5 | timeout |  |
| q82 | 9.6 | 3.6 | 4.2 | 0.8 | 6.7 | 4.4 |
| q83 | 3.4 ≠R | 1.4 | 1.9 ≠R | 0.9 | 3.5 | 3.0 |
| q84 | 2.5 | 0.7 | 1.5 | 0.5 | 0.9 | 0.4 |
| q85 | 6.3 | 1.8 | 2.6 | 0.8 | 1.6 | 1.0 |
| q86 | 14.1 | 12.1 | 6.1 | 5.5 | 1.6 | 1.3 |
| q87 | 8.2 | 4.3 | 2.7 | 1.1 | 6.9 | 6.5 |
| q88 | 15.1 | 11.8 | 4.2 | 3.3 | 2.9 | 2.7 |
| q89 | 5.3 | 1.7 | 1.8 | 0.5 | 1.8 | 1.4 |
| q90 | 3.0 | 1.2 | 1.3 | 0.5 | 0.8 | 0.5 |
| q91 | 2.8 | 0.8 | 1.8 | 0.5 | 1.2 | 0.6 |
| q92 | 2.6 | 0.8 | 1.1 | 0.4 | error |  |
| q93 | 8.3 | 4.7 | 2.2 | 1.1 | 1.5 | 0.9 |
| q94 | 5.2 | 1.3 | 1.7 | 0.5 | 1.7 ≠R | 1.0 |
| q95 | 10.4 | 7.3 | 2.7 | 1.7 | timeout |  |
| q96 | 4.3 | 1.4 | 1.4 | 0.5 | 0.6 | 0.3 |
| q97 | 8.4 | 4.6 | 2.0 | 0.8 | 5.6 | 5.1 |
| q98 | 4.9 | 1.3 | 1.5 | 0.4 | 1.1 | 0.8 |
| q99 | 5.1 | 2.0 | 1.8 | 0.7 | 0.9 | 0.6 |

---

## 한국어

[RESULTS.md](RESULTS.md)의 같은 측정을 숨김 없이 읽은 문서입니다. 어디서 이기고 졌는지, 추정 원인(추정이라고 표시), 정가 기준 계산을 담습니다. 질의별 표는 위 영어 절과 같습니다.

### 질문별 결론

1. **db.t4g에서 aurora_analytics가 되는가:** 된다. t4g.medium·large: SF1 100/103, SF10 94/103, 메모리 부족 0. SF100의 t4g.large는 3시간에 103개 중 75개를 실행해 53개 완료(시간 초과 20, OOM 2). 4 GiB와 8 GiB는 중앙값 1–2% 차이.
2. **같은 vCPU(8), SF100에서 누가 더 끝냈나:** Aurora r8gd.2xlarge 92/103, ClickHouse 경로 78/103. Aurora만 끝낸 질의 18개, 반대는 4개.
3. **누가 빠른가:** 캐시에 따라 갈린다.
   - 첫 실행: ClickHouse 경로. 공통 74개 합계 약 2.9배(1,337초 vs 3,860초), 기하평균 11.3초 vs 21.1초.
   - 반복 실행: 질의별로는 Aurora. 기하평균 3.05초 vs 8.09초, 74개 중 37개에서 3배 이상 빠름(ClickHouse가 3배 이상 빠른 것 6개). 합계가 같은 것(1,130초 vs 1,140초)은 ClickHouse가 무거운 몇 개를 크게 이기기 때문(q66 22.7배, q36 16.3배).
   - SF10(2 vCPU t4g vs 8 GiB 레플리카)도 같은 모양: 첫 실행 합계 1,589초 vs 758초, 반복 기하평균 2.52초 vs 4.17초.
4. **답이 맞는가:** Aurora는 PostgreSQL 의미를 따른다(SF1 비교 가능 99개 중 98개가 PostgreSQL 18과 같음). ClickHouse 경로는 q16·q94(부등호 조건 `EXISTS`)와 q44에서 모든 규모에서 두 기준 모두와 다른 답.
5. **Glue 카탈로그 + Iceberg:** 둘 다 됨. Aurora `IMPORT FOREIGN SCHEMA`, ClickHouse `DataLakeCatalog` 모두 24개 표를 행 수까지 맞게 봄. SF10 Iceberg에서 Aurora r8gd 100/103, ClickHouse 경로 86/103(26.6.1에서 Iceberg 읽기 오류 q34·q73 추가).

### ClickHouse 경로가 진 곳과 이유 (측정이라고 쓴 것 외에는 추정)

- **ClickHouse 자체보다 pg_clickhouse 경유에서.** SF100의 103개 중 통째로 내려간 것은 28개(EXPLAIN VERBOSE, 측정). 나머지는 조인·집계·정렬이 Postgres 앞단에 남아 중간 행을 TLS로 끌어온다. SF100 시간 초과 16개 중 15개가 일부만 내려간 질의(계획 분류는 측정, 끌어온 행이 원인이라는 것은 추정, 연산자별 시간은 재지 않음).
- **생성 SQL:** 모든 규모에서 오류 6개 — 상관 서브쿼리(q06·q32·q41·q92, 26.6.1의 "Resolved identifier … in parent scope", 로컬 리허설의 26.9 + pg_clickhouse 0.11에서는 없음), `ALL INNER JOIN` 문법(q64), Decimal/Float64 공통 타입(q75).
- **조인 메모리:** SF100의 q17·q25·q29(통째로 내려간 팩트 테이블 3개 조인)가 서버 한도 28.8 GiB에 걸림. 기본 해시 조인은 디스크로 넘기지 않음(`join_algorithm` 변경은 시험 안 함).
- **질의당 바닥 시간:** 반복 실행에서 Aurora 캐시가 1초 안쪽으로 답하는 가벼운 질의가 ClickHouse 경로에서는 수 초(q31 24.8배, q83 22.3배). 앞단→ClickHouse 왕복이 바닥으로 보임(따로 재지 않음).
- **메모리가 같지 않음:** E 64 GiB, ClickHouse 레플리카 하나 32 GiB.

### Aurora가 진 곳과 이유

- **S3에서 차가운 읽기:** 첫 실행마다 Parquet를 S3에서 로컬 캐시로 다시 읽는다. SF10·SF100 모두 첫 실행 합계가 ClickHouse 경로의 2–3배.
- **무거운 집계·윈도 질의:** q66·q36·q86·q88의 반복 실행이 ClickHouse보다 5–23배 느림.
- **운영:** 실행 중 질의를 `statement_timeout`·`pg_cancel_backend()`로 멈출 수 없고 `pg_terminate_backend()`로만 멈춤. 분석이 같은 인스턴스의 OLTP와 CPU를 나눔(t4g에서 CPU 99.7%, OLTP 지연은 재지 않음). T4g Unlimited: 실행 1 동안 두 t4g가 CPU 크레딧을 약 27씩 빌림(24시간 평균 기준선 초과분 vCPU-시간당 $0.09).
- **키우기 = OLTP 인스턴스 크기 변경.**

### 정가 기준 계산 (SF100, 공통 74개, 앞단 제외)

| | Aurora r8gd.2xlarge ($1.502/시간) | ClickHouse 32 GiB × 2 ($3.84/시간) |
|---|---|---|
| 첫 실행 한 바퀴 | 3,860초 → $1.61 | 1,337초 → $1.43 |
| 반복 실행 한 바퀴 | 1,130초 → $0.47 | 1,140초 → $1.22 |

인스턴스 시간만, 다른 작업이 없다고 본 계산. ClickHouse 쪽은 Managed Postgres 앞단, Aurora 쪽은 스토리지·I/O를 뺐다. ClickHouse 질의는 레플리카 하나에서 돌고, 두 번째 레플리카는 이 조직에서 웨어하우스 첫 서비스의 최소 개수(API 스펙)라 레플리카 1개 가격이면 ClickHouse 열이 절반이 된다. TCO가 아님.
