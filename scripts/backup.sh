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

encode_base64() {
  printf '%s' "$1" | base64 | tr -d '\r\n'
}

barman_sql() {
  local sql="$1"
  local sql_base64
  sql_base64="$(encode_base64 "${sql}")"

  run_vagrant "${BARMAN_VM}" \
    "echo ${sql_base64} | base64 -d | sudo -u barman psql 'host=pg-primary port=5432 user=barman dbname=postgres' -v ON_ERROR_STOP=1 -Atq"
}

echo "==> Starting PostgreSQL backup workflow"

# ------------------------------------------------------------
# Verify Barman VM is reachable
# ------------------------------------------------------------

echo "==> Checking ${BARMAN_VM}"

if ! vagrant ssh "${BARMAN_VM}" -c "hostname" -- -T >/dev/null 2>&1; then
  echo "ERROR: ${BARMAN_VM} is not reachable through Vagrant. Run 'vagrant up' first."
  exit 1
fi

# ------------------------------------------------------------
# Verify PostgreSQL management connectivity
# ------------------------------------------------------------

echo "==> Checking PostgreSQL connectivity from Barman"

run_vagrant "${BARMAN_VM}" \
  "sudo -u barman psql 'host=pg-primary port=5432 user=barman dbname=postgres' -Atc 'SELECT 1;' >/dev/null" \
  >/dev/null

# ------------------------------------------------------------
# Verify receive-wal process
# ------------------------------------------------------------

echo "==> Checking Barman receive-wal"

run_vagrant "${BARMAN_VM}" \
  "pgrep -u barman -f 'receive-wal ${SERVER_NAME}' >/dev/null" \
  >/dev/null

# ------------------------------------------------------------
# Generate and archive a complete WAL segment
# ------------------------------------------------------------

echo "==> Preparing WAL archive"

# Close the segment that receive-wal may have joined partially.
barman_sql "SELECT pg_switch_wal();" >/dev/null

# Generate WAL activity in the new segment.
barman_sql "SELECT pg_create_restore_point('backup_workflow');" >/dev/null

# Close the fully streamed segment.
barman_sql "SELECT pg_switch_wal();" >/dev/null

# ------------------------------------------------------------
# Archive WAL
# ------------------------------------------------------------

echo "==> Archiving WAL"

run_vagrant "${BARMAN_VM}" \
  "sudo -u barman barman archive-wal ${SERVER_NAME}" \
  >/dev/null

# ------------------------------------------------------------
# Verify Barman health after WAL pipeline is initialized
# ------------------------------------------------------------

echo "==> Checking Barman"

run_vagrant "${BARMAN_VM}" \
  "sudo -u barman barman check ${SERVER_NAME}"

# ------------------------------------------------------------
# Run backup
# ------------------------------------------------------------

echo "==> Starting Barman backup"

run_vagrant "${BARMAN_VM}" \
  "sudo -u barman barman backup --wait ${SERVER_NAME}"

# ------------------------------------------------------------
# Get latest backup ID
# ------------------------------------------------------------

BACKUP_LIST="$(
  run_vagrant "${BARMAN_VM}" \
    "sudo -u barman barman list-backups ${SERVER_NAME} --minimal"
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

run_vagrant "${BARMAN_VM}" \
  "sudo -u barman barman show-backup ${SERVER_NAME} ${BACKUP_ID}"

echo
echo "========================================="
echo " BACKUP WORKFLOW: PASS"
echo "========================================="
echo "Server: ${SERVER_NAME}"
echo "Backup: ${BACKUP_ID}"
echo "Status: DONE"
