#!/usr/bin/env bash
set -euo pipefail

echo "==> Provisioning PostgreSQL primary on $(hostname)"

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------
# Validate required secrets
# ------------------------------------------------------------

if [[ -z "${PG_REPLICATION_PASSWORD:-}" ]]; then
  echo "ERROR: PG_REPLICATION_PASSWORD is not set"
  exit 1
fi

if [[ -z "${BARMAN_PASSWORD:-}" ]]; then
  echo "ERROR: BARMAN_PASSWORD is not set"
  exit 1
fi

if [[ -z "${BARMAN_STREAMING_PASSWORD:-}" ]]; then
  echo "ERROR: BARMAN_STREAMING_PASSWORD is not set"
  exit 1
fi


# ------------------------------------------------------------
# Install PostgreSQL
# ------------------------------------------------------------

apt-get update

# Ubuntu 24.04 default repository provides PostgreSQL 16.
apt-get install -y \
  postgresql-16 \
  postgresql-client-16


# ------------------------------------------------------------
# PostgreSQL paths
# ------------------------------------------------------------

PG_VERSION="16"
PG_CLUSTER="main"

PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER}"
PG_CONF="${PG_CONF_DIR}/postgresql.conf"
PG_HBA="${PG_CONF_DIR}/pg_hba.conf"


# ------------------------------------------------------------
# Configure PostgreSQL
# ------------------------------------------------------------

echo "==> Configuring PostgreSQL ${PG_VERSION}"

# Remove the previous managed block if provisioning is re-run.
sed -i \
  '/# BEGIN POSTGRESQL-BACKUP-RECOVERY/,/# END POSTGRESQL-BACKUP-RECOVERY/d' \
  "${PG_CONF}"

cat >> "${PG_CONF}" <<'EOF'

# BEGIN POSTGRESQL-BACKUP-RECOVERY

# Listen on localhost and the internal VM network.
listen_addresses = '*'

# Physical replication and Barman streaming requirements.
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10

# Keep some WAL locally for short replica interruptions.
wal_keep_size = 512MB

# Passwords created by this lab must work with SCRAM HBA rules.
password_encryption = 'scram-sha-256'

# END POSTGRESQL-BACKUP-RECOVERY
EOF


# ------------------------------------------------------------
# Create PostgreSQL roles
# ------------------------------------------------------------

echo "==> Creating PostgreSQL roles"

sudo -u postgres psql \
  --set=replication_password="${PG_REPLICATION_PASSWORD}" \
  --set=barman_password="${BARMAN_PASSWORD}" \
  --set=barman_streaming_password="${BARMAN_STREAMING_PASSWORD}" <<'SQL'

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'replicator'
  ) THEN
    CREATE ROLE replicator WITH LOGIN REPLICATION;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'barman'
  ) THEN
    CREATE ROLE barman WITH LOGIN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'barman_streaming'
  ) THEN
    CREATE ROLE barman_streaming WITH LOGIN REPLICATION;
  END IF;
END
$$;

ALTER ROLE replicator
  PASSWORD :'replication_password';

ALTER ROLE barman
  PASSWORD :'barman_password';

ALTER ROLE barman_streaming
  PASSWORD :'barman_streaming_password';


-- Barman management / monitoring privileges.
GRANT pg_monitor TO barman;
GRANT pg_checkpoint TO barman;

GRANT EXECUTE ON FUNCTION pg_backup_start(text, boolean)
TO barman;

GRANT EXECUTE ON FUNCTION pg_backup_stop(boolean)
TO barman;

GRANT EXECUTE ON FUNCTION pg_switch_wal()
TO barman;

GRANT EXECUTE ON FUNCTION pg_create_restore_point(text)
TO barman;

SQL


# ------------------------------------------------------------
# Configure client authentication
# ------------------------------------------------------------

echo "==> Configuring pg_hba.conf"

sed -i \
  '/# BEGIN POSTGRESQL-BACKUP-RECOVERY/,/# END POSTGRESQL-BACKUP-RECOVERY/d' \
  "${PG_HBA}"

cat >> "${PG_HBA}" <<'EOF'

# BEGIN POSTGRESQL-BACKUP-RECOVERY

# Physical streaming replica.
host replication replicator         192.168.167.202/32 scram-sha-256

# Barman management connection.
host postgres    barman             192.168.167.210/32 scram-sha-256

# Barman WAL streaming connection.
host replication barman_streaming   192.168.167.210/32 scram-sha-256

# END POSTGRESQL-BACKUP-RECOVERY
EOF


# ------------------------------------------------------------
# Apply configuration
# ------------------------------------------------------------

echo "==> Restarting PostgreSQL"

systemctl restart postgresql

echo "==> Waiting for PostgreSQL primary to become ready"

PRIMARY_READY=false

for attempt in $(seq 1 60); do
  if pg_isready \
      -h 192.168.167.201 \
      -p 5432 \
      -d postgres \
      >/dev/null 2>&1; then

    PRIMARY_READY=true
    break
  fi

  sleep 1
done

if [[ "${PRIMARY_READY}" != "true" ]]; then
  echo "ERROR: PostgreSQL primary did not become ready within 60 seconds"
  systemctl --no-pager status postgresql || true
  exit 1
fi

echo "==> PostgreSQL primary is accepting TCP connections"

# ------------------------------------------------------------
# Create physical replication slot
# ------------------------------------------------------------

echo "==> Ensuring physical replication slot for pg-replica exists"

sudo -u postgres psql <<'SQL'

SELECT pg_create_physical_replication_slot('pg_replica_slot')
WHERE NOT EXISTS (
  SELECT 1
  FROM pg_replication_slots
  WHERE slot_name = 'pg_replica_slot'
);

SQL


# ------------------------------------------------------------
# Verification
# ------------------------------------------------------------

echo "==> Verifying PostgreSQL"

sudo -u postgres psql -Atc "SELECT version();"
sudo -u postgres psql -Atc "SHOW listen_addresses;"
sudo -u postgres psql -Atc "SHOW wal_level;"
sudo -u postgres psql -Atc "SHOW max_wal_senders;"
sudo -u postgres psql -Atc "SHOW max_replication_slots;"
sudo -u postgres psql -Atc "SHOW wal_keep_size;"
sudo -u postgres psql -Atc "SHOW password_encryption;"

sudo -u postgres psql -c "
SELECT
  slot_name,
  slot_type,
  active
FROM pg_replication_slots
WHERE slot_name = 'pg_replica_slot';
"

echo "==> PostgreSQL primary provisioning completed"