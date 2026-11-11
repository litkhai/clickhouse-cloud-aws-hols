#!/usr/bin/env bash
# CDC phase: key rotation (version 2 for all three columns), 10,000 users re-encrypted with version 2 (and changed),
# 1,000 deletes, 10,000 new users with version 2. Then the decrypted table against Aurora.
set -euo pipefail
cd "$(dirname "$0")"; . ./env.sh
step "data keys, version 2 → key ring (version 1 stays)"
keys --version 2
step "changes"
load upsert --from 0 --to 9999 --ver 2 --rev 1
pg -c "DELETE FROM users WHERE user_id BETWEEN 'u000990000' AND 'u000990999'"
pg -c "DELETE FROM lab_expected WHERE user_id BETWEEN 'u000990000' AND 'u000990999'"
load upsert --from 1000000 --to 1009999 --ver 2
date -u +"%T changes committed"
reload_expected
wait_caught_up
q --queries-file sql/40-verify.sql
q -q "SELECT splitByChar(':', encrypted_email)[1] AS email_key_version, count() FROM app.users FINAL GROUP BY 1 ORDER BY 1"
