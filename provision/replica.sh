#!/usr/bin/env bash

set -euo pipefail

echo "==> Provisioning PostgreSQL replica on $(hostname)"

export DEBIAN_FRONTEND=noninteractive

if [[ -z "${PG_REPLICATION_PASSWORD:-}" ]]; then
  echo "ERROR: PG_REPLICATION_PASSWORD is not set"
  exit 1
fi

apt-get update -y

apt-get install -y \
  postgresql-16 \
  postgresql-client-16

PG_VERSION="16"
PG_CLUSTER="main"
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER}"

echo "==> Stopping local PostgreSQL cluster"

systemctl stop postgresql

echo "==> Replacing local data directory with base backup from pg-primary"

rm -rf "${PG_DATA_DIR}"
install -d -o postgres -g postgres -m 700 "${PG_DATA_DIR}"

export PGPASSWORD="${PG_REPLICATION_PASSWORD}"

sudo -u postgres \
  env PGPASSWORD="${PG_REPLICATION_PASSWORD}" \
  pg_basebackup \
    -h pg-primary \
    -p 5432 \
    -U replicator \
    -D "${PG_DATA_DIR}" \
    -Fp \
    -Xs \
    -P \
    -R

unset PGPASSWORD

echo "==> Ensuring correct data directory permissions"

chown -R postgres:postgres "${PG_DATA_DIR}"
chmod 700 "${PG_DATA_DIR}"

echo "==> Starting PostgreSQL replica"

systemctl start postgresql

echo "==> Verifying standby state"

sudo -u postgres psql -Atc "SELECT pg_is_in_recovery();"

echo "==> PostgreSQL replica provisioning completed"