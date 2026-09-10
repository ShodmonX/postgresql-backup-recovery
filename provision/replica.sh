#!/usr/bin/env bash
set -euo pipefail

echo "==> Provisioning PostgreSQL replica on $(hostname)"

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------
# Validate required secrets
# ------------------------------------------------------------

if [[ -z "${PG_REPLICATION_PASSWORD:-}" ]]; then
  echo "ERROR: PG_REPLICATION_PASSWORD is not set"
  exit 1
fi


# ------------------------------------------------------------
# Install PostgreSQL
# ------------------------------------------------------------

apt-get update

apt-get install -y \
  postgresql-16 \
  postgresql-client-16


# ------------------------------------------------------------
# PostgreSQL paths
# ------------------------------------------------------------

PG_VERSION="16"
PG_CLUSTER="main"
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER}"

STANDBY_SIGNAL="${PG_DATA_DIR}/standby.signal"

# ------------------------------------------------------------
# Wait for primary
# ------------------------------------------------------------

echo "==> Waiting for pg-primary to accept PostgreSQL connections"

PRIMARY_READY=false

for attempt in $(seq 1 60); do
  if pg_isready \
      -h pg-primary \
      -p 5432 \
      >/dev/null 2>&1; then

    PRIMARY_READY=true
    break
  fi

  sleep 1
done

if [[ "${PRIMARY_READY}" != "true" ]]; then
  echo "ERROR: pg-primary did not become ready within 60 seconds"
  exit 1
fi

echo "==> pg-primary is reachable"

# ------------------------------------------------------------
# Check whether replica is already initialized
# ------------------------------------------------------------

if [[ -f "${STANDBY_SIGNAL}" ]]; then
  echo "==> Existing standby configuration detected"
  echo "==> Skipping destructive base backup"

  systemctl start postgresql

else
  echo "==> No existing standby configuration detected"
  echo "==> Initializing replica from pg-primary"

  systemctl stop postgresql

  echo "==> Replacing package-created data directory"

  rm -rf "${PG_DATA_DIR}"

  install \
    -d \
    -o postgres \
    -g postgres \
    -m 700 \
    "${PG_DATA_DIR}"


  # ----------------------------------------------------------
  # Clone primary
  # ----------------------------------------------------------

  echo "==> Taking base backup from pg-primary"

  BASEBACKUP_OK=false

  for attempt in $(seq 1 5); do
    if sudo -u postgres \
        env PGPASSWORD="${PG_REPLICATION_PASSWORD}" \
        pg_basebackup \
          -h pg-primary \
          -p 5432 \
          -U replicator \
          -D "${PG_DATA_DIR}" \
          -Fp \
          -Xs \
          -P \
          -R \
          -S pg_replica_slot; then

      BASEBACKUP_OK=true
      break
    fi

    echo "WARNING: pg_basebackup attempt ${attempt}/5 failed"

    if [[ "${attempt}" -lt 5 ]]; then
      echo "==> Retrying in 5 seconds"

      rm -rf "${PG_DATA_DIR}"
      install -d -o postgres -g postgres -m 700 "${PG_DATA_DIR}"

      sleep 5
    fi
  done

  if [[ "${BASEBACKUP_OK}" != "true" ]]; then
    echo "ERROR: pg_basebackup failed after 5 attempts"
    exit 1
  fi


  # ----------------------------------------------------------
  # Permissions
  # ----------------------------------------------------------

  echo "==> Ensuring correct data directory permissions"

  chown -R postgres:postgres "${PG_DATA_DIR}"
  chmod 700 "${PG_DATA_DIR}"


  # ----------------------------------------------------------
  # Start replica
  # ----------------------------------------------------------

  echo "==> Starting PostgreSQL replica"

  systemctl start postgresql
fi


# ------------------------------------------------------------
# Verification
# ------------------------------------------------------------

echo "==> Verifying standby state"

IS_IN_RECOVERY="$(
  sudo -u postgres psql -Atc \
    "SELECT pg_is_in_recovery();"
)"

if [[ "${IS_IN_RECOVERY}" != "t" ]]; then
  echo "ERROR: PostgreSQL is not running as a standby"
  exit 1
fi

echo "==> PostgreSQL is running in recovery mode"

sudo -u postgres psql -c "
SELECT
    status,
    sender_host,
    sender_port,
    slot_name
FROM pg_stat_wal_receiver;
"

echo "==> PostgreSQL replica provisioning completed"