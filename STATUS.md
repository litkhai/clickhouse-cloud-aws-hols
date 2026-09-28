# STATUS.md

**As of 2026-09-27** — split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10) with history.

## CI

`checks`: `links`, `syntax`, `shellcheck` (advisory), `secrets` (gitleaks), `hygiene` — green.
GitHub secret scanning and push protection are on.

## Inventory

7 labs in the README tables; 7 single-language: `labs/kafka/terraform-confluent-aws`, `labs/kafka/terraform-confluent-aws-connect-sink`, `labs/kafka/terraform-confluent-aws-nlb-ssl`, `labs/lake/terraform-glue-s3-chc-integration`, `labs/lake/terraform-minio-on-aws`, `labs/s3/terraform-chc-secures3-aws`, `labs/s3/terraform-chc-secures3-aws-direct-attach`.

## Open work

Tracked as issues — [all open](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues) · [needs a re-run](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues?q=is%3Aopen+label%3Are-verify):

- [Re-run the three Kafka labs (track K)](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/1)
- [Decide what to do with terraform-chc-secures3-aws-direct-attach](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/2)
- [Upgrade hashicorp/aws beyond ~> 5.0](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/3)
- [Translate the seven labs](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/4)
