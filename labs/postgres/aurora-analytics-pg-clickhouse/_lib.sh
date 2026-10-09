#!/bin/bash
# Shared helpers, sourced by every numbered script:   source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
# Works with bash 3.2 (macOS) and 5.x (Amazon Linux 2023).
#
# Interface (the keys are those of config.env.example, written by deploy.sh):
#   load_config            reads $CONFIG_ENV (default: ./config.env) KEY=value line by line, no eval
#   require_keys K1 K2 ..  dies, naming every key that is missing or empty
#   aurora_psql / pgfront_psql / ch_client   run a client against Aurora / the PG front end / ClickHouse
#   set_log <target> <name>; log "text"      every command and its output goes to out/<target>/<name>.log
# Secrets: passwords reach a client through its environment or a mode-600 temp file, never argv, and
# are replaced by *** in the log.
#
# Overrides used by local/rehearse.sh only (not config keys, not needed on AWS):
#   LAB_OUT, LAB_WORK          output / work directories (default ./out, ./work)
#   LAB_PSQL_DOCKER=<name>     run psql inside that container, connecting to 127.0.0.1:5432
#   CH_SECURE=0, CH_PORT       plaintext ClickHouse client connection on CH_PORT
#   PGCH_HOST, PGCH_PORT       host / port pg_clickhouse uses to reach ClickHouse (default CH_HOST, driver default)

# The single query set: tpcds-scripts engines/duckdb/queries at this commit (PR litkhai/tpcds-scripts#11;
# re-pin to the merge commit here, nowhere else).
TPCDS_SCRIPTS_SHA=1e4870cc2d153ff4716182c9a4f115a65b2d60f9
TPCDS_SCRIPTS_URL=https://github.com/litkhai/tpcds-scripts

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${LAB_OUT:-$LAB_DIR/out}"
WORK_DIR="${LAB_WORK:-$LAB_DIR/work}"

TPCDS_TABLES="call_center catalog_page catalog_returns catalog_sales customer customer_address customer_demographics date_dim household_demographics income_band inventory item promotion reason ship_mode store store_returns store_sales time_dim warehouse web_page web_returns web_sales web_site"

# ORDER BY key of the 7 fact tables in the Parquet export (empty for the other 17 tables)
fact_order_key() {
  case "$1" in
    store_sales) echo ss_sold_date_sk ;;
    store_returns) echo sr_returned_date_sk ;;
    catalog_sales) echo cs_sold_date_sk ;;
    catalog_returns) echo cr_returned_date_sk ;;
    web_sales) echo ws_sold_date_sk ;;
    web_returns) echo wr_returned_date_sk ;;
    inventory) echo inv_date_sk ;;
    *) echo "" ;;
  esac
}

LOG_FILE=""

die() { echo "ERROR: $*" >&2; exit 1; }

now() { python3 -c 'import time; print("%.3f" % time.time())'; }
elapsed() { python3 -c 'import sys; print("%.1f" % (float(sys.argv[2]) - float(sys.argv[1])))' "$1" "$2"; }

# ---- logging ---------------------------------------------------------------------------------------
# Replace known secrets and `password '...'` options with ***
_redact() {
  local s="$1"
  [ -z "${PGFRONT_PASSWORD:-}" ] || s="${s//"$PGFRONT_PASSWORD"/***}"
  [ -z "${CH_PASSWORD:-}" ] || s="${s//"$CH_PASSWORD"/***}"
  [ -z "${_AURORA_PASSWORD:-}" ] || s="${s//"$_AURORA_PASSWORD"/***}"
  printf '%s' "$s" | sed -E "s/([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd] +)'[^']*'/\1'***'/g"
}

set_log() { # set_log <target> <name>  -> out/<target>/<name>.log
  mkdir -p "$OUT_DIR/$1"
  LOG_FILE="$OUT_DIR/$1/$2.log"
}

log() {
  local line
  line="[$(date -u +%H:%M:%S)] $*"
  echo "$line" >&2
  [ -z "$LOG_FILE" ] || echo "$line" >> "$LOG_FILE"
}

# _logged_run <description> <stdin text or ""> -- cmd args...
# Appends the command and its output to $LOG_FILE; stdout and stderr stay separate for the caller.
_logged_run() {
  local desc="$1" text="$2"
  shift 3
  local rc=0
  if [ -z "$LOG_FILE" ]; then
    if [ -n "$text" ]; then printf '%s\n' "$text" | "$@" || rc=$?; else "$@" || rc=$?; fi
    return $rc
  fi
  {
    echo "[$(date -u +%FT%TZ)] \$ $desc"
    if [ -n "$text" ]; then _redact "$text"; echo; fi
  } >> "$LOG_FILE"
  if [ -n "$text" ]; then
    printf '%s\n' "$text" | "$@" 2> >(tee -a "$LOG_FILE" >&2) | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[1]}
  else
    "$@" 2> >(tee -a "$LOG_FILE" >&2) | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}
  fi
  return "$rc"
}

# ---- config ----------------------------------------------------------------------------------------
load_config() {
  local f="${CONFIG_ENV:-$LAB_DIR/config.env}" line k v
  [ -f "$f" ] || die "config file not found: $f (deploy.sh writes config.env; fill the CH_* keys by hand)"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    k=${line%%=*}
    v=${line#*=}
    case "$k" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    export "$k=$v"
  done < "$f"
}

require_keys() {
  local k missing=""
  for k in "$@"; do
    eval "[ -n \"\${$k:-}\" ]" || missing="$missing $k"
  done
  [ -z "$missing" ] || die "missing or empty in ${CONFIG_ENV:-config.env}:$missing"
}

# Aurora target letter from the instance class (spec test design: A t4g.medium, B t4g.large,
# C serverless, D r8g.large, E r8gd; the Terraform allows db.r8gd.xlarge for E). TARGET overrides.
target_letter() {
  if [ -n "${TARGET:-}" ]; then echo "$TARGET"; return; fi
  case "${AURORA_CLASS:-}" in
    db.t4g.medium) echo A ;;
    db.t4g.large) echo B ;;
    db.serverless) echo C ;;
    db.r8g.large) echo D ;;
    db.r8gd.large|db.r8gd.xlarge) echo E ;;
    *) die "cannot map AURORA_CLASS='${AURORA_CLASS:-}' to a target letter; set TARGET=A..E" ;;
  esac
}

# ---- psql ------------------------------------------------------------------------------------------
_AURORA_PASSWORD=""
_aurora_password() {
  [ -z "$_AURORA_PASSWORD" ] || return 0
  require_keys AURORA_SECRET_ARN AWS_REGION
  local secret
  secret=$(aws secretsmanager get-secret-value --secret-id "$AURORA_SECRET_ARN" --region "$AWS_REGION" \
    --query SecretString --output text) || die "cannot read the Aurora secret"
  _AURORA_PASSWORD=$(printf '%s' "$secret" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])') \
    || die "the Aurora secret has no password field"
}

# _psql <label> <host> <port> <user> <db> <password> <sslmode> [psql args]
# SQL comes on stdin, or with -c. The password lives only in the environment of the psql process.
_psql() {
  local label=$1 host=$2 port=$3 user=$4 db=$5 pw=$6 ssl=$7
  shift 7
  local text="" has_c=0 a
  for a in "$@"; do [ "$a" != "-c" ] || has_c=1; done
  if [ "$has_c" = 0 ]; then text=$(cat); fi
  local desc="psql[$label] $host:$port/$db $*"
  if [ -n "${LAB_PSQL_DOCKER:-}" ]; then
    PGPASSWORD="$pw" PGSSLMODE="$ssl" PGCONNECT_TIMEOUT=30 \
      _logged_run "$(_redact "$desc")" "$text" -- \
      docker exec -i -e PGPASSWORD -e PGSSLMODE -e PGCONNECT_TIMEOUT "$LAB_PSQL_DOCKER" \
      psql -X -h 127.0.0.1 -p 5432 -U "$user" -d "$db" -v ON_ERROR_STOP=1 "$@"
  else
    PGPASSWORD="$pw" PGSSLMODE="$ssl" PGCONNECT_TIMEOUT=30 \
      _logged_run "$(_redact "$desc")" "$text" -- \
      psql -X -h "$host" -p "$port" -U "$user" -d "$db" -v ON_ERROR_STOP=1 "$@"
  fi
}

aurora_psql() {
  require_keys AURORA_HOST AURORA_PORT AURORA_USER AURORA_DB
  _aurora_password
  _psql aurora "$AURORA_HOST" "$AURORA_PORT" "$AURORA_USER" "$AURORA_DB" "$_AURORA_PASSWORD" require "$@"
}

# PGFRONT_DB_OVERRIDE picks another database on the front end (rehearsal: the plain-PostgreSQL check)
pgfront_psql() {
  require_keys PGFRONT_HOST PGFRONT_PORT PGFRONT_USER PGFRONT_PASSWORD PGFRONT_DB PGFRONT_SSLMODE
  _psql pgfront "$PGFRONT_HOST" "$PGFRONT_PORT" "$PGFRONT_USER" "${PGFRONT_DB_OVERRIDE:-$PGFRONT_DB}" \
    "$PGFRONT_PASSWORD" "$PGFRONT_SSLMODE" "$@"
}

# ---- clickhouse client -----------------------------------------------------------------------------
# `clickhouse client --secure`; user and password go through a temporary mode-600 config file.
# SQL on stdin, or with --query.
ch_client() {
  require_keys CH_HOST CH_USER CH_PASSWORD
  local secure="${CH_SECURE:-1}" port cfg rc=0 text="" has_q=0 a esc_pw esc_user
  if [ "$secure" = 1 ]; then port="${CH_PORT:-9440}"; else port="${CH_PORT:-9000}"; fi
  for a in "$@"; do case "$a" in --query|-q|--query=*) has_q=1 ;; esac; done
  [ "$has_q" = 1 ] || text=$(cat)
  cfg=$(umask 077; mktemp "${TMPDIR:-/tmp}/chclient.XXXXXX")
  chmod 600 "$cfg"
  esc_pw=$(printf '%s' "$CH_PASSWORD" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
  esc_user=$(printf '%s' "$CH_USER" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
  printf '<clickhouse><user>%s</user><password>%s</password></clickhouse>\n' "$esc_user" "$esc_pw" > "$cfg"
  local sec_args=()
  [ "$secure" != 1 ] || sec_args=(--secure)
  _logged_run "clickhouse client $CH_HOST:$port $*" "$text" -- \
    clickhouse client --config-file "$cfg" --host "$CH_HOST" --port "$port" ${sec_args[@]+"${sec_args[@]}"} "$@" || rc=$?
  rm -f "$cfg"
  return $rc
}

# sha256 of files, `sha256sum` format
sha256_files() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

# Count and total bytes of the *.parquet under a directory or s3:// prefix: "<files> <bytes>"
parquet_stats() {
  case "$1" in
    s3://*)
      aws s3 ls "$1" --recursive --summarize 2>/dev/null | python3 -c '
import sys
n = b = 0
for l in sys.stdin:
    p = l.split()
    if len(p) >= 4 and p[3].endswith(".parquet"):
        n += 1; b += int(p[2])
print(n, b)'
      ;;
    *)
      python3 -c '
import os, sys
n = b = 0
for r, _, fs in os.walk(sys.argv[1]):
    for f in fs:
        if f.endswith(".parquet"):
            n += 1; b += os.path.getsize(os.path.join(r, f))
print(n, b)' "$1"
      ;;
  esac
}
