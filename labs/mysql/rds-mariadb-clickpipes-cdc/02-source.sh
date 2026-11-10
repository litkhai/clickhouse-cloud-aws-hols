#!/usr/bin/env bash
# Loads 02-source.sql into the RDS instance as the master user and prints the settings and grants.
set -euo pipefail
cd "$(dirname "$0")"; . ./.env; . out/rds.env
sed "s/__CP_PW__/$CP_PW/" 02-source.sql |
  mysql -h "$RDS_HOST" -u admin -p"$MASTER_PW" --ssl-mode=REQUIRED -t 2>&1 |
  grep -v 'Using a password' | sed 's/IDENTIFIED BY PASSWORD .*/IDENTIFIED BY PASSWORD <redacted>/'
