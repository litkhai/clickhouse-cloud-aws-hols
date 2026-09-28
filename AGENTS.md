# AGENTS.md

Instructions for coding agents working in this repository.

This repository was split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols). Its
[AGENTS.md](https://github.com/litkhai/clickhouse-hols/blob/main/AGENTS.md) still applies here —
bilingual READMEs (English first, `## English` / `## 한국어`), no links to labs
that do not exist yet, and the **Verification claims** rule: only write
*"Verified on …"* when the scripts actually ran end to end against that version.

Differences from the core repository:

- No Pages site and no `site` CI job (decision D7). The root README tables are
  documentation only, not a site index.
- Enable the guard once per clone: `git config core.hooksPath .githooks`.

## Rules for this repository

- **Last-verified banner.** Every lab README starts with a bilingual banner giving the date the
  lab last ran end to end (`deploy.sh` → `destroy.sh`) and what changed since without a re-run.
  Update the date only after a real `apply` + `destroy`; a `terraform plan` or `validate` run is
  listed under "changed since", never as the verified date. Update the *Last run* column in the
  root README in the same commit.
- Provider upgrades (`hashicorp/aws ~> 5.0` today) happen only together with a re-run.
- Never commit Terraform state or saved plans. The `hygiene` job checks file *content*, because
  a `tfplan` is a zip with the full state inside and slips past name-based ignore rules.
- `allowed_cidr_blocks` is required and rejects `0.0.0.0/0`. Keep it that way.

## Where things came from

Paths were renamed by `git filter-repo`, so `git log --follow` works across the
split. The original locations:

| In clickhouse-hols | Here |
|---|---|
| `chc/kafka/` | `labs/kafka/` |
| `chc/lake/` | `labs/lake/` |
| `chc/s3/` | `labs/s3/` |

## Tracking work

Planned work, re-verification and follow-ups are **GitHub issues**; every change
lands through a **pull request** that references its issue (`Closes #N`).
`STATUS.md` is a snapshot of the current state and links to the open issues
instead of keeping its own to-do list. When you find something to do that you
are not doing now, open an issue rather than writing it into a README or
`STATUS.md`. Labels: `re-verify` (changed but not re-run), `enhancement`,
`docs`, `ops`, `security`.

한국어: 해야 할 일은 GitHub 이슈로, 변경은 이슈를 참조하는 PR로 관리합니다. `STATUS.md`는 열린 이슈를 링크합니다.
