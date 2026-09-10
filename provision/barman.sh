#!/usr/bin/env bash
set -euo pipefail

echo "==> Provisioning Barman server on $(hostname)"

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------
# Validate required secrets
# ------------------------------------------------------------

if [[ -z "${BARMAN_PASSWORD:-}" ]]; then
  echo "ERROR: BARMAN_PASSWORD is not set"
  exit 1
fi

if [[ -z "${BARMAN_STREAMING_PASSWORD:-}" ]]; then
  echo "ERROR: BARMAN_STREAMING_PASSWORD is not set"
  exit 1
fi


# ------------------------------------------------------------
# Install Barman
# ------------------------------------------------------------

apt-get update

apt-get install -y \
  barman \
  postgresql-client-16


# ------------------------------------------------------------
# Configure PostgreSQL credentials
# ------------------------------------------------------------

echo "==> Configuring PostgreSQL credentials for Barman"

install \
  -o barman \
  -g barman \
  -m 600 \
  /dev/null \
  /var/lib/barman/.pgpass

cat > /var/lib/barman/.pgpass <<EOF_PGPASS
pg-primary:5432:*:barman:${BARMAN_PASSWORD}
pg-primary:5432:*:barman_streaming:${BARMAN_STREAMING_PASSWORD}
EOF_PGPASS

chown barman:barman /var/lib/barman/.pgpass
chmod 600 /var/lib/barman/.pgpass


# ------------------------------------------------------------
# Configure pg-primary in Barman
# ------------------------------------------------------------

echo "==> Configuring pg-primary in Barman"

cat > /etc/barman.d/pg-primary.conf <<'EOF_CONFIG'
[pg-primary]

description = "PostgreSQL 16 primary"

conninfo = host=pg-primary port=5432 user=barman dbname=postgres
streaming_conninfo = host=pg-primary port=5432 user=barman_streaming dbname=postgres

backup_method = postgres

streaming_archiver = on
slot_name = barman_wal_slot
create_slot = auto

path_prefix = /usr/lib/postgresql/16/bin

retention_policy = REDUNDANCY 2
EOF_CONFIG

chown root:barman /etc/barman.d/pg-primary.conf
chmod 640 /etc/barman.d/pg-primary.conf


# ------------------------------------------------------------
# Validate local Barman configuration
# ------------------------------------------------------------

echo "==> Validating Barman configuration"

sudo -u barman barman diagnose >/dev/null


# ------------------------------------------------------------
# Wait for pg-primary
# ------------------------------------------------------------

echo "==> Waiting for pg-primary"

PRIMARY_READY=false

for attempt in $(seq 1 60); do
  if pg_isready -h pg-primary -p 5432 >/dev/null 2>&1; then
    PRIMARY_READY=true
    break
  fi

  sleep 1
done

if [[ "${PRIMARY_READY}" != "true" ]]; then
  echo "ERROR: pg-primary did not become ready within 60 seconds"
  exit 1
fi

echo "==> pg-primary is accepting PostgreSQL connections"


# ------------------------------------------------------------
# Test Barman management connection
# ------------------------------------------------------------

echo "==> Testing PostgreSQL management connection"

MANAGEMENT_READY=false

for attempt in $(seq 1 30); do
  if sudo -u barman \
      psql \
        "host=pg-primary port=5432 user=barman dbname=postgres" \
        -v ON_ERROR_STOP=1 \
        -Atc "SELECT 1;" \
        >/dev/null 2>&1; then

    MANAGEMENT_READY=true
    break
  fi

  sleep 1
done

if [[ "${MANAGEMENT_READY}" != "true" ]]; then
  echo "ERROR: Barman management connection to pg-primary failed"
  exit 1
fi

echo "==> PostgreSQL management connection is working"


# ------------------------------------------------------------
# Ensure Barman WAL replication slot exists
# ------------------------------------------------------------

echo "==> Ensuring Barman WAL replication slot exists"

if ! sudo -u barman \
  psql \
    "host=pg-primary port=5432 user=barman dbname=postgres" \
    -v ON_ERROR_STOP=1 \
    -Atc "SELECT 1 FROM pg_replication_slots WHERE slot_name = 'barman_wal_slot';" \
  | grep -qx 1; then

  sudo -u barman barman receive-wal --create-slot pg-primary
fi


# ------------------------------------------------------------
# Start Barman background processes
# ------------------------------------------------------------

echo "==> Starting Barman background processes"

sudo -u barman barman cron


# ------------------------------------------------------------
# Lightweight receive-wal verification
# ------------------------------------------------------------

echo "==> Waiting for Barman receive-wal process"

RECEIVER_READY=false

for attempt in $(seq 1 30); do
  if pgrep -u barman -f "receive-wal pg-primary" >/dev/null; then
    RECEIVER_READY=true
    break
  fi

  sleep 1
done

if [[ "${RECEIVER_READY}" != "true" ]]; then
  echo "ERROR: Barman receive-wal process did not start"
  ps aux | grep '[b]arman' || true
  tail -n 50 /var/log/barman/barman.log || true
  exit 1
fi

echo "==> Barman receive-wal process is running"


# ------------------------------------------------------------
# Provisioning complete
# ------------------------------------------------------------

echo "==> Barman provisioning completed"
