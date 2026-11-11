#!/usr/bin/env bash
# Ciphertext lookups: a rotated user (u000000005, version 2) and an untouched one (u000500000, version 1),
# a kept-encrypted property in a condition, and whether the bloom filter skips granules.
set -euo pipefail
cd "$(dirname "$0")"; . ./env.sh
for u in 5 500000; do
  step "user $u"
  out=$(uv run -q --with boto3 --with cryptography lookup.py --user $u --name 김민준)
  emails=$(sed -n 1p <<<"$out"); names=$(sed -n 2p <<<"$out")
  q --param_emails="$emails" --param_names="$names" --queries-file sql/50-lookup.sql
done
q --param_emails="$emails" --queries-file sql/55-lookup-index.sql
