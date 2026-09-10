#!/usr/bin/env bash

set -euo pipefail

TARGET_FILE=".recovery-target"
STAGING_DIR="/var/lib/barman/recovery-staging"
RECOVERY_DATA="/var/lib/postgresql/16/main"

if [[ ! -f "${TARGET_FILE}" ]]; then
    echo "ERROR: ${TARGET_FILE} not found"
    echo "Run simulate-data-loss.sh first."
    exit 1
fi

RECOVERY_TARGET="$(tr -d '\r\n' < "${TARGET_FILE}")"

echo "==> Recovery target: ${RECOVERY_TARGET}"

echo "==> Archiving completed WAL segments"

vagrant ssh barman -c \
    "sudo -u barman barman archive-wal pg-primary"

echo "==> Selecting latest backup before recovery target"

BACKUP_ID="$(
    vagrant ssh barman -c \
        "sudo -u barman barman list-backups pg-primary --minimal" |
    tr -d '\r' |
    head -n 1
)"

if [[ -z "${BACKUP_ID}" ]]; then
    echo "ERROR: No Barman backup found"
    exit 1
fi

echo "==> Using backup: ${BACKUP_ID}"

echo "==> Preparing staging directory on Barman"

vagrant ssh barman -c \
    "sudo rm -rf '${STAGING_DIR}' &&
     sudo install -d -o barman -g barman -m 700 '${STAGING_DIR}'"

echo "==> Restoring backup to recovery staging directory"

vagrant ssh barman -c \
    "sudo -u barman barman restore \
        --target-time '${RECOVERY_TARGET}' \
        --target-action pause \
        pg-primary \
        '${BACKUP_ID}' \
        '${STAGING_DIR}'"

echo "==> Preparing pg-recovery"

vagrant ssh pg-recovery -c \
    "sudo systemctl stop postgresql &&
     sudo rm -rf '${RECOVERY_DATA}' &&
     sudo install -d -o postgres -g postgres -m 700 '${RECOVERY_DATA}'"

echo "==> Transferring restored PGDATA"

vagrant ssh barman -c \
    "sudo tar -C '${STAGING_DIR}' -cf /tmp/recovery.tar . &&
     sudo chmod 644 /tmp/recovery.tar"

vagrant ssh barman -c \
    "cat /tmp/recovery.tar" |
vagrant ssh pg-recovery -c \
    "sudo tar -C '${RECOVERY_DATA}' -xf -"

echo "==> Fixing ownership"

vagrant ssh pg-recovery -c \
    "sudo chown -R postgres:postgres '${RECOVERY_DATA}' &&
     sudo chmod 700 '${RECOVERY_DATA}'"

echo "==> Starting PostgreSQL recovery"

vagrant ssh pg-recovery -c \
    "sudo systemctl start postgresql"

echo "==> Waiting for recovery target"

sleep 3

echo "==> PITR status"

vagrant ssh pg-recovery -c \
    "sudo -u postgres psql -c \"
        SELECT
            pg_is_in_recovery(),
            pg_last_wal_replay_lsn(),
            pg_last_xact_replay_timestamp();
    \""

echo "==> PITR restore completed"