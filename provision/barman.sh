#!/usr/bin/env bash

set -euo pipefail

echo "==> Provisioning Barman server on $(hostname)"

export DEBIAN_FRONTEND=noninteractive

if [[ -z "${BARMAN_PASSWORD:-}" ]]; then
  echo "ERROR: BARMAN_PASSWORD is not set"
  exit 1
fi

if [[ -z "${BARMAN_STREAMING_PASSWORD:-}" ]]; then
  echo "ERROR: BARMAN_STREAMING_PASSWORD is not set"
  exit 1
fi

apt-get update -y

apt-get install -y \
  barman \
  postgresql-client-16

echo "==> Configuring PostgreSQL credentials for Barman"

install -o barman -g barman -m 600 /dev/null /var/lib/barman/.pgpass

cat > /var/lib/barman/.pgpass <<EOF
pg-primary:5432:*:barman:${BARMAN_PASSWORD}
pg-primary:5432:*:barman_streaming:${BARMAN_STREAMING_PASSWORD}
EOF

chown barman:barman /var/lib/barman/.pgpass
chmod 600 /var/lib/barman/.pgpass

echo "==> Configuring pg-primary in Barman"

cat > /etc/barman.d/pg-primary.conf <<'EOF'
[pg-primary]
description = "PostgreSQL 16 primary"

conninfo = host=pg-primary port=5432 user=barman dbname=postgres
streaming_conninfo = host=pg-primary port=5432 user=barman_streaming dbname=postgres

backup_method = postgres
streaming_archiver = on
slot_name = barman_wal_slot
create_slot = auto

retention_policy = REDUNDANCY 2
EOF

chown root:barman /etc/barman.d/pg-primary.conf
chmod 640 /etc/barman.d/pg-primary.conf

echo "==> Barman provisioning completed"