#!/bin/bash
# Runs ON THE CLIENT (sent by 20-push.sh, started by 30-run.sh). One phase per call:
#   matrix.sh floor|s1|kv|s2|s3|all <stamp>
# Results: /opt/cachebench/results/<stamp>/<phase>.jsonl, synced to s3://$BUCKET/results/<stamp>/
# after every run. Lists below can be overridden in the environment (e.g. S1_CONC="8 32").
set -uo pipefail
cd /opt/cachebench
set -a; . ./env; set +a
ulimit -n 65536

PHASE=${1:?phase}; STAMP=${2:?stamp}
OUT=results/$STAMP; mkdir -p "$OUT"
DUR=${DUR:-60s}; WARM=${WARM:-10s}

FLOOR_CONC=${FLOOR_CONC:-"1 16"}
S1_ARMS=${S1_ARMS:-"ch ch-qc vk-aside ddb-aside"}; S1_SPACE=${S1_SPACE:-"100 10000 1000000"}; S1_CONC=${S1_CONC:-"8 32 128"}
S2_ARMS=${S2_ARMS:-"ch ch-agg vk-kv ddb-kv vk-aside ddb-aside"}; S2_CONC=${S2_CONC:-"8 32 128 512"}
S3_CACHED=${S3_CACHED:-"ch-qc vk-aside ddb-aside"}; S3_TTL=${S3_TTL:-"5 60"}; S3_CONC=${S3_CONC:-"32 128"}

sync_out() { aws s3 sync --quiet "$OUT" "s3://$BUCKET/results/$STAMP/"; }
log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$OUT/matrix.log"; }

run() {  # run <phase file> <cachebench args...>
  local f="$OUT/$1.jsonl"; shift
  log "start $*"
  ./cachebench "$@" --out "$f" >>"$OUT/stdout.log" 2>>"$OUT/stderr.log" || log "FAILED ($?) $*"
  sync_out
}

phase_floor() { for c in $FLOOR_CONC; do run floor floor --conc "$c" --duration "$DUR"; done; }

phase_s1() {
  for space in $S1_SPACE; do for arm in $S1_ARMS; do for c in $S1_CONC; do
    run s1 run --scenario s1 --arm "$arm" --conc "$c" --space "$space" --ttl 60 --warmup "$WARM" --duration "$DUR"
  done; done; done
}

phase_kv() { run kv load-kv --target vk; run kv load-kv --target ddb; }

phase_s2() {
  for arm in $S2_ARMS; do for c in $S2_CONC; do
    run s2 run --scenario s2 --arm "$arm" --conc "$c" --dist zipf --ttl 60 --warmup "$WARM" --duration "$DUR"
  done; done
}

phase_s3() {
  for c in $S3_CONC; do
    for arm in ch ch-agg; do
      run s3 run --scenario s3 --arm "$arm" --conc "$c" --ttl 0 --warmup "$WARM" --duration "$DUR"
    done
    for arm in $S3_CACHED; do for ttl in $S3_TTL; do
      run s3 run --scenario s3 --arm "$arm" --conc "$c" --ttl "$ttl" --warmup "$WARM" --duration "$DUR"
    done; done
  done
}

case "$PHASE" in
  floor|s1|kv|s2|s3) "phase_$PHASE" ;;
  all) phase_floor; phase_s1; phase_kv; phase_s2; phase_s3 ;;   # s3 last: it inserts rows
  *) echo "unknown phase $PHASE" >&2; exit 2 ;;
esac
log "done $PHASE"
sync_out
