# Decrypting KMS-protected values inside JSON after Postgres CDC — a ClickHouse Cloud UDF vs a key kept in ClickHouse

> **Last run: 2026-11-04** — every step ran once, one script at a time in the order `deploy.sh` lists them, then `cdc-changes.sh`, the checks and `destroy.sh`, on AWS `ap-northeast-2`: Aurora PostgreSQL 16.13 (`db.t4g.medium`, `rds.logical_replication = 1`), a ClickHouse Cloud test service (1 replica, 8 GiB, ClickHouse 26.6.1.2455, `max_threads` 2), ClickPipes Postgres CDC (`syncIntervalSeconds` 10, `pullBatchSize` 100000), a Python 3.11 executable UDF (`sandboxType: netenable`). Terraform 1.16.4, `hashicorp/aws` 5.100.0. `deploy.sh` itself was not run as one script. Not run: the IAM-user path (`create_udf_user = true`) — an SCP in the lab account denied `iam:CreateUser`, so the UDF got 1-hour STS credentials from a role; path C (decrypt before load, e.g. a Lambda) is described, not run. Local rehearsal of the UDF against real KMS on clickhouse local 26.9.6.6, 10,000 of 10,000 rows correct.
>
> **마지막 실행: 2026-11-04** — `deploy.sh`에 적힌 순서대로 스크립트를 하나씩 한 번 실행하고, 이어서 `cdc-changes.sh`, 검사, `destroy.sh`까지 실행. AWS `ap-northeast-2`: Aurora PostgreSQL 16.13(`db.t4g.medium`, `rds.logical_replication = 1`), ClickHouse Cloud 테스트 서비스(replica 1개, 8 GiB, ClickHouse 26.6.1.2455, `max_threads` 2), ClickPipes Postgres CDC(`syncIntervalSeconds` 10, `pullBatchSize` 100000), Python 3.11 실행형 UDF(`sandboxType: netenable`). Terraform 1.16.4, `hashicorp/aws` 5.100.0. `deploy.sh`를 한 번에 돌리지는 않았다. 실행하지 않은 것: IAM 사용자 경로(`create_udf_user = true`) — 실습 계정의 SCP가 `iam:CreateUser`를 막아 UDF는 역할의 1시간 STS 자격 증명을 썼다. 경로 C(적재 전 복호화, 예: Lambda)는 설명만 했다. UDF를 실제 KMS로 clickhouse local 26.9.6.6에서 미리 돌려 10,000행 중 10,000행 정답.

[English](#english) | [한국어](#한국어)

## English

An application encrypts sensitive values with AES-256-CBC under a data key that AWS KMS wraps (envelope encryption) and stores them in PostgreSQL — most of them **inside a `jsonb` column**. ClickPipes copies the table to ClickHouse Cloud with CDC. Can ClickHouse Cloud decrypt those values itself, with the key still protected by KMS, instead of a Lambda in front of the load?

| | Path | Where the data key comes from |
|---|---|---|
| **A** | Executable UDF `kms_unwrap` + built-in `decrypt()` | The UDF calls KMS `Decrypt` on the encrypted data key (cached per pool process); `decrypt('aes-256-cbc', …)` does the AES |
| **B** | Key kept in ClickHouse | Plaintext data keys in a table behind a dictionary (`keys.plain_key_dict`), keyed by `hex(SHA256(edk))` |
| **C** | Decrypt before load | A Lambda (or the application) decrypts and the pipe carries plaintext — not run here |

### Answer

- **It works.** A Python UDF in ClickHouse Cloud can call KMS over the public endpoint (standard library only, SigV4 by hand) and hand the data key to the built-in `decrypt()`. AES-256-CBC with PKCS7 from Python `cryptography` and OpenSSL decrypts as is. On 1,000,000 users plus 22,101 CDC changes, A and B gave identical rows (`sum(cityHash64(…))` equal on 1,009,100 rows), and every field matched the plaintext the generator kept.
- **But the key leaves KMS's control in ways a Lambda does not:**
  1. A Cloud UDF has **no cloud identity and no secret store** yet, so the AWS credentials ship inside the UDF zip. Static keys, or short STS credentials you must republish before they expire (≈3.5 minutes per republish here).
  2. **Any SQL user can call the UDF.** A user with `SELECT` on one decrypted table only called `kms_unwrap(edk)` and got a plaintext data key back. The encrypted data key is not secret (it sits next to the data), so in practice everyone who can query the service can unwrap keys.
  3. **A failing UDF stops the whole pipe.** With broken credentials the view failed, ClickPipes retried the same batch, and nothing else arrived — not even path B's table or `raw.users` — for 7 minutes, until a fixed version was attached.
- **Key granularity decides the cost.** One data key per tenant: 8 KMS calls for 1,000,000 rows (13.8 s to decrypt them, vs 11.9 s with the key in ClickHouse). One data key per row: about 37 KMS calls per second from the UDF — 10,000 new keys held one CDC batch for 4.5 minutes.
- **Choose C (decrypt before load)** when keys must stay inside the IAM/KMS boundary or more than a few people can query the service. **Choose B** when the key may live in ClickHouse: no KMS on the ingest path, ordinary `GRANT`s protect the key table and dictionary, rotation is a new key id. **Choose A** only for a service with few, trusted SQL users, a key per tenant (not per row), and a credential-rotation job that republishes the UDF.

### Results (2026-11-04)

Data: 1,000,000 users in 8 tenants (one data key each), `properties` jsonb with 8 keys of which `name`, `birthday`, `memo` are encrypted, plus encrypted `email_enc` and `phone_enc`. 812 MB in Aurora; generation + `COPY` from a laptop in Seoul 69 s.

| Step | Measured |
|---|---|
| ClickPipe create → `Running` (snapshot of 1,000,000 rows) | 186 s (`Provisioning` 3 min, `Snapshot` ≈20 s) |
| `raw.users` (ciphertext) | 200.5 MiB compressed / 762 MiB |
| Decrypted table `app.users_a` | 24.6 MiB compressed / 249 MiB — ciphertext (random, base64) hardly compresses |
| Backfill 1,000,000 rows, A (UDF + KMS) | 13.8 s |
| Backfill 1,000,000 rows, B (dictionary) | 11.9 s, 800 MiB memory, 16.5 s user CPU |
| Correct rows after the snapshot, A and B | 1,000,000 / 1,000,000 (properties, email, phone) |
| CDC: 1,000 updates with 8 new keys → visible in `users_a` | 15 s (raw 11 s); view time A 377 ms, B 94 ms |
| CDC: 10,000 users with one key each | B 0.5 s; A 271.8 s for the batch — 10,000 KMS calls, ≈2,200 per minute |
| Correct rows after CDC (10,000 updates with rotated keys, 1,000 deletes, 10,000 per-row keys) | 1,009,000 / 1,009,000 in A and B; deleted rows hidden by `FINAL` |
| KMS `Decrypt` calls by the UDF role, whole run (CloudTrail) | 12,500, all from one service egress IP |
| Search on stored plaintext vs decrypting at query time (41,902 matches) | 0.13 s vs 1.7–2.1 s; first run 65.7 s (cold key cache, 10,000 per-row keys) |
| Broken UDF credentials → pipe | `Running` but stuck: raw, A and B all stopped; caught up 219 s after republishing (build 128 s, attach 78 s, `SYSTEM RELOAD FUNCTION`) |

#### Who can reach a key

| Check | Result |
|---|---|
| `analyst` (only `SELECT ON app.users_a`) reads `raw.users`, `keys.plain_keys`, `dictGet(plain_key_dict)` | denied (`Code: 497`) |
| `analyst` calls `kms_unwrap('<edk>')` | **returns the plaintext data key** — no grant is checked for an executable UDF |
| Plaintext keys loaded with `INSERT … FORMAT TSV` (data, not query text) — found in `system.query_log` | 0 of 10,024 |
| A literal key inside `decrypt(…)` | logged as `decrypt('aes-256-cbc', '[HIDDEN]')` — the masking rule covers `encrypt`/`decrypt` arguments |
| A literal key elsewhere (`unhex('<key>')`) | logged as written (positive control: 1 key, 2 rows) |
| The UDF's `config.json` (AWS credentials) | not visible in SQL (`system.functions` has no `create_query` for it); it lives in the uploaded zip |

#### JSON typing in the views

The decrypted `properties` keeps every value as a string, so conditions cast at query time. The backfill used `SETTINGS input_format_try_infer_dates = 0, input_format_try_infer_datetimes = 0`. The first version of the views did not, and the 20,000 rows that came through CDC stored `lastVisitedAt` and `birthday` as `DateTime64(9)` (`"2026-04-02T03:00:00Z"` → `2026-04-02 03:00:00.000000000`): a `String` into a `JSON` column is parsed with the **inserting session's** settings — ClickPipes'. Tested on the same service:

| View SELECT | Stored type of `"2026-01-01"`, `"2026-04-02T03:00:00Z"` |
|---|---|
| `SELECT j` (String into a JSON column) | `Date`, `DateTime` |
| `SELECT j … SETTINGS input_format_try_infer_dates = 0, …` | `Date`, `DateTime` |
| `SELECT CAST(JSONExtract(j, 'Map(String, String)'), 'JSON')` | `Date`, `DateTime` |
| `SELECT CAST(j, 'JSON') … SETTINGS input_format_try_infer_dates = 0, …` | **`String`, `String`** |

`sql/30-mvs.sql` uses the last form; 1,000 later updates through it stored `String`.

#### Cost

AWS from the Price List × usage: Aurora `db.t4g.medium` $0.113 per hour × about 1 hour, about 22,500 KMS requests at $0.03 per 10,000, two KMS keys for a few hours — about $0.25. ClickHouse Cloud (one 8 GiB replica for about 1 hour, ClickPipes CDC for about 35 minutes) is billed in the Cloud console; not read here.

### What it does

```
Aurora PostgreSQL 16 ── ClickPipes Postgres CDC ──> raw.users (ciphertext, SharedReplacingMergeTree(_peerdb_version))
  users.properties jsonb                                 │
  "name": "enc:v1:<base64(iv‖ct)>"                       ├─ users_a_mv: kms_unwrap(edk) → decrypt() → app.users_a
  users.edk = KMS-encrypted data key                     └─ users_b_mv: dictGet(plain_key_dict, sha256(edk)) → decrypt() → app.users_b
```

- `gen.py` does what the application would: `GenerateDataKey` per tenant (or per row), AES-256-CBC with a random IV per value, the encrypted data key stored on the row (`edk`). It also writes the expected plaintext and, for path B only, the plaintext keys.
- `udf/kms_unwrap/main.py` — TabSeparated in, hex key out, one KMS call per distinct `edk` per process. `udf-deploy.sh` builds the zip with `config.json`, uploads it (`POST /udfUploads/url`, `PUT` to the URL), creates or versions the UDF and attaches it. Attaching the first UDF restarts the service (rolling).
- `sql/10-functions.sql` — SQL UDFs `dec_val` (one value) and `dec_props` (top-level jsonb text → `Map(String, String)` with encrypted values decrypted). No key material in any definition.
- ClickPipes copies `jsonb` as `String` and creates `SharedReplacingMergeTree(…, _peerdb_version)` with `_peerdb_is_deleted`. The source table has `REPLICA IDENTITY FULL`, so a delete carries the old row and its `edk`. The targets are `ReplacingMergeTree(_peerdb_version, _peerdb_is_deleted)`, so `FINAL` hides deleted users.

### Run it

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # owner, ttl, your /32; create_udf_user = false if an SCP forbids IAM users
export CHC_KEY=… CHC_SECRET=… ORG_ID=… SERVICE_ID=… CH_HOST=… CH_USER=default CH_PASSWORD=…   # a test service in ap-northeast-2
./deploy.sh          # or the steps one by one, as on 2026-11-04
./cdc-changes.sh     # 10,000 updates with rotated keys, 1,000 deletes, 10,000 users with a key each
clickhouse client … --param_t=users_a --queries-file sql/42-verify-final.sql
./destroy.sh         # pipe, UDF, lab databases, Terraform; delete the test service yourself
```

With role credentials (`create_udf_user = false`) the UDF stops working an hour after `udf-deploy.sh`; run it again before that.

## 한국어

애플리케이션이 민감한 값을 AES-256-CBC로 암호화해 PostgreSQL에 저장한다. 데이터 키는 AWS KMS가 감싼다(envelope 암호화). 암호화된 값은 대부분 **`jsonb` 컬럼 안에** 있다. ClickPipes가 이 테이블을 CDC로 ClickHouse Cloud에 복사한다. 적재 앞단의 Lambda 대신, 키를 KMS로 보호한 채 ClickHouse Cloud가 직접 풀 수 있을까?

| | 경로 | 데이터 키를 얻는 곳 |
|---|---|---|
| **A** | 실행형 UDF `kms_unwrap` + 내장 `decrypt()` | UDF가 암호화된 데이터 키로 KMS `Decrypt`를 부른다(pool 프로세스마다 캐시). AES는 `decrypt('aes-256-cbc', …)` |
| **B** | 키를 ClickHouse에 둔다 | 평문 데이터 키를 테이블에 두고 딕셔너리(`keys.plain_key_dict`)로 찾는다. 키 id는 `hex(SHA256(edk))` |
| **C** | 적재 전 복호화 | Lambda(또는 애플리케이션)가 풀고 파이프는 평문을 나른다 — 이번에 실행하지 않음 |

### 답

- **된다.** ClickHouse Cloud의 Python UDF가 KMS 공개 엔드포인트를 부를 수 있고(표준 라이브러리만, SigV4 직접 서명), 받은 데이터 키를 내장 `decrypt()`에 넘기면 된다. Python `cryptography`와 OpenSSL로 만든 AES-256-CBC(PKCS7) 암호문이 그대로 풀린다. 유저 1,000,000명과 CDC 변경 22,101건에서 A와 B의 결과가 같았고(1,009,100행의 `sum(cityHash64(…))` 일치), 모든 필드가 생성기가 남긴 평문과 같았다.
- **다만 Lambda와 달리 키가 KMS 통제를 벗어나는 지점이 생긴다.**
  1. Cloud UDF에는 아직 **클라우드 신원도 비밀 저장소도 없다.** AWS 자격 증명을 UDF zip 안에 넣어야 한다. 정적 키를 쓰거나, 짧은 STS 자격 증명을 만료 전에 다시 배포해야 한다(이번에 다시 배포 한 번에 약 3.5분).
  2. **SQL 사용자라면 누구나 UDF를 부를 수 있다.** 복호화된 테이블 하나에 `SELECT` 권한만 있는 사용자가 `kms_unwrap(edk)`를 불러 평문 데이터 키를 받았다. 암호화된 데이터 키는 데이터 옆에 있어 비밀이 아니다. 결국 서비스에 쿼리할 수 있는 사람은 모두 키를 풀 수 있다.
  3. **UDF가 실패하면 파이프 전체가 멈춘다.** 자격 증명을 망가뜨리자 뷰가 실패했고, ClickPipes는 같은 배치를 다시 시도했다. 고친 버전을 붙일 때까지 7분 동안 아무것도 들어오지 않았다. 경로 B의 테이블과 `raw.users`도 마찬가지였다.
- **키 단위가 비용을 정한다.** 테넌트마다 키 하나면 1,000,000행에 KMS 호출 8번이다(복호화 13.8초, ClickHouse에 키를 둔 B는 11.9초). 행마다 키 하나면 UDF에서 KMS 호출이 초당 약 37번이다. 새 키 10,000개가 CDC 배치 하나를 4.5분 붙잡았다.
- **C(적재 전 복호화)를 고를 때:** 키가 IAM/KMS 경계 안에 있어야 하거나, 서비스에 쿼리하는 사람이 몇 명을 넘는다.
- **B를 고를 때:** 키가 ClickHouse에 있어도 된다. 적재 경로에 KMS가 없고, 키 테이블과 딕셔너리는 평범한 `GRANT`로 보호되며, 키 교체는 새 키 id가 된다.
- **A는 이럴 때만:** SQL 사용자가 적고 믿을 수 있으며, 키가 행마다가 아니라 테넌트마다이고, 자격 증명을 교체하며 UDF를 다시 배포하는 작업이 있다.

### 결과 (2026-11-04)

데이터: 테넌트 8개(키 하나씩)에 유저 1,000,000명. `properties` jsonb에 키 8개가 있고 그중 `name`·`birthday`·`memo`가 암호화돼 있다. `email_enc`·`phone_enc`도 암호화돼 있다. Aurora에서 812 MB, 서울의 노트북에서 생성 + `COPY`에 69초.

| 단계 | 측정 |
|---|---|
| ClickPipe 생성 → `Running`(1,000,000행 스냅샷) | 186초(`Provisioning` 3분, `Snapshot` 약 20초) |
| `raw.users`(암호문) | 압축 200.5 MiB / 원본 762 MiB |
| 복호화 테이블 `app.users_a` | 압축 24.6 MiB / 249 MiB — 암호문(무작위, base64)은 거의 압축되지 않는다 |
| 1,000,000행 채우기, A(UDF + KMS) | 13.8초 |
| 1,000,000행 채우기, B(딕셔너리) | 11.9초, 메모리 800 MiB, user CPU 16.5초 |
| 스냅샷 뒤 정답 행, A·B | 1,000,000 / 1,000,000(properties, email, phone) |
| CDC: 새 키 8개로 갱신 1,000건 → `users_a`에 보이기까지 | 15초(raw 11초). 뷰 시간 A 377 ms, B 94 ms |
| CDC: 키가 행마다 다른 유저 10,000명 | B 0.5초. A는 그 배치에 271.8초 — KMS 호출 10,000번, 분당 약 2,200번 |
| CDC 뒤 정답 행(키를 바꾼 갱신 10,000건, 삭제 1,000건, 행마다 키 10,000명) | A·B 모두 1,009,000 / 1,009,000. 삭제된 행은 `FINAL`이 숨긴다 |
| 실행 전체에서 UDF 역할의 KMS `Decrypt` 호출(CloudTrail) | 12,500번, 모두 서비스 egress IP 하나에서 |
| 저장된 평문 검색 vs 쿼리 시점 복호화(41,902건 일치) | 0.13초 vs 1.7~2.1초. 첫 실행 65.7초(키 캐시가 비어 있고 행마다 키 10,000개) |
| UDF 자격 증명이 깨졌을 때 파이프 | 상태는 `Running`이지만 멈춤: raw·A·B 모두 정지. 다시 배포한 뒤 219초 만에 따라잡음(빌드 128초, 붙이기 78초, `SYSTEM RELOAD FUNCTION`) |

#### 누가 키에 닿을 수 있나

| 확인 | 결과 |
|---|---|
| `analyst`(`app.users_a`에 `SELECT`만)가 `raw.users`, `keys.plain_keys`, `dictGet(plain_key_dict)` 읽기 | 거부(`Code: 497`) |
| `analyst`가 `kms_unwrap('<edk>')` 호출 | **평문 데이터 키를 돌려받음** — 실행형 UDF에는 권한 검사가 없다 |
| `INSERT … FORMAT TSV`(쿼리 문장이 아니라 데이터)로 넣은 평문 키가 `system.query_log`에 있는가 | 10,024개 중 0개 |
| `decrypt(…)` 안의 키 리터럴 | `decrypt('aes-256-cbc', '[HIDDEN]')`로 기록 — masking 규칙이 `encrypt`/`decrypt` 인자를 가린다 |
| 다른 곳의 키 리터럴(`unhex('<key>')`) | 쓴 그대로 기록(양성 대조: 키 1개, 2행) |
| UDF의 `config.json`(AWS 자격 증명) | SQL로는 보이지 않는다(`system.functions`에 `create_query` 없음). 업로드한 zip 안에 있다 |

#### 뷰에서 JSON 타입

복호화한 `properties`는 모든 값을 문자열로 둔다. 조건은 쿼리 시점에 형변환한다. 채우기 쿼리에는 `SETTINGS input_format_try_infer_dates = 0, input_format_try_infer_datetimes = 0`을 썼다. 첫 버전의 뷰에는 이 설정이 없었다. 그래서 CDC로 들어온 20,000행은 `lastVisitedAt`과 `birthday`를 `DateTime64(9)`로 저장했다(`"2026-04-02T03:00:00Z"` → `2026-04-02 03:00:00.000000000`). `String`을 `JSON` 컬럼에 넣으면 **넣는 세션(ClickPipes)의 설정**으로 해석한다. 같은 서비스에서 시험한 결과는 아래와 같다.

| 뷰의 SELECT | `"2026-01-01"`, `"2026-04-02T03:00:00Z"`가 저장된 타입 |
|---|---|
| `SELECT j`(String을 JSON 컬럼에) | `Date`, `DateTime` |
| `SELECT j … SETTINGS input_format_try_infer_dates = 0, …` | `Date`, `DateTime` |
| `SELECT CAST(JSONExtract(j, 'Map(String, String)'), 'JSON')` | `Date`, `DateTime` |
| `SELECT CAST(j, 'JSON') … SETTINGS input_format_try_infer_dates = 0, …` | **`String`, `String`** |

`sql/30-mvs.sql`은 마지막 형태를 쓴다. 이 뷰로 들어온 이후 갱신 1,000건은 `String`으로 저장됐다.

#### 비용

AWS는 Price List × 사용량으로 계산했다. Aurora `db.t4g.medium` 시간당 $0.113 × 약 1시간, KMS 요청 약 22,500건(10,000건당 $0.03), KMS 키 2개 몇 시간 — 약 $0.25. ClickHouse Cloud(8 GiB replica 1개 약 1시간, ClickPipes CDC 약 35분)는 Cloud 콘솔에서 청구된다. 여기서는 읽지 않았다.

### 하는 일

```
Aurora PostgreSQL 16 ── ClickPipes Postgres CDC ──> raw.users (암호문, SharedReplacingMergeTree(_peerdb_version))
  users.properties jsonb                                 │
  "name": "enc:v1:<base64(iv‖ct)>"                       ├─ users_a_mv: kms_unwrap(edk) → decrypt() → app.users_a
  users.edk = KMS로 암호화한 데이터 키                      └─ users_b_mv: dictGet(plain_key_dict, sha256(edk)) → decrypt() → app.users_b
```

- `gen.py`는 애플리케이션이 하는 일을 한다. 테넌트(또는 행)마다 `GenerateDataKey`를 부르고, 값마다 무작위 IV로 AES-256-CBC 암호화하고, 암호화된 데이터 키를 행에(`edk`) 둔다. 정답 평문과, 경로 B용 평문 키도 쓴다.
- `udf/kms_unwrap/main.py` — TabSeparated로 받아 16진수 키를 돌려준다. 프로세스마다 서로 다른 `edk` 하나에 KMS 호출 한 번이다. `udf-deploy.sh`는 `config.json`을 넣은 zip을 만들어 올리고(`POST /udfUploads/url`, 그 URL로 `PUT`), UDF를 만들거나 새 버전을 만들어 붙인다. 첫 UDF를 붙이면 서비스가 순차 재시작한다.
- `sql/10-functions.sql` — SQL UDF `dec_val`(값 하나)과 `dec_props`(최상위 jsonb 텍스트 → 암호화된 값을 푼 `Map(String, String)`). 어떤 정의에도 키가 없다.
- ClickPipes는 `jsonb`를 `String`으로 복사하고 `_peerdb_is_deleted`가 있는 `SharedReplacingMergeTree(…, _peerdb_version)`을 만든다. 원본 테이블은 `REPLICA IDENTITY FULL`이라 삭제에도 이전 행과 `edk`가 실린다. 결과 테이블은 `ReplacingMergeTree(_peerdb_version, _peerdb_is_deleted)`라서 `FINAL`이 삭제된 유저를 숨긴다.

### 실행

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # owner, ttl, 내 /32. SCP가 IAM 사용자를 막으면 create_udf_user = false
export CHC_KEY=… CHC_SECRET=… ORG_ID=… SERVICE_ID=… CH_HOST=… CH_USER=default CH_PASSWORD=…   # ap-northeast-2의 테스트 서비스
./deploy.sh          # 또는 2026-11-04처럼 단계별로
./cdc-changes.sh     # 키를 바꾼 갱신 10,000건, 삭제 1,000건, 행마다 키 10,000명
clickhouse client … --param_t=users_a --queries-file sql/42-verify-final.sql
./destroy.sh         # 파이프, UDF, 실습 데이터베이스, Terraform. 테스트 서비스는 직접 지운다
```

역할 자격 증명(`create_udf_user = false`)을 쓰면 `udf-deploy.sh` 한 시간 뒤 UDF가 멈춘다. 그 전에 다시 실행한다.
