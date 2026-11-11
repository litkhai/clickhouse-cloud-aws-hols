# Sourced by the scripts: terraform outputs, Postgres and ClickHouse helpers.
# Needs CHC_KEY CHC_SECRET ORG_ID SERVICE_ID CH_HOST CH_USER CH_PASSWORD (a test service in ap-northeast-2).
tf() { terraform -chdir=terraform output -raw "$1"; }
export PGHOST=$(tf pg_host) PGUSER=$(tf pg_user) PGPASSWORD=$(terraform -chdir=terraform output -raw pg_password) PGDATABASE=app
export KEYRING_PARAM=$(tf keyring_param) KMS_ALIAS=$(tf kms_alias) LAMBDA_NAME=$(tf lambda_name) API_URL=$(tf api_url)
q() { clickhouse client --host "$CH_HOST" --secure --user "$CH_USER" --password "$CH_PASSWORD" "$@"; }
pg() { uv run -q --with 'psycopg[binary]' pg.py "$@"; }
load() { uv run -q --with 'psycopg[binary]' --with cryptography load.py "$@"; }
keys() { uv run -q --with boto3 keys.py "$@"; }
step() { printf '\n== %s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
reload_expected() { load expected > out/expected.tsv && q -q "TRUNCATE TABLE lab.expected" && q -q "INSERT INTO lab.expected FORMAT TSV" < out/expected.tsv; }
wait_caught_up() {  # until the decrypted table has every live raw row
  until [ "$(q -q "SELECT (SELECT count() FROM app.users FINAL) = (SELECT count() FROM raw.users FINAL WHERE _peerdb_is_deleted = 0) AND (SELECT count() FROM raw.users FINAL WHERE _peerdb_is_deleted = 0) = (SELECT count() FROM lab.expected)")" = 1 ]; do
    sleep 10; done; date -u +"%T caught up"; }
