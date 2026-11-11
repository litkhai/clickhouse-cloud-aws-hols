#!/usr/bin/env bash
# The decrypt API goes down (Lambda reserved concurrency 0 = every call throttled) while 100 users arrive.
# CDC must keep going; the refresh fails and retries; after the API is back, nothing is missing.
set -euo pipefail
cd "$(dirname "$0")"; . ./env.sh
step "API down: reserved concurrency 0"
aws lambda put-function-concurrency --function-name "$LAMBDA_NAME" --reserved-concurrent-executions 0 >/dev/null
sleep 20
load upsert --from 2000000 --to 2000099 --ver 2
date -u +"%T 100 users committed"
reload_expected
sleep 60
q -q "SELECT 'raw' AS t, count() FROM raw.users WHERE user_id >= 'u002000000' UNION ALL SELECT 'app', count() FROM app.users WHERE user_id >= 'u002000000'"
q --queries-file sql/60-monitor.sql
step "API back"
aws lambda delete-function-concurrency --function-name "$LAMBDA_NAME"
wait_caught_up
q --queries-file sql/40-verify.sql
