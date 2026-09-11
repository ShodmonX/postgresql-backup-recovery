#!/usr/bin/env bash
set -euo pipefail

PRIMARY_VM="pg-primary"
BARMAN_VM="barman"
SERVER_NAME="pg-primary"
DB_NAME="recovery_demo"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_FILE="${REPO_ROOT}/.recovery-target"

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

echo "==> Starting data-loss simulation"

# ------------------------------------------------------------
# Verify primary is reachable
# ------------------------------------------------------------

echo "==> Checking ${PRIMARY_VM}"

if ! vagrant ssh "${PRIMARY_VM}" -c "hostname" -- -T >/dev/null 2>&1; then
  echo "ERROR: ${PRIMARY_VM} is not reachable through Vagrant. Run 'vagrant up' first."
  exit 1
fi

# ------------------------------------------------------------
# Verify demo data exists
# ------------------------------------------------------------

echo "==> Verifying demo data"

ROW_COUNT="$(
  run_vagrant "${PRIMARY_VM}" \
    "sudo -u postgres psql ${DB_NAME} -Atqc 'SELECT count(*) FROM customer_orders;'"
)"

if [[ "${ROW_COUNT}" != "3" ]]; then
  echo "ERROR: Expected 3 rows before data-loss simulation, found '${ROW_COUNT}'. Run setup-demo first."
  exit 1
fi

echo "==> Demo rows before data loss: ${ROW_COUNT}"

# ------------------------------------------------------------
# Force WAL boundary before recovery target
# ------------------------------------------------------------

echo "==> Switching WAL before recovery target"
run_vagrant "${PRIMARY_VM}" \
  "sudo -u postgres psql -Atqc 'SELECT pg_switch_wal();'" \
  >/dev/null

# ------------------------------------------------------------
# Record recovery target
# ------------------------------------------------------------

RECOVERY_TARGET="$(
  run_vagrant "${PRIMARY_VM}" \
    "sudo -u postgres psql ${DB_NAME} -Atqc 'SELECT clock_timestamp();'"
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
run_vagrant "${PRIMARY_VM}" \
  "sudo -u postgres psql -v ON_ERROR_STOP=1 ${DB_NAME} -c 'DELETE FROM customer_orders;'"

# ------------------------------------------------------------
# Verify data was deleted
# ------------------------------------------------------------

REMAINING_ROWS="$(
  run_vagrant "${PRIMARY_VM}" \
    "sudo -u postgres psql ${DB_NAME} -Atqc 'SELECT count(*) FROM customer_orders;'"
)"

if [[ "${REMAINING_ROWS}" != "0" ]]; then
  echo "ERROR: Data-loss simulation failed. Expected 0 rows, found '${REMAINING_ROWS}'"
  exit 1
fi

echo "==> Remaining rows: ${REMAINING_ROWS}"

# ------------------------------------------------------------
# Force WAL containing DELETE to archive
# ------------------------------------------------------------

echo "==> Switching and archiving WAL after data loss"
run_vagrant "${BARMAN_VM}" \
  "sudo -u barman barman switch-wal --force --archive --archive-timeout 30 ${SERVER_NAME}"

echo
echo "========================================="
echo " DATA LOSS SIMULATION: PASS"
echo "========================================="
echo "Database:        ${DB_NAME}"
echo "Rows before:     ${ROW_COUNT}"
echo "Rows after:      ${REMAINING_ROWS}"
echo "Recovery target: ${RECOVERY_TARGET}"
