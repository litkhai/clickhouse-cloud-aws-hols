#!/usr/bin/env bash
# Runs the whole comparison on one ClickHouse Cloud service:
#   schema → A (ClickPipe from Terraform, masked by an MV) → C (INSERT … SELECT FROM s3) → B (load raw, then UPDATE) → checks.
# Needs: clickhouse client, terraform, curl, python3, and
#   CH_HOST CH_USER CH_PASSWORD                       — the service (native protocol, port 9440)
#   TF_VAR_organization_id TF_VAR_service_id          — Cloud API ids
#   TF_VAR_token_key TF_VAR_token_secret              — Cloud API key (Admin, or Developer with ClickPipes rights)
set -euo pipefail
cd "$(dirname "$0")"
: "${CH_HOST:?}" "${CH_USER:?}" "${CH_PASSWORD:?}"
: "${TF_VAR_organization_id:?}" "${TF_VAR_service_id:?}" "${TF_VAR_token_key:?}" "${TF_VAR_token_secret:?}"

q() { clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" --password "$CH_PASSWORD" "$@"; }
step() { printf '\n== %s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
api() { curl -fsS -u "$TF_VAR_token_key:$TF_VAR_token_secret" "https://api.clickhouse.cloud/v1/organizations/$TF_VAR_organization_id/services/$TF_VAR_service_id/$1"; }

step "schema"
q --queries-file sql/00-schema.sql

step "A: terraform apply (ClickPipe → users_landing (Null) → users_mask_mv → users_a)"
start=$SECONDS
terraform -chdir=terraform init -input=false >/dev/null
terraform -chdir=terraform apply -auto-approve -input=false
pipe=$(terraform -chdir=terraform output -raw pipe_id)
while :; do
  state=$(api "clickpipes/$pipe" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["state"])')
  case "$state" in Completed) break ;; Failed|Stopped|Paused) echo "pipe $state"; exit 1 ;; esac
  sleep 15
done
echo "A: apply → Completed in $((SECONDS - start)) s"
q -q "SELECT count() AS pipe_errors FROM mask_lab.users_landing_clickpipes_error"
q --param_t=users_a --queries-file sql/90-verify.sql

step "C: INSERT … SELECT FROM s3 with the masking expressions"
q --time --queries-file sql/20-c-insert-select.sql
q --param_t=users_c --queries-file sql/90-verify.sql

step "B: load raw (users_b, copy to users_b2)"
q --time --queries-file sql/30-b-load-raw.sql
step "B: lightweight UPDATE (users_b)"
q --time --queries-file sql/31-b-lightweight-update.sql
q --param_t=users_b --queries-file sql/90-verify.sql
q --queries-file sql/33-b-residue.sql
step "B: APPLY PATCHES (users_b)"
q --time --queries-file sql/34-b-apply-patches.sql
step "B: ALTER TABLE … UPDATE (users_b2)"
q --time --queries-file sql/32-b-alter-update.sql
q --param_t=users_b2 --queries-file sql/90-verify.sql
q --queries-file sql/33-b-residue.sql

step "same rows in all four tables?"
for t in users_a users_b users_b2 users_c; do
  printf '%s\t' "$t"
  q -q "SELECT count(), sum(cityHash64(Id, Reputation, CreationDate, DisplayName, LastAccessDate, AboutMe,
               Views, UpVotes, DownVotes, WebsiteUrl, Location, AccountId, is_masked))
        FROM mask_lab.$t SETTINGS select_sequential_consistency = 1"
done
