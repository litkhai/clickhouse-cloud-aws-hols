#!/bin/bash
# Shared helpers, sourced by the numbered scripts. Not run on its own.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }

# config.env is written by deploy.sh (Terraform outputs). ch.env holds the ClickHouse Cloud
# connection: CH_HOST, CH_USER, CH_PASSWORD. CH_ENV_FILE points elsewhere if you keep it outside.
load_config() {
  [ -f "$LAB_DIR/config.env" ] || die "config.env not found: run ./deploy.sh first"
  # shellcheck disable=SC1091
  . "$LAB_DIR/config.env"
}

load_ch() {
  local f="${CH_ENV_FILE:-$LAB_DIR/ch.env}"
  [ -f "$f" ] || die "ClickHouse env file not found: $f (CH_HOST, CH_USER, CH_PASSWORD; see README)"
  # shellcheck disable=SC1090
  . "$f"
  : "${CH_HOST:?CH_HOST missing in $f}" "${CH_USER:?CH_USER missing in $f}" "${CH_PASSWORD:?CH_PASSWORD missing in $f}"
}

ch() {  # ch <args...> — clickhouse client against the Cloud service
  command -v clickhouse >/dev/null || die "clickhouse (client) is not installed"
  clickhouse client --secure --host "$CH_HOST" --user "$CH_USER" --password "$CH_PASSWORD" "$@"
}

# ssm_run <timeout seconds> <shell script> — run as root on the client, print stdout, fail on non-zero.
ssm_run() {
  local timeout="$1" script="$2" params cid status deadline
  params=$(python3 -c 'import json,sys; print(json.dumps({"commands":[sys.argv[1]],"executionTimeout":[sys.argv[2]]}))' "$script" "$timeout")
  cid=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --document-name AWS-RunShellScript --parameters "$params" \
        --query Command.CommandId --output text)
  deadline=$(( $(date +%s) + timeout + 60 ))
  while :; do
    sleep 3
    status=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
             --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in
      Success) break ;;
      Failed|Cancelled|TimedOut|Cancelling)
        aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$INSTANCE_ID" \
          --query '[StandardOutputContent,StandardErrorContent]' --output text >&2
        die "SSM command $cid: $status" ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || die "SSM command $cid still $status after ${timeout}s"
  done
  aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$INSTANCE_ID" \
    --query StandardOutputContent --output text
}
