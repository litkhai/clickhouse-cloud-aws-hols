# STATUS.md

**As of 2026-10-04** — [#1](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/1), [#2](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/2) and [#3](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/3) closed without a re-run: the Kafka re-run, the direct-attach decision and the provider upgrade are recorded as "Not checked" in each lab's banner instead. As of 2026-10-03: `docs/labs.json` added (notes-site export, 0 labs published). As of 2026-10-02: split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10) with history.

## CI

`checks` (on pull requests): `links`, `syntax`, `secrets` (gitleaks), `hygiene` — green.
GitHub secret scanning and push protection are on.

## Inventory

8 labs in the README tables; 1 bilingual: `labs/billing/usage-cost`; 7 single-language: `labs/kafka/terraform-confluent-aws`, `labs/kafka/terraform-confluent-aws-connect-sink`, `labs/kafka/terraform-confluent-aws-nlb-ssl`, `labs/lake/terraform-glue-s3-chc-integration`, `labs/lake/terraform-minio-on-aws`, `labs/s3/terraform-chc-secures3-aws`, `labs/s3/terraform-chc-secures3-aws-direct-attach`.

## Open work

Tracked as issues — [all open](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues) · [needs a re-run](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues?q=is%3Aopen+label%3Are-verify):

- [Translate the seven labs](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/4)
