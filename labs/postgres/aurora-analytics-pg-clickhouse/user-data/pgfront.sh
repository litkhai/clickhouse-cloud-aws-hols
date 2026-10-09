#!/bin/bash
# PostgreSQL front end (Amazon Linux 2023, arm64): pg_clickhouse in Docker. Runs once as root through
# cloud-init; main.tf puts these in front of this file:
#   export PG_MAJOR=<17|18>  PG_IMAGE=<image pinned by digest>  POSTGRES_PASSWORD=<generated>
# Progress: /var/log/lab-user-data.log. Done: /var/log/lab-ready exists.
set -euxo pipefail
exec > >(tee -a /var/log/lab-user-data.log) 2>&1

: "${PG_MAJOR:?PG_MAJOR must be 17 or 18}"
: "${PG_IMAGE:?PG_IMAGE must be set}"
: "${POSTGRES_PASSWORD:?is empty}"

dnf install -y docker
systemctl enable --now docker

# Data on a host volume. The 17 image declares VOLUME /var/lib/postgresql/data (PGDATA there);
# the 18 image declares VOLUME /var/lib/postgresql (PGDATA /var/lib/postgresql/18/docker).
# Both read from the image config on 2026-10-09.
mkdir -p /srv/pgdata
case "$PG_MAJOR" in
  17) MOUNT=/var/lib/postgresql/data ;;
  18) MOUNT=/var/lib/postgresql ;;
  *) echo "unsupported PG_MAJOR=$PG_MAJOR" >&2; exit 1 ;;
esac

docker run -d --name pg_clickhouse \
  --restart always \
  --network host \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -v "/srv/pgdata:${MOUNT}" \
  "$PG_IMAGE"

# Wait up to 2 minutes for PostgreSQL to accept connections
for _ in $(seq 1 60); do
  if docker exec pg_clickhouse pg_isready -U postgres -h 127.0.0.1 -p 5432; then
    break
  fi
  sleep 2
done
docker exec pg_clickhouse pg_isready -U postgres -h 127.0.0.1 -p 5432

{
  echo "ready $(date -u +%FT%TZ)"
  echo "image $PG_IMAGE"
  docker exec pg_clickhouse psql -U postgres -h 127.0.0.1 -Atc 'select version()'
} > /var/log/lab-ready 2>&1
