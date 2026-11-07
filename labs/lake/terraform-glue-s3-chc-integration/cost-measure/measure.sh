#!/usr/bin/env bash
# What one ClickHouse DataLakeCatalog (catalog_type = 'glue') costs on the AWS side (#71).
# Needs aws, jq, terraform, clickhouse (client), python3; AWS credentials in the environment;
# CH_HOST / CH_USER / CH_PASSWORD for a ClickHouse Cloud service (v26.2+, aws_role_arn) in the same
# region; `terraform apply` done in this folder.
#
#   ./measure.sh tables [n]   Athena CTAS: n Iceberg tables (t01 200,000 rows, the rest 100), registered in Glue
#   ./measure.sh ch           the ClickHouse queries, each marked (log_comment glue71-*) and timed -> out/marks.tsv
#   ./measure.sh s3           S3 requests per marked query from system.query_log ProfileEvents -> out/s3.tsv
#   ./measure.sh trail        Glue calls in CloudTrail (management events) per mark -> out/trail.json
#                             (CloudTrail takes up to ~15 min to show events; run it after that)
#
# Nothing here creates or deletes AWS resources except the Athena tables inside the lab's own database.
set -euo pipefail
cd "$(dirname "$0")"
export AWS_PAGER=""
mkdir -p out
tf() { terraform output -raw "$1"; }
REGION=${AWS_REGION:-ap-northeast-2}
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

athena() {   # athena <sql> -> waits, fails on error
    local id state
    id=$(aws athena start-query-execution --work-group "$(tf workgroup)" \
        --query-execution-context "Database=$(tf glue_database)" --query-string "$1" \
        --query QueryExecutionId --output text)
    for _ in $(seq 1 120); do
        state=$(aws athena get-query-execution --query-execution-id "$id" --query QueryExecution.Status.State --output text)
        case $state in SUCCEEDED) return 0 ;; FAILED|CANCELLED)
            aws athena get-query-execution --query-execution-id "$id" --query QueryExecution.Status.StateChangeReason --output text >&2; return 1 ;; esac
        sleep 2
    done
    return 1
}

ch() {   # ch <log_comment> <sql>
    clickhouse client --secure --host "$CH_HOST" --user "$CH_USER" --password "$CH_PASSWORD" \
        --allow_database_glue_catalog=1 --distributed_ddl_output_mode=none --max_execution_time=120 --receive_timeout=180 \
        --log_comment="$1" --format TSV --query "$2"
}

case ${1:-} in
tables)
    n=${2:-40}; b=$(tf bucket); echo "tables start $(utc)" | tee out/tables.log
    for i in $(seq -w 1 "$n"); do
        # Athena's sequence() stops at 10,000 entries: rows = 200 x 1,000 for t01, 1 x 100 for the rest
        hi=0; per=100; [ "$i" = 01 ] && { hi=199; per=1000; }
        athena "CREATE TABLE t$i WITH (table_type = 'ICEBERG', location = 's3://$b/iceberg/t$i/', is_external = false) AS SELECT CAST(a * $per + b AS bigint) AS id, CAST((a * $per + b) % 97 AS integer) AS grp, concat('row-', CAST(a * $per + b AS varchar)) AS label FROM UNNEST(sequence(0, $hi)) AS u(a) CROSS JOIN UNNEST(sequence(1, $per)) AS v(b)"
        echo "t$i $(( (hi + 1) * per )) rows $(utc)" | tee -a out/tables.log
    done
    echo "tables end $(utc)" | tee -a out/tables.log
    ;;
ch)
    db=$(tf glue_database); role=$(tf chc_role_arn); : > out/marks.tsv; utc > out/ch.start
    mark() {   # mark <name> <sql>: one marked query, its start/end and the replica that ran it
        local s e r
        s=$(utc)
        # a failed query is recorded, not fatal: Cloud may replace a replica mid-run
        case $1 in *-show-*) r="$(ch "$1" "$2" | wc -l | tr -d ' ') lines" || r="ERROR" ;; *) r=$(ch "$1" "$2" | tr '\t\n' '  ') || r="ERROR" ;; esac
        e=$(utc)
        printf '%s\t%s\t%s\t%s\n' "$1" "$s" "$e" "$r" | tee -a out/marks.tsv
        sleep "${GAP:-6}"
    }
    # a new catalog name per run (no DROP): Cloud waits for every replica on database DDL, and a
    # replaced pod can stay registered for a while; distributed_ddl_output_mode=none returns at once
    cat=${CAT:-glue71_$(date -u +%H%M)}; echo "catalog $cat" | tee -a out/ch.start
    mark glue71-m0-create "CREATE DATABASE $cat ENGINE = DataLakeCatalog SETTINGS catalog_type = 'glue', region = '$REGION', aws_role_arn = '$role'"
    # 1. cache: the same one-table query 10 times; a join of 3 tables 3 times
    for i in $(seq -w 1 10); do mark "glue71-m1-repeat-$i" "SELECT count(), hostName() FROM $cat.\`$db.t01\`"; done
    for i in 1 2 3; do mark "glue71-m1-join3-$i" "SELECT count(), hostName() FROM $cat.\`$db.t01\` AS a JOIN $cat.\`$db.t02\` AS b ON a.id = b.id JOIN $cat.\`$db.t03\` AS c ON a.id = c.id"; done
    # 2. listing
    for i in 1 2 3; do mark "glue71-m2-show-$i" "SHOW TABLES FROM $cat"; done
    for i in 1 2 3; do mark "glue71-m2-systables-$i" "SELECT count(), hostName() FROM system.tables WHERE database = '$cat'"; done
    mark glue71-m2-systables-all "SELECT count(), hostName() FROM system.tables"
    echo "ch done $(utc)"
    ;;
s3)
    ch glue71-read "SYSTEM FLUSH LOGS" >/dev/null || true
    # query_log is per replica: run this right after `ch`, before Cloud replaces a pod
    clickhouse client --secure --host "$CH_HOST" --user "$CH_USER" --password "$CH_PASSWORD" \
        --skip_unavailable_shards=1 --format TSV --query "SELECT log_comment, hostname(), query_duration_ms, read_rows,
        ProfileEvents['S3GetObject'], ProfileEvents['S3HeadObject'], ProfileEvents['S3ListObjects'],
        ProfileEvents['ReadBufferFromS3'], ProfileEvents['S3ReadRequestsCount']
      FROM clusterAllReplicas('default', system.query_log)
      WHERE log_comment LIKE 'glue71-m%' AND type = 'QueryFinish' AND event_date >= today() - 1
        AND event_time >= parseDateTimeBestEffort('$(head -1 out/ch.start)')
      ORDER BY event_time_microseconds" | tee out/s3.tsv
    ;;
trail)
    [ -s out/marks.tsv ] || { echo "run ./measure.sh ch first" >&2; exit 1; }
    t0=$(sed -n 's/^tables start //p' out/tables.log); t1=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    aws cloudtrail lookup-events --region "$REGION" --start-time "$t0" --end-time "$t1" \
        --lookup-attributes AttributeKey=EventSource,AttributeValue=glue.amazonaws.com --output json \
      | jq '[.Events[] | (.CloudTrailEvent | fromjson) | {t: .eventTime, name: .eventName,
              ua: .userAgent, who: (.userIdentity.arn // ""), err: (.errorCode // null)}]' > out/trail-raw.json
    python3 -I - out/marks.tsv out/trail-raw.json "$(tf chc_role_arn | sed 's#.*/##')" out/tables.log > out/trail.json <<'PY'
import json, sys
from datetime import datetime, timezone
marks_path, raw_path, role, tables_log = sys.argv[1:5]
iso = lambda s: datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
marks = [l.rstrip("\n").split("\t") for l in open(marks_path) if l.strip()]
raw = json.load(open(raw_path))
events = [e for e in raw if role in e["who"]]
tl = {l.split(" ")[1]: l.split(" ", 2)[2].strip() for l in open(tables_log) if l.startswith("tables ")}
reg = {}   # 4. registering without a crawler: Glue calls by everyone else while Athena created the tables
for e in raw:
    if role not in e["who"] and iso(tl["start"]) <= iso(e["t"]) <= iso(tl["end"]):
        k = e["name"] + " via " + e["ua"][:24]
        reg[k] = reg.get(k, 0) + 1
out = []
for i, m in enumerate(marks):
    start = iso(m[1]); end = iso(marks[i + 1][1]) if i + 1 < len(marks) else None
    calls = {}
    for e in events:
        t = iso(e["t"])
        if t >= start and (end is None or t < end):
            k = e["name"] + (" (" + e["err"] + ")" if e["err"] else "")
            calls[k] = calls.get(k, 0) + 1
    out.append({"mark": m[0], "start": m[1], "replica_and_result": m[3].strip(), "glue_calls": calls})
print(json.dumps({"window": [tl["start"], tl["end"]], "registration_calls": reg, "clickhouse_role_events": len(events),
                  "clickhouse_user_agents": sorted({e["ua"][:40] for e in events}), "marks": out}, indent=1))
PY
    jq -c '.marks[] | {mark, glue_calls}' out/trail.json
    ;;
cleanup)   # drop the per-run catalogs once every replica answers again
    for c in $(ch glue71-read "SELECT name FROM system.databases WHERE name LIKE 'glue71%'"); do
        ch glue71-read "DROP DATABASE IF EXISTS $c" && echo "dropped $c"
    done
    ;;
*) sed -n '2,13p' "$0"; exit 2 ;;
esac
