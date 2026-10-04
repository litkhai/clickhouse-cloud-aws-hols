# STATUS.md

**As of 2026-10-04** — all eight lab READMEs are bilingual ([#4](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/4)). Also on 2026-10-04: [#1](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/1), [#2](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/2) and [#3](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/3) closed without a re-run: the Kafka re-run, the direct-attach decision and the provider upgrade are recorded as "Not checked" in each lab's banner instead. As of 2026-10-03: `docs/labs.json` added (notes-site export, 0 labs published). As of 2026-10-02: split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10) with history.

## CI

`checks` (on pull requests): `links`, `syntax`, `secrets` (gitleaks), `hygiene` — green.
GitHub secret scanning and push protection are on.

## Inventory

8 labs in the README tables, every lab README bilingual (English first, `## English` / `## 한국어`). The 16 extra notes beside the two Kafka labs (`labs/kafka/terraform-confluent-aws/*.md`, `labs/kafka/terraform-confluent-aws-nlb-ssl/*.md` other than `README.md`) are English only.

## Open work

Tracked as issues — [all open](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues) · [needs a re-run](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues?q=is%3Aopen+label%3Are-verify):

- [Fix stale and contradictory passages in the lab READMEs](https://github.com/litkhai/clickhouse-cloud-aws-hols/issues/19)
