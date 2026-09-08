#!/usr/bin/env bash

set -euo pipefail

echo "==> Provisioning PostgreSQL primary on $(hostname)"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y

# Ubuntu 24.04 default repository provides PostgreSQL 16.
apt-get install -y \
  postgresql-16 \
  postgresql-client-16

PG_VERSION="16"
PG_CLUSTER="main"
PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER}"
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER}"

echo "==> Configuring PostgreSQL ${PG_VERSION}"

# PostgreSQL should listen on the VMnet1 interface as well as localhost.
sed -i \
  "s/^#\?listen_addresses\s*=.*/listen_addresses = '*'/" \
  "${PG_CONF_DIR}/postgresql.conf"

# Physical replication and Barman WAL streaming requirements.
sed -i \
  "s/^#\?wal_level\s*=.*/wal_level = replica/" \
  "${PG_CONF_DIR}/postgresql.conf"

sed -i \
  "s/^#\?max_wal_senders\s*=.*/max_wal_senders = 10/" \
  "${PG_CONF_DIR}/postgresql.conf"

sed -i \
  "s/^#\?max_replication_slots\s*=.*/max_replication_slots = 10/" \
  "${PG_CONF_DIR}/postgresql.conf"

# Keep enough WAL available for short interruptions.
sed -i \
  "s/^#\?wal_keep_size\s*=.*/wal_keep_size = 512MB/" \
  "${PG_CONF_DIR}/postgresql.conf"

systemctl restart postgresql

echo "==> Verifying PostgreSQL"

sudo -u postgres psql -Atc "SELECT version();"
sudo -u postgres psql -Atc "SHOW listen_addresses;"
sudo -u postgres psql -Atc "SHOW wal_level;"
sudo -u postgres psql -Atc "SHOW max_wal_senders;"
sudo -u postgres psql -Atc "SHOW max_replication_slots;"
sudo -u postgres psql -Atc "SHOW wal_keep_size;"

echo "==> PostgreSQL primary provisioning completed"