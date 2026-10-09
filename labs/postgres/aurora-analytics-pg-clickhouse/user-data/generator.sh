#!/bin/bash
# Generator / client EC2 (Amazon Linux 2023, arm64). Runs once as root through cloud-init;
# main.tf puts "export PG_MAJOR=<17|18>" in front of this file.
# Progress: /var/log/lab-user-data.log. Done: /var/log/lab-ready exists.
set -euxo pipefail
exec > >(tee -a /var/log/lab-user-data.log) 2>&1

: "${PG_MAJOR:?PG_MAJOR must be 17 or 18}"
DUCKDB_VERSION=v1.5.6
# duckdb_cli-linux-arm64.gz digest as published on the GitHub release (read 2026-10-09)
DUCKDB_SHA256=1af0541e649a3ae34eb20eec2ca564308bf0e8993e5d6dba6be77bfb289a2718

# Package names read from the AL2023 repository metadata (primary + filelists, aarch64) on 2026-10-09:
# postgresql17 / postgresql18 hold psql and pg_dump; postgresql17-contrib / postgresql18-contrib hold
# pgbench. The release notes list the same names:
# https://docs.aws.amazon.com/linux/al2023/release-notes/all-packages-AL2023.9.html
dnf install -y git python3 python3-pip jq tar gzip \
  "postgresql${PG_MAJOR}" "postgresql${PG_MAJOR}-contrib"

# AWS CLI v2 ships in the AL2023 AMI; install it only if a minimal image lacks it.
command -v aws >/dev/null || dnf install -y awscli-2

# uv (not in the AL2023 repository): official installer, system-wide, no profile edits
curl -LsSf https://astral.sh/uv/install.sh | UV_UNMANAGED_INSTALL=/usr/local/bin sh

# DuckDB CLI, pinned and checked
cd /tmp
curl -fsSL -o duckdb.gz \
  "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-linux-arm64.gz"
echo "${DUCKDB_SHA256}  duckdb.gz" | sha256sum -c -
gunzip -c duckdb.gz > /usr/local/bin/duckdb
chmod 755 /usr/local/bin/duckdb
rm -f duckdb.gz

# ClickHouse client: the official installer downloads one binary; `clickhouse client` is the client
curl -fsSL https://clickhouse.com/ | sh
install -m 755 ./clickhouse /usr/local/bin/clickhouse
rm -f ./clickhouse

{
  echo "ready $(date -u +%FT%TZ)"
  psql --version
  pgbench --version
  duckdb --version
  uv --version
  clickhouse client --version
  aws --version
  jq --version
} > /var/log/lab-ready 2>&1
