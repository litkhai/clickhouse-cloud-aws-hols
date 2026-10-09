# Aurora PostgreSQL 18.6 — builtin `C.UTF-8` collation check (2026-10-09)

[English](#english) | [한국어](#한국어)

## English

Run once on 2026-10-09 in ap-northeast-2 on Aurora PostgreSQL **18.6** (`PostgreSQL 18.6 on aarch64-linux, compiled by gcc-10.5.0`), db.t4g.medium, a fresh cluster with default settings, from an EC2 client in the same VPC (psql 18.6). Database names below are generic.

**Result: Aurora accepts the builtin locale provider with `C.UTF-8`.**

```sql
CREATE DATABASE db_builtin TEMPLATE template0 ENCODING 'UTF8'
  LOCALE_PROVIDER builtin BUILTIN_LOCALE 'C.UTF-8' LOCALE 'C';
-- CREATE DATABASE
-- pg_database: datlocprovider = b, datcollate = C, datctype = C, datlocale = C.UTF-8
```

Cluster defaults: `template0`, `template1` and `postgres` are libc `en_US.UTF-8`. `pg_collation` lists three builtin collations: `pg_c_utf8` (C.UTF-8), `pg_unicode_fast` (PG_UNICODE_FAST) and `ucs_basic` (C); libc `C`, `C.utf8` and `POSIX` are present.

The same checks in three databases (one table, 200,008 rows, a plain B-tree index on `name`, `ANALYZE`):

| | builtin `C.UTF-8` (+ `LOCALE 'C'`) | libc `C` | default (`CREATE DATABASE x;` → libc `en_US.UTF-8`) |
|---|---|---|---|
| `ORDER BY name` over `하늘 가방 나무 다리 apple Banana cherry Apple` | `Apple Banana apple cherry 가방 나무 다리 하늘` | same as builtin | `가방 나무 다리 하늘 apple Apple Banana cherry` |
| `EXPLAIN … WHERE name LIKE 'n00001%'` | Index Scan, `Index Cond: name >= 'n00001' AND name < 'n00002'` | Index Scan, same | **Seq Scan** |
| `ILIKE 'apple'` | `apple Apple` | `apple Apple` | `apple Apple` |
| `ILIKE 'b%'` | `Banana` | `Banana` | `Banana` |
| `upper('abc 가방')` | `ABC 가방` | `ABC 가방` | `ABC 가방` |

Notes
- Builtin `C.UTF-8` and libc `C` sort by code point: upper case, then lower case, then Hangul; the four Hangul words came out in 가나다 order (Hangul syllables are in that order in Unicode).
- The default `en_US.UTF-8` database also sorted these four Hangul words in 가나다 order, before Latin. **This sample is four words only**; an earlier local measurement on Amazon Linux 2 (glibc 2.26) found `en_US` not in 가나다 order on a larger sample, which this run does not confirm or refute.
- In the default database a prefix `LIKE` cannot use a plain index (Seq Scan); it would need `text_pattern_ops` or a C collation.
- `SHOW lc_collate` fails on 18.6 (`unrecognized configuration parameter`), as on any PostgreSQL 16+.
- Not checked: other Aurora 17.x / 18.x minors, `pg_unicode_fast`, case-insensitive ICU collations, a larger Hangul sample.

## 한국어

2026-10-09 서울 리전, Aurora PostgreSQL **18.6**(`PostgreSQL 18.6 on aarch64-linux, compiled by gcc-10.5.0`), db.t4g.medium, 기본 설정의 새 클러스터에서 같은 VPC의 EC2 클라이언트(psql 18.6)로 한 번 실행했습니다. 아래 DB 이름은 일반 이름입니다.

**결과: Aurora는 builtin locale provider의 `C.UTF-8`을 받습니다.**

```sql
CREATE DATABASE db_builtin TEMPLATE template0 ENCODING 'UTF8'
  LOCALE_PROVIDER builtin BUILTIN_LOCALE 'C.UTF-8' LOCALE 'C';
-- CREATE DATABASE
-- pg_database: datlocprovider = b, datcollate = C, datctype = C, datlocale = C.UTF-8
```

클러스터 기본값: `template0`·`template1`·`postgres`는 libc `en_US.UTF-8`. `pg_collation`에는 builtin collation 세 개 `pg_c_utf8`(C.UTF-8), `pg_unicode_fast`(PG_UNICODE_FAST), `ucs_basic`(C)이 있고, libc `C`·`C.utf8`·`POSIX`도 있습니다.

세 DB에서 같은 확인(표 하나, 200,008행, `name`에 일반 B-tree 인덱스, `ANALYZE`):

| | builtin `C.UTF-8` (+ `LOCALE 'C'`) | libc `C` | 기본값(`CREATE DATABASE x;` → libc `en_US.UTF-8`) |
|---|---|---|---|
| `하늘 가방 나무 다리 apple Banana cherry Apple`의 `ORDER BY name` | `Apple Banana apple cherry 가방 나무 다리 하늘` | builtin과 같음 | `가방 나무 다리 하늘 apple Apple Banana cherry` |
| `EXPLAIN … WHERE name LIKE 'n00001%'` | Index Scan, `Index Cond: name >= 'n00001' AND name < 'n00002'` | Index Scan, 같음 | **Seq Scan** |
| `ILIKE 'apple'` | `apple Apple` | `apple Apple` | `apple Apple` |
| `ILIKE 'b%'` | `Banana` | `Banana` | `Banana` |
| `upper('abc 가방')` | `ABC 가방` | `ABC 가방` | `ABC 가방` |

참고
- builtin `C.UTF-8`과 libc `C`는 코드 포인트 순서로 정렬합니다(대문자 → 소문자 → 한글). 한글 네 단어는 가나다순이었습니다(유니코드의 한글 음절 순서가 가나다순).
- 기본값 `en_US.UTF-8` DB도 이 네 단어를 가나다순으로, 라틴 문자보다 앞에 정렬했습니다. **표본이 네 단어뿐입니다.** 앞서 Amazon Linux 2(glibc 2.26)에서 더 큰 표본으로 en_US가 가나다순이 아니었던 로컬 측정을 이번 실행은 확인도 반박도 하지 못합니다.
- 기본값 DB에서는 앞부분 `LIKE`가 일반 인덱스를 쓰지 못합니다(Seq Scan). `text_pattern_ops`나 C collation이 필요합니다.
- 18.6에서 `SHOW lc_collate`는 `unrecognized configuration parameter`로 실패합니다(PostgreSQL 16 이상과 같음).
- 확인 안 한 것: 다른 Aurora 17.x·18.x 마이너, `pg_unicode_fast`, 대소문자 무시 ICU collation, 더 큰 한글 표본.
