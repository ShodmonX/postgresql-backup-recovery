#!/usr/bin/env bash
set -euo pipefail

PRIMARY_VM="pg-primary"
BARMAN_VM="barman"
SERVER_NAME="pg-primary"
DB_NAME="recovery_demo"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_FILE="${REPO_ROOT}/.recovery-target"


echo "==> Starting data-loss simulation"


# ------------------------------------------------------------
# Verify primary is reachable
# ------------------------------------------------------------

echo "==> Checking ${PRIMARY_VM}"

if ! vagrant ssh "${PRIMARY_VM}" -c "hostname" -- -T >/dev/null 2>&1; then
  echo "ERROR: ${PRIMARY_VM} is not reachable through Vagrant"
  echo "Run 'vagrant up' first."
  exit 1
fi


# ------------------------------------------------------------
# Verify demo data exists
# ------------------------------------------------------------

echo "==> Verifying demo data"

ROW_COUNT="$(
  vagrant ssh "${PRIMARY_VM}" -c \
    "sudo -u postgres psql ${DB_NAME} -Atqc 'SELECT count(*) FROM customer_orders;'" -- -T \
    | tr -d '\r'
)"

if [[ "${ROW_COUNT}" != "3" ]]; then
  echo "ERROR: Expected 3 rows before data-loss simulation, found '${ROW_COUNT}'"
  echo "Run setup-demo first."
  exit 1
fi

echo "==> Demo rows before data loss: ${ROW_COUNT}"


# ------------------------------------------------------------
# Force WAL boundary before recovery target
# ------------------------------------------------------------

echo "==> Switching WAL before recovery target"

vagrant ssh "${PRIMARY_VM}" -c \
  "sudo -u postgres psql -Atqc 'SELECT pg_switch_wal();'" -- -T \
  >/dev/null


# ------------------------------------------------------------
# Record recovery target
# ------------------------------------------------------------

RECOVERY_TARGET="$(
  vagrant ssh "${PRIMARY_VM}" -c \
    "sudo -u postgres psql ${DB_NAME} -Atqc 'SELECT clock_timestamp();'" -- -T \
    | tr -d '\r'
)"

if [[ -z "${RECOVERY_TARGET}" ]]; then
  echo "ERROR: Failed to obtain recovery target timestamp"
  exit 1
fi

printf '%s\n' "${RECOVERY_TARGET}" > "${TARGET_FILE}"

echo "==> Recovery target recorded:"
echo "${RECOVERY_TARGET}"
echo "==> Saved to: ${TARGET_FILE}"


# ------------------------------------------------------------
# Ensure bad transaction occurs after recovery target
# ------------------------------------------------------------

sleep 3


# ------------------------------------------------------------
# Simulate accidental data loss
# ------------------------------------------------------------

echo "==> Simulating accidental data loss"

vagrant ssh "${PRIMARY_VM}" -c \
  "sudo -u postgres psql -v ON_ERROR_STOP=1 ${DB_NAME} -c 'DELETE FROM customer_orders;'" -- -T


# ------------------------------------------------------------
# Verify deletion
# ------------------------------------------------------------

REMAINING_ROWS="$(
  vagrant ssh "${PRIMARY_VM}" -c \
    "sudo -u postgres psql ${DB_NAME} -Atqc 'SELECT count(*) FROM customer_orders;'" -- -T \
    | tr -d '\r'
)"

if [[ "${REMAINING_ROWS}" != "0" ]]; then
  echo "ERROR: Expected 0 rows after data loss, found '${REMAINING_ROWS}'"
  exit 1
fi

echo "==> Remaining rows: ${REMAINING_ROWS}"


# ------------------------------------------------------------
# Force WAL containing DELETE to archive
# ------------------------------------------------------------

echo "==> Switching and archiving WAL after data loss"

vagrant ssh "${BARMAN_VM}" -c \
  "sudo -u barman barman switch-wal --force --archive --archive-timeout 30 ${SERVER_NAME}" -- -T


echo
echo "========================================="
echo " DATA LOSS SIMULATION: PASS"
echo "========================================="
echo "Database:        ${DB_NAME}"
echo "Rows before:     ${ROW_COUNT}"
echo "Rows after:      ${REMAINING_ROWS}"
echo "Recovery target: ${RECOVERY_TARGET}"