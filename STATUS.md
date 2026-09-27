# STATUS.md

**As of 2026-09-27** — split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10) with history.

## CI

`checks`: `links`, `syntax`, `shellcheck` (advisory), `secrets` (gitleaks), `hygiene` — green.
GitHub secret scanning and push protection are on.

## Inventory

7 labs in the README tables; 7 single-language: `labs/kafka/terraform-confluent-aws`, `labs/kafka/terraform-confluent-aws-connect-sink`, `labs/kafka/terraform-confluent-aws-nlb-ssl`, `labs/lake/terraform-glue-s3-chc-integration`, `labs/lake/terraform-minio-on-aws`, `labs/s3/terraform-chc-secures3-aws`, `labs/s3/terraform-chc-secures3-aws-direct-attach`.

## Re-verification notes

Not re-run; update a README's verification line only after a real end-to-end run.

| What | Note |
|------|------|
| Kafka labs | SASL credentials made required (2026-07-28) and `allowed_cidr_blocks` required (2026-08-10); never applied. |
| `labs/s3/terraform-chc-secures3-aws-direct-attach` | Last run failed on ClickHouse Cloud (cross-account 403). |
| History | Rewritten 2026-09-27 to drop state dumps and scrub AWS IDs/IPs; `.gitleaksignore` regenerated then. |
