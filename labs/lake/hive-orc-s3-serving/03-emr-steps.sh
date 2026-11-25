#!/usr/bin/env bash
# Run one stage as an EMR step and wait for it: gen | explode | bi | day31
#   gen     30 days x ROWS_PER_DAY events (default 5,000,000) into game_lake.events_raw
#   explode game_lake.events_raw -> game_lake.item_events (the transform job)
#   bi      the five BI queries, 3 runs each
#   day31   one more day (2026-10-31) for the incremental test
# Prints the step's start/end (what the cost uses) and, once EMR has shipped the log, its RESULT lines.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
set -a; source .env; set +a
BUCKET=$(terraform -chdir=terraform output -raw bucket)
CID=$(cat .cluster-id)
ROWS=${ROWS_PER_DAY:-5000000}
case "$1" in
  gen)     ARGS="s3://$BUCKET/scripts/gen_events.py,$BUCKET,2026-10-01,30,$ROWS" ;;
  explode) ARGS="s3://$BUCKET/scripts/explode_items.py,$BUCKET" ;;
  bi)      ARGS="s3://$BUCKET/scripts/bi_queries.py,$BUCKET,3" ;;
  day31)   ARGS="s3://$BUCKET/scripts/gen_events.py,$BUCKET,2026-10-31,1,$ROWS" ;;
  *) echo "usage: $0 gen|explode|bi|day31" >&2; exit 2 ;;
esac
SID=$(aws emr add-steps --region "$AWS_REGION" --cluster-id "$CID" \
  --steps "Type=Spark,Name=$1,ActionOnFailure=CONTINUE,Args=[--deploy-mode,client,$ARGS]" \
  --query 'StepIds[0]' --output text)
echo "step $1 = $SID"
aws emr wait step-complete --region "$AWS_REGION" --cluster-id "$CID" --step-id "$SID" || true
aws emr describe-step --region "$AWS_REGION" --cluster-id "$CID" --step-id "$SID" \
  --query 'Step.{name:Name,state:Status.State,start:Status.Timeline.StartDateTime,end:Status.Timeline.EndDateTime,reason:Status.FailureDetails.Message}'
echo "$1 $SID" >> .steps
for _ in $(seq 1 20); do
  if aws s3 cp "s3://$BUCKET/emr-logs/$CID/steps/$SID/stdout.gz" - --region "$AWS_REGION" 2>/dev/null | gunzip | grep RESULT; then
    exit 0
  fi
  sleep 30
done
echo "stdout not shipped yet: s3://$BUCKET/emr-logs/$CID/steps/$SID/stdout.gz"
