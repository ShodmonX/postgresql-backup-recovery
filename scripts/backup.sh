#!/usr/bin/env bash
set -euo pipefail

BARMAN_VM="barman"
SERVER_NAME="pg-primary"

echo "==> Starting PostgreSQL backup workflow"

# ------------------------------------------------------------
# Verify Barman VM is reachable
# ------------------------------------------------------------

if ! vagrant ssh "${BARMAN_VM}" -c "hostname" -- -T >/dev/null 2>&1; then
  echo "ERROR: ${BARMAN_VM} is not reachable through Vagrant"
  echo "Run 'vagrant up' first."
  exit 1
fi


# ------------------------------------------------------------
# Verify Barman health
# ------------------------------------------------------------

echo "==> Checking Barman"

vagrant ssh "${BARMAN_VM}" -c \
  "sudo -u barman barman check ${SERVER_NAME}" -- -T


# ------------------------------------------------------------
# Force WAL switch and wait for archive
# ------------------------------------------------------------

echo "==> Switching and archiving WAL"

vagrant ssh "${BARMAN_VM}" -c \
  "sudo -u barman barman switch-wal --force --archive --archive-timeout 30 ${SERVER_NAME}" -- -T


# ------------------------------------------------------------
# Run backup
# ------------------------------------------------------------

echo "==> Starting Barman backup"

vagrant ssh "${BARMAN_VM}" -c \
  "sudo -u barman barman backup --wait ${SERVER_NAME}" -- -T


# ------------------------------------------------------------
# Get latest backup ID
# ------------------------------------------------------------

BACKUP_LIST="$(
  vagrant ssh "${BARMAN_VM}" -c \
    "sudo -u barman barman list-backups ${SERVER_NAME} --minimal" -- -T \
    | tr -d '\r'
)"

BACKUP_ID="$(printf '%s\n' "${BACKUP_LIST}" | sed -n '1p')"

if [[ -z "${BACKUP_ID}" ]]; then
  echo "ERROR: Unable to determine backup ID"
  exit 1
fi

echo "==> Backup ID: ${BACKUP_ID}"


# ------------------------------------------------------------
# Verify backup status
# ------------------------------------------------------------

echo "==> Verifying backup"

if ! vagrant ssh "${BARMAN_VM}" -c \
  "sudo -u barman barman show-backup ${SERVER_NAME} ${BACKUP_ID} | grep -Eq '^[[:space:]]*Status[[:space:]]*:[[:space:]]*DONE[[:space:]]*$'" -- -T; then

  echo "ERROR: Backup ${BACKUP_ID} is not in DONE state"

  vagrant ssh "${BARMAN_VM}" -c \
    "sudo -u barman barman show-backup ${SERVER_NAME} ${BACKUP_ID}" -- -T

  exit 1
fi


# ------------------------------------------------------------
# Display backup
# ------------------------------------------------------------

vagrant ssh "${BARMAN_VM}" -c \
  "sudo -u barman barman show-backup ${SERVER_NAME} ${BACKUP_ID}" -- -T

echo
echo "========================================="
echo " BACKUP WORKFLOW: PASS"
echo "========================================="
echo "Server: ${SERVER_NAME}"
echo "Backup: ${BACKUP_ID}"
echo "Status: DONE"