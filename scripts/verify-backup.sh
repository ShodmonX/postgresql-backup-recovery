#!/usr/bin/env bash
set -euo pipefail

BARMAN_VM="barman"
SERVER_NAME="pg-primary"

run_vagrant() {
  local vm="$1"
  local command="$2"
  local output

  if ! output="$(vagrant ssh "${vm}" -c "${command}" -- -T)"; then
    echo "ERROR: Command failed on VM '${vm}': ${command}" >&2
    return 1
  fi

  printf '%s\n' "${output}" | tr -d '\r'
}

echo "==> Verifying latest Barman backup"
echo "==> Checking ${BARMAN_VM}"

if ! vagrant ssh "${BARMAN_VM}" -c "hostname" -- -T >/dev/null 2>&1; then
  echo "ERROR: ${BARMAN_VM} is not reachable through Vagrant."
  exit 1
fi

echo "==> Running Barman health check"
run_vagrant "${BARMAN_VM}" \
  "sudo -u barman barman check ${SERVER_NAME}"

echo "==> Finding latest backup"

BACKUP_LIST="$(
  run_vagrant "${BARMAN_VM}" \
    "sudo -u barman barman list-backups ${SERVER_NAME} --minimal"
)"

BACKUP_ID="$(printf '%s\n' "${BACKUP_LIST}" | sed -n '1p')"

if [[ -z "${BACKUP_ID}" ]]; then
  echo "ERROR: No backups found for ${SERVER_NAME}"
  exit 1
fi

echo "==> Latest backup: ${BACKUP_ID}"
echo "==> Checking backup status"

if ! vagrant ssh "${BARMAN_VM}" -c \
  "sudo -u barman barman show-backup ${SERVER_NAME} ${BACKUP_ID} | grep -Eq '^[[:space:]]*Status[[:space:]]*:[[:space:]]*DONE[[:space:]]*$'" -- -T; then

  vagrant ssh "${BARMAN_VM}" -c \
    "sudo -u barman barman show-backup ${SERVER_NAME} ${BACKUP_ID}" -- -T
  echo "ERROR: Backup ${BACKUP_ID} is not in DONE state"
  exit 1
fi

echo "==> Checking backup with barman verify-backup"
run_vagrant "${BARMAN_VM}" \
  "sudo -u barman barman verify-backup ${SERVER_NAME} ${BACKUP_ID}"

echo "==> Backup details"
run_vagrant "${BARMAN_VM}" \
  "sudo -u barman barman show-backup ${SERVER_NAME} ${BACKUP_ID}"

echo
echo "========================================="
echo " BACKUP VERIFICATION: PASS"
echo "========================================="
echo "Server: ${SERVER_NAME}"
echo "Backup: ${BACKUP_ID}"
echo "Status: DONE"
