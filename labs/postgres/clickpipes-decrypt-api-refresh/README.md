# ClickPipes Postgres CDC decrypted through an application-owned batch API

> **Last run: 2026-11-11.** Everything ran once, one script at a time, from 11:50 to 12:47 UTC, then `destroy.sh` ran. Region AWS `ap-northeast-2`. Setup: Aurora PostgreSQL 16.13 (`db.t4g.medium`, `rds.logical_replication = 1`, pgcrypto); a new ClickHouse Cloud service (1 replica, 8 GiB, ClickHouse 26.6.1.2455, `max_threads` 2); ClickPipes Postgres CDC (`syncIntervalSeconds` 10); a Python 3.11 executable UDF (`type: executable`, standard library only, `sandboxType: netenable`); a refreshable MV every 10 s; the decrypt API on API Gateway REST (regional, resource policy) + Lambda Node.js 22 arm64 1024 MB. Terraform 1.16.4, `hashicorp/aws` 5.100.0. Not run: PrivateLink (Aurora was public, open only to the ClickPipes IPs), sizing at production volume, a real application's API.
>
> **마지막 실행: 2026-11-11.** 11:50부터 12:47 UTC까지 스크립트를 하나씩 한 번 실행했고, 이어서 `destroy.sh`를 실행했다. 리전은 AWS `ap-northeast-2`. 구성: Aurora PostgreSQL 16.13(`db.t4g.medium`, `rds.logical_replication = 1`, pgcrypto), 새 ClickHouse Cloud 서비스(replica 1개, 8 GiB, ClickHouse 26.6.1.2455, `max_threads` 2), ClickPipes Postgres CDC(`syncIntervalSeconds` 10), Python 3.11 실행형 UDF(`type: executable`, 표준 라이브러리만, `sandboxType: netenable`), 10초마다 도는 refreshable MV, API Gateway REST(리전, 리소스 정책) + Lambda Node.js 22 arm64 1024 MB로 만든 복호화 API. Terraform 1.16.4, `hashicorp/aws` 5.100.0. 실행하지 않은 것: PrivateLink(Aurora는 공개, ClickPipes IP에만 열어 둠), 운영 규모 사이징, 실제 애플리케이션의 API.

[English](#english) | [한국어](#한국어)

## English

This lab is the third design for the same problem. The first two are [`../kms-decrypt-cdc`](../kms-decrypt-cdc/) and [`../clickpipes-kms-decrypt-refresh`](../clickpipes-kms-decrypt-refresh/). In both of them, ClickHouse Cloud's executable UDF called KMS with AWS credentials kept in its zip. Here **the UDF holds no data key and no AWS credentials**. It sends rows to a **decrypt API owned by the application**. Only ClickHouse Cloud's egress IPs may reach that API, and each call needs a bearer token. The KMS permission stays on the API's own IAM role, inside AWS.

The data follows a common application layout:

- One KMS master key, and one data key per column (`email`, `phone`, `properties`), each with a key version.
- Each value is stored as `<key version>:<base64>`: AES-256-CBC with PKCS#7 padding and a **fixed IV per key version**. The IV is not stored in the value, so the same plaintext always gives the same ciphertext.
- In Postgres, **every** property value inside the `jsonb` is encrypted. Property names stay in plaintext.
- In ClickHouse, the properties a tenant chooses stay encrypted. The API decides which ones, so ClickHouse keeps no list of them.
- Email and phone stay encrypted in ClickHouse too. The application finds a user by ciphertext: it encrypts the input with the same key and IV.

```
Aurora PostgreSQL 16 ──ClickPipes CDC──> raw.users (ciphertext only)
                                            │ every 10 s, watermark + anti-join (unchanged from clickpipes-kms-decrypt-refresh)
                                            └─ users_rmv: api_decrypt_props(tenant, props) ──HTTPS, batches of 500──> API Gateway
                                                   → app.users                                  (resource policy: Cloud egress IPs only)
                                                                                                 → Lambda: bearer token; KMS Decrypt once per
                                                                                                   column:version per container; AES; keep list
```

### What it shows

- **The KMS credentials never leave AWS.** The UDF zip holds the API URL, a token and two numbers. The Lambda role is the only principal with `kms:Decrypt`. Each Lambda container unwrapped at most 2 data keys over the whole run (`props:1`, `props:2`).
- **The API accepts nobody but ClickHouse Cloud, and nobody without the token.** From the operator's laptop, with a valid token: HTTP 403 from the resource policy. From the ClickHouse service, without the token: HTTP 401. A direct invoke with a wrong token: 401.
- **Snapshot through the API.** 1,000,000 users (40 properties each, 2,141 bytes of encrypted jsonb on average) were decrypted in **one refresh of 173.3 s, about 5,770 rows/s**. All 1,000,000 rows match the generator, and every one of the 40 property paths is `String`.
- **CDC through the API.** The change was 10,000 users re-encrypted under the new key version and changed, 1,000 deletes and 10,000 new users, committed at 12:42:47. ClickPipes landed it at 12:42:52. The refresh wrote 21,000 rows in 7.5 s, and the table was caught up by 12:43:12. All 1,009,000 rows are correct.
- **Key rotation needs no ClickHouse change.** Adding version 2 to the key ring was enough: warm Lambdas re-read the ring when they met an unknown version. After the changes the table held 989,000 emails under version 1 and 20,000 under version 2.
- **An API outage never stops CDC, and nothing is lost.** With the Lambda throttled, 100 new users still landed in `raw.users`. The refresh failed with `decrypt API HTTP 500` (3 attempts per batch) and kept retrying. At worst the table was 77.8 s behind. After the API came back, it caught up in 11 s, and all 1,009,100 rows are correct.
- **Ciphertext lookups work, with every key version.** A rotated user is found by `encrypted_email IN (v1, v2)`; with the version-1 ciphertext alone there are 0 rows. On a kept-encrypted property, `=` and `<>` return 168,183 and 840,917 users, exactly what the generator expects. The bloom filter on `encrypted_email` read 3 of 127 granules: 24,576 rows in 5 ms, or 95,920 rows in 13 ms with `FINAL`.

### Results (2026-11-11, UTC)

| Step | Measured |
|---|---|
| `terraform apply` | 30 resources, 11:50:42 → 11:57:42 |
| Data in Aurora, generated by pgcrypto | 1,000,000 users, 40 properties each, 2,830 MB; about 1,600 rows/s (10,000 in 6.8 s, 740,000 in 455.7 s). Format check: Python `cryptography` decrypted the pgcrypto output with the same key and fixed IV (3/3) |
| UDF, first version | `type: executable` accepted. Build + attach 11:59:02 → 12:07:44 (rolling restart; the trailing `SYSTEM RELOAD` hit the pod being replaced, as in the earlier labs) |
| UDF, first refreshes | Every refresh failed with `can't start new thread`. Each block runs as a process, and 16 HTTP threads per process went over the sandbox's thread limit. Nothing reached `app.users`, and the watermark stayed. Fixed with 4 threads per process, falling back to sequential calls; version 2 published 12:35:13 → 12:38:23 |
| ClickPipe create → `Running` | 329 s (12:18:53 → 12:24:37), 1,000,000 rows in `raw.users` |
| Snapshot decrypted | One refresh, 173.3 s, 1,000,000 rows (≈5,770 rows/s), finished 12:41:03; 1,000,000 / 1,000,000 correct; 40 paths, all `String` |
| API during the snapshot | ≈750 calls/min of 500 rows, Lambda duration 237–244 ms on average (handler 220 ms), at most **8 concurrent** (2 query threads × 4 UDF threads), no throttles or errors |
| CDC: key version 2, 10,000 re-encrypted and changed users, 1,000 deletes, 10,000 new users | Committed 12:42:47 → landed in raw 12:42:52 → one refresh of 21,000 rows in 7.5 s → caught up 12:43:12; 1,009,000 / 1,009,000 correct; email key versions: v1 989,000, v2 20,000 |
| API outage (reserved concurrency 0, 12:43:38) + 100 new users | CDC landed all 100; `app.users` 0 of them; refresh `Code: 754 … decrypt API HTTP 500`, retried about every 3 s; 55 throttled invocations; `behind_raw_s` 77.8 |
| API back (12:45:09) | Caught up 12:45:20; 1,009,100 / 1,009,100 correct |
| Access | Laptop + valid token: 403 (resource policy). ClickHouse service without token: 401. Wrong token: 401 |
| Lookups | v2 user: `IN (v1, v2)` → 1 row, v1 only → 0. v1 user → 1 row. Kept-encrypted `name`: `=` 168,183 / `<>` 840,917 (generator: 168,183 / 840,917). Bloom filter: 3/127 granules; 24,576 rows read in 5 ms, or 95,920 rows in 13 ms with `FINAL` |
| API calls in total | 5,711 calls, 2,763,600 rows, 106,398,600 values decrypted, 4,145,400 kept encrypted. About 1.03 million rows were needed; the rest were sent again by failed refreshes (see below) |
| AWS cost (Price List × usage, estimate) | Under $1: Aurora `db.t4g.medium` $0.113/h × ≈1 h; Aurora I/O $0.24 per million requests for about 2.8 GB written; Lambda arm64 ≈1,400 GB-s × $0.0000133; API Gateway 5,711 requests × $3.50 per million; KMS key for one day. Not read from billing |

### What it takes from the API

- **Public HTTPS.** The UDF's outbound calls leave the service through its regional egress IPs. The ClickHouse docs list those IPs per region and cloud. They describe no PrivateLink for traffic leaving a service, so PrivateLink covers ClickPipes → Postgres and application → ClickHouse, not the UDF → API call.
- **IP allowlist and a token.** The egress IPs come from a regional list, so the IPs alone do not single out one service. The token does.
- **Batches.** One call here carried 500 rows (about 1 MB). Throughput scales with the number of calls in flight, which ClickHouse caps: query threads × UDF threads per process. The sandbox's thread limit sets the second number.
- **Retries cost calls.** A refresh that fails re-sends the same rows, and part of a failed refresh may already have been decrypted. During the 14 minutes of thread errors, the API still answered about 270 calls a minute for rows that were then thrown away. During an outage, the API therefore sees a burst of retried calls when it comes back. Alert on `system.view_refreshes` and fix the cause; the backlog clears without help.
- **The initial load runs at the API's speed.** Here that was ≈5,770 rows/s with 8 calls in flight. At that rate a 60-million-row table takes about 3 hours. More calls in flight or bigger batches shorten it, and so does a one-time bulk load outside the pipe.

### What is still true

- An executable UDF has no grant of its own. A user who can read `raw.users` can call `api_decrypt_props` and get plaintext back through the API. Keep `raw.users` restricted to the refresh, and watch `query_log.used_executable_user_defined_functions` (see [`../clickpipes-kms-decrypt-refresh`](../clickpipes-kms-decrypt-refresh/)).
- The token sits in the UDF zip, as the AWS credentials did in the earlier designs. It works only from the Cloud egress IPs, it unwraps no key, and the application can rotate or revoke it.
- With a fixed IV, two equal values always have equal ciphertexts. Lookups depend on that, and anyone who can see the ciphertexts sees which values are equal.

### Run it

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # owner, ttl, your /32, the Cloud egress IPs
export CHC_KEY=… CHC_SECRET=… ORG_ID=… SERVICE_ID=… CH_HOST=… CH_USER=default CH_PASSWORD=…   # a test service in ap-northeast-2
./deploy.sh          # infrastructure, keys, 1,000,000 users, UDF, ClickPipe, refreshable MV, checks
./cdc-changes.sh     # key version 2, re-encrypted updates, deletes, new users
./outage.sh          # the API down while users arrive, then back
./lookups.sh         # ciphertext lookups and the bloom filter
./metrics.sh 120     # Lambda invocations, duration, concurrency, throttles (CloudWatch)
./destroy.sh         # pipe, UDF, databases, Terraform, out/; delete the test service yourself
```

`deploy.sh` holds the steps in the order they ran. The 2026-11-11 run used the scripts one by one, and the UDF ran with the four-thread setting from its second version on.

## 한국어

같은 문제의 세 번째 설계다. 앞의 두 설계는 [`../kms-decrypt-cdc`](../kms-decrypt-cdc/)와 [`../clickpipes-kms-decrypt-refresh`](../clickpipes-kms-decrypt-refresh/)다. 둘 다 ClickHouse Cloud의 실행형 UDF가 zip에 든 AWS 자격 증명으로 KMS를 불렀다. 여기서는 **UDF가 데이터 키도 AWS 자격 증명도 갖지 않는다.** 행을 **애플리케이션이 가진 복호화 API**로 보낸다. 그 API는 ClickHouse Cloud egress IP에서만 닿고, 호출마다 bearer 토큰이 필요하다. KMS 권한은 AWS 안, API 자신의 IAM 역할에 그대로 있다.

데이터는 흔한 애플리케이션 구성을 따른다.

- KMS 마스터 키 하나, 컬럼(`email`, `phone`, `properties`)마다 데이터 키 하나. 키마다 버전이 있다.
- 값은 `<키 버전>:<base64>`로 저장한다. AES-256-CBC, PKCS#7 패딩, **키 버전마다 고정된 IV**다. IV는 값에 넣지 않으므로, 같은 평문은 늘 같은 암호문이 된다.
- Postgres에서는 `jsonb` 안의 속성 값이 **모두** 암호화돼 있다. 속성 이름은 평문이다.
- ClickHouse에서는 테넌트가 고른 속성이 암호문으로 남는다. 어느 속성인지는 API가 정하므로, ClickHouse에는 그 목록이 없다.
- 이메일과 전화번호도 ClickHouse에 암호문으로 남는다. 애플리케이션은 입력값을 같은 키와 IV로 암호화해 암호문으로 찾는다.

```
Aurora PostgreSQL 16 ──ClickPipes CDC──> raw.users (암호문만)
                                            │ 10초마다, 워터마크 + anti-join (clickpipes-kms-decrypt-refresh와 같음)
                                            └─ users_rmv: api_decrypt_props(tenant, props) ──HTTPS, 500행 배치──> API Gateway
                                                   → app.users                               (리소스 정책: Cloud egress IP만)
                                                                                              → Lambda: bearer 토큰, 컨테이너마다 column:version당
                                                                                                KMS Decrypt 한 번, AES, 유지 목록
```

### 보여 주는 것

- **KMS 자격 증명이 AWS 밖으로 나오지 않는다.** UDF zip에는 API URL, 토큰, 숫자 두 개만 있다. `kms:Decrypt`를 가진 주체는 Lambda 역할뿐이다. Lambda 컨테이너 하나가 실행 내내 푼 데이터 키는 많아야 2개(`props:1`, `props:2`)였다.
- **API는 ClickHouse Cloud만 받고, 토큰이 없으면 거절한다.** 운영자 노트북에서 유효한 토큰으로 부르면 리소스 정책이 HTTP 403을 돌려준다. ClickHouse 서비스에서 토큰 없이 부르면 HTTP 401이다. 틀린 토큰으로 직접 호출해도 401이다.
- **API를 거친 스냅샷.** 유저 1,000,000명(속성 40개, 암호화된 jsonb 평균 2,141바이트)이 **refresh 한 번 173.3초, 초당 약 5,770행**으로 복호화됐다. 1,000,000행 모두 생성기와 같고, 속성 경로 40개가 모두 `String`이다.
- **API를 거친 CDC.** 변경은 새 키 버전으로 다시 암호화하고 값도 바꾼 유저 10,000명, 삭제 1,000건, 새 유저 10,000명이고, 12:42:47에 커밋했다. ClickPipes가 12:42:52에 적재했고, refresh가 21,000행을 7.5초에 썼으며, 12:43:12에 따라잡았다. 1,009,000행 모두 맞다.
- **키 교체에 ClickHouse 쪽 변경이 없다.** key ring에 버전 2를 넣는 것으로 충분했다. 떠 있던 Lambda는 모르는 버전을 만나자 ring을 다시 읽었다. 변경 뒤 이메일은 버전 1이 989,000개, 버전 2가 20,000개였다.
- **API 장애가 CDC를 멈추지 못하고, 빠진 행도 없다.** Lambda를 막아 둔 동안에도 새 유저 100명이 `raw.users`에 들어왔다. refresh는 `decrypt API HTTP 500`(배치마다 3번 시도)으로 실패하며 계속 재시도했다. 가장 뒤처졌을 때가 77.8초다. API를 되살리자 11초 만에 따라잡았고, 1,009,100행 모두 맞다.
- **암호문 일치 조회가 키 버전마다 된다.** 키를 바꾼 유저는 `encrypted_email IN (v1, v2)`로 찾고, v1 암호문만으로는 0행이다. 암호문으로 남긴 속성에 `=`와 `<>`를 걸면 168,183명과 840,917명으로, 생성기 기대값과 정확히 같다. `encrypted_email`의 bloom filter는 granule 127개 중 3개만 읽었다. 24,576행을 5 ms에 읽었고, `FINAL`이면 95,920행을 13 ms에 읽었다.

### 결과 (2026-11-11, UTC)

| 단계 | 측정 |
|---|---|
| `terraform apply` | 리소스 30개, 11:50:42 → 11:57:42 |
| Aurora 데이터, pgcrypto로 생성 | 유저 1,000,000명, 속성 40개씩, 2,830 MB. 초당 약 1,600행(1만 행 6.8초, 74만 행 455.7초). 형식 확인: pgcrypto 결과를 Python `cryptography`가 같은 키와 고정 IV로 풀었다(3/3) |
| UDF 첫 버전 | `type: executable`이 받아들여졌다. 빌드 + 붙이기 11:59:02 → 12:07:44(순차 재시작. 앞 실습처럼 마지막 `SYSTEM RELOAD`는 교체되는 pod에서 실패) |
| UDF 첫 refresh들 | 모든 refresh가 `can't start new thread`로 실패했다. 블록마다 프로세스가 하나씩 뜨고, 프로세스마다 HTTP 스레드 16개를 띄우자 샌드박스의 스레드 한도를 넘었다. `app.users`에는 아무것도 들어가지 않았고 워터마크는 그대로였다. 프로세스당 스레드 4개, 안 되면 순차 호출로 고쳤다. 버전 2 배포 12:35:13 → 12:38:23 |
| ClickPipe 생성 → `Running` | 329초(12:18:53 → 12:24:37), `raw.users`에 1,000,000행 |
| 스냅샷 복호화 | refresh 한 번, 173.3초, 1,000,000행(초당 약 5,770행), 12:41:03에 끝남. 1,000,000 / 1,000,000 맞음. 경로 40개 모두 `String` |
| 스냅샷 중 API | 500행짜리 호출이 분당 약 750번, Lambda 평균 실행 시간 237–244 ms(핸들러 220 ms), 동시 실행 최대 **8**(쿼리 스레드 2 × UDF 스레드 4), 스로틀·오류 없음 |
| CDC: 키 버전 2, 다시 암호화하고 바꾼 유저 10,000명, 삭제 1,000건, 새 유저 10,000명 | 커밋 12:42:47 → raw 적재 12:42:52 → refresh 한 번이 21,000행을 7.5초에 → 12:43:12 따라잡음. 1,009,000 / 1,009,000 맞음. 이메일 키 버전 v1 989,000 · v2 20,000 |
| API 장애(reserved concurrency 0, 12:43:38) + 새 유저 100명 | CDC는 100명 모두 적재. `app.users`에는 0명. refresh `Code: 754 … decrypt API HTTP 500`, 약 3초마다 재시도. 스로틀된 호출 55번. `behind_raw_s` 77.8 |
| API 복구(12:45:09) | 12:45:20 따라잡음. 1,009,100 / 1,009,100 맞음 |
| 접근 | 노트북 + 유효한 토큰: 403(리소스 정책). ClickHouse 서비스에서 토큰 없이: 401. 틀린 토큰: 401 |
| 조회 | v2 유저: `IN (v1, v2)` → 1행, v1만 → 0행. v1 유저 → 1행. 암호문으로 남긴 `name`: `=` 168,183 / `<>` 840,917(생성기 168,183 / 840,917). bloom filter: granule 3/127. 24,576행을 5 ms에 읽음, `FINAL`이면 95,920행을 13 ms |
| API 호출 합계 | 5,711번, 2,763,600행, 복호화한 값 106,398,600개, 암호문으로 남긴 값 4,145,400개. 필요했던 행은 약 103만 개이고, 나머지는 실패한 refresh가 다시 보낸 것이다(아래) |
| AWS 비용(Price List × 사용량, 추정) | $1 미만: Aurora `db.t4g.medium` 시간당 $0.113 × 약 1시간, 약 2.8 GB를 쓰는 데 드는 Aurora I/O(100만 요청당 $0.24), Lambda arm64 약 1,400 GB-s × $0.0000133, API Gateway 요청 5,711번 × 100만 건당 $3.50, KMS 키 하루치. 청구서에서 읽지 않았다 |

### API에 필요한 것

- **공개 HTTPS.** UDF의 외부 호출은 서비스의 리전 egress IP로 나간다. ClickHouse 문서는 이 IP를 리전·클라우드별 목록으로 둔다. 서비스에서 나가는 트래픽용 PrivateLink는 문서에 없다. 그래서 PrivateLink는 ClickPipes → Postgres와 애플리케이션 → ClickHouse에 쓰고, UDF → API 호출에는 쓰지 못한다.
- **IP 허용 목록과 토큰.** egress IP는 리전 단위 목록이라, IP만으로는 서비스 하나를 가려내지 못한다. 그 일은 토큰이 한다.
- **배치.** 여기서는 호출 하나에 500행(약 1 MB)을 실었다. 처리량은 동시에 날아가는 호출 수에 비례하고, 그 수는 ClickHouse 쪽에서 정해진다: 쿼리 스레드 × 프로세스당 UDF 스레드. 두 번째 수의 상한은 샌드박스의 스레드 한도다.
- **재시도에도 호출이 든다.** 실패한 refresh는 같은 행을 다시 보낸다. 실패한 refresh의 일부는 이미 복호화됐을 수도 있다. 스레드 오류가 난 14분 동안에도 API는 분당 약 270번, 결국 버려질 행을 처리했다. 그래서 장애 뒤 API가 돌아오면 재시도 호출이 몰린다. `system.view_refreshes`에 알림을 걸고 원인을 고치면, 밀린 것은 알아서 따라잡는다.
- **초기 적재는 API 속도로 돈다.** 여기서는 동시 호출 8개로 초당 약 5,770행이었다. 이 속도면 6천만 행 테이블은 약 3시간이다. 동시 호출을 늘리거나 배치를 키우면 줄어들고, 파이프 밖에서 한 번 대량 적재하는 방법도 있다.

### 여전히 남는 것

- 실행형 UDF에는 자체 권한이 없다. `raw.users`를 읽을 수 있는 사용자는 `api_decrypt_props`를 불러 API를 거쳐 평문을 받을 수 있다. `raw.users`는 refresh만 읽게 하고, `query_log.used_executable_user_defined_functions`를 본다([`../clickpipes-kms-decrypt-refresh`](../clickpipes-kms-decrypt-refresh/) 참고).
- 토큰은 앞 설계의 AWS 자격 증명처럼 UDF zip 안에 있다. 다만 Cloud egress IP에서만 통하고, 키를 풀지 못하며, 애플리케이션이 바꾸거나 끊을 수 있다.
- 고정 IV에서는 같은 두 값의 암호문이 늘 같다. 일치 조회가 이 성질에 기대고, 암호문을 볼 수 있는 사람은 어느 값끼리 같은지 알 수 있다.

### 실행

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # owner, ttl, 내 /32, Cloud egress IP
export CHC_KEY=… CHC_SECRET=… ORG_ID=… SERVICE_ID=… CH_HOST=… CH_USER=default CH_PASSWORD=…   # ap-northeast-2의 테스트 서비스
./deploy.sh          # 인프라, 키, 유저 1,000,000명, UDF, ClickPipe, refreshable MV, 확인
./cdc-changes.sh     # 키 버전 2, 다시 암호화한 갱신, 삭제, 새 유저
./outage.sh          # 유저가 들어오는 동안 API 중단, 이어서 복구
./lookups.sh         # 암호문 일치 조회와 bloom filter
./metrics.sh 120     # Lambda 호출 수, 실행 시간, 동시 실행, 스로틀(CloudWatch)
./destroy.sh         # 파이프, UDF, 데이터베이스, Terraform, out/. 테스트 서비스는 직접 지운다
```

`deploy.sh`에는 실행한 순서대로 단계가 들어 있다. 2026-11-11 실행은 스크립트를 하나씩 돌렸고, UDF는 두 번째 버전부터 스레드 4개 설정으로 돌았다.
