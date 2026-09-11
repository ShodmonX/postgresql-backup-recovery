#!/usr/bin/env bash
set -euo pipefail

RECOVERY_VM="pg-recovery"
DB_NAME="recovery_demo"

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

echo "==> Verifying PostgreSQL recovery result"

# ------------------------------------------------------------
# Verify recovery VM is reachable
# ------------------------------------------------------------

echo "==> Checking ${RECOVERY_VM}"

if ! vagrant ssh "${RECOVERY_VM}" -c "hostname" -- -T >/dev/null 2>&1; then
  echo "ERROR: ${RECOVERY_VM} is not reachable through Vagrant."
  exit 1
fi

# ------------------------------------------------------------
# Verify PostgreSQL service
# ------------------------------------------------------------

echo "==> Checking PostgreSQL service"

SERVICE_STATE="$(run_vagrant "${RECOVERY_VM}" "systemctl is-active postgresql")"

if [[ "${SERVICE_STATE}" != "active" ]]; then
  echo "ERROR: PostgreSQL service is not active. Current state: '${SERVICE_STATE}'"
  exit 1
fi

echo "==> PostgreSQL service: active"

# ------------------------------------------------------------
# Verify PostgreSQL accepts connections
# ------------------------------------------------------------

echo "==> Checking PostgreSQL connectivity"

PG_READY="$(run_vagrant "${RECOVERY_VM}" "pg_isready -q && echo READY")"

if [[ "${PG_READY}" != "READY" ]]; then
  echo "ERROR: PostgreSQL is not accepting connections."
  exit 1
fi

echo "==> PostgreSQL connectivity: OK"

# ------------------------------------------------------------
# Verify recovery has completed
# ------------------------------------------------------------

echo "==> Checking recovery state"

RECOVERY_STATE="$(
  run_vagrant "${RECOVERY_VM}" \
    "sudo -u postgres psql -Atqc 'SELECT pg_is_in_recovery();'"
)"

if [[ "${RECOVERY_STATE}" != "f" ]]; then
  echo "ERROR: PostgreSQL is still in recovery mode. pg_is_in_recovery() = '${RECOVERY_STATE}'"
  exit 1
fi

echo "==> Recovery state: completed"

# ------------------------------------------------------------
# Verify demo database exists
# ------------------------------------------------------------

echo "==> Checking database ${DB_NAME}"

DATABASE_LIST="$(
  run_vagrant "${RECOVERY_VM}" \
    "sudo -u postgres psql -Atqc 'SELECT datname FROM pg_database;'"
)"

if ! printf '%s\n' "${DATABASE_LIST}" | grep -Fxq "${DB_NAME}"; then
  echo "ERROR: Database '${DB_NAME}' does not exist on ${RECOVERY_VM}."
  exit 1
fi

echo "==> Database ${DB_NAME}: found"

# ------------------------------------------------------------
# Verify expected row count
# ------------------------------------------------------------

echo "==> Checking recovered row count"

ROW_COUNT="$(
  run_vagrant "${RECOVERY_VM}" \
    "sudo -u postgres psql ${DB_NAME} -Atqc 'SELECT count(*) FROM customer_orders;'"
)"

if [[ "${ROW_COUNT}" != "3" ]]; then
  echo "ERROR: Expected 3 recovered rows, found '${ROW_COUNT}'."
  exit 1
fi

echo "==> Recovered rows: ${ROW_COUNT}"

# ------------------------------------------------------------
# Verify exact expected demo data
# ------------------------------------------------------------

echo "==> Checking expected demo records"

EXPECTED_DATA_SQL="$(cat <<'SQL'
SELECT count(*)
FROM customer_orders
WHERE (customer, amount) IN (
    ('Alice', 125.50),
    ('Bob', 890.00),
    ('Charlie', 42.75)
);
SQL
)"

EXPECTED_DATA_BASE64="$(encode_base64 "${EXPECTED_DATA_SQL}")"
EXPECTED_ROW_COUNT="$(
  run_vagrant "${RECOVERY_VM}" \
    "echo ${EXPECTED_DATA_BASE64} | base64 -d | sudo -u postgres psql ${DB_NAME} -Atq"
)"

if [[ "${EXPECTED_ROW_COUNT}" != "3" ]]; then
  echo "ERROR: Recovered data does not match the expected demo records."
  exit 1
fi

echo "==> Expected demo records: OK"

# ------------------------------------------------------------
# Verify instance is writable
# ------------------------------------------------------------

echo "==> Checking write capability"

WRITE_TEST_COMMAND="$(cat <<EOF2
sudo -u postgres psql -v ON_ERROR_STOP=1 ${DB_NAME} -c '
BEGIN;
CREATE TABLE __recovery_write_probe (
    id integer
);
ROLLBACK;
'
EOF2
)"

WRITE_TEST_BASE64="$(encode_base64 "${WRITE_TEST_COMMAND}")"

if ! vagrant ssh "${RECOVERY_VM}" -c \
  "echo ${WRITE_TEST_BASE64} | base64 -d | bash" -- -T; then
  echo "ERROR: Recovery instance is not writable."
  exit 1
fi

echo "==> Write capability: OK"

# ------------------------------------------------------------
# Display recovered data
# ------------------------------------------------------------

echo "==> Recovered data"
run_vagrant "${RECOVERY_VM}" \
  "sudo -u postgres psql ${DB_NAME} -c 'SELECT id, customer, amount, created_at FROM customer_orders ORDER BY id;'"

# ------------------------------------------------------------
# Final result
# ------------------------------------------------------------

echo
echo "========================================="
echo " RECOVERY VERIFICATION: PASS"
echo "========================================="
echo "Node:            ${RECOVERY_VM}"
echo "PostgreSQL:      active"
echo "Recovery mode:   false"
echo "Database:        ${DB_NAME}"
echo "Recovered rows:  ${ROW_COUNT}"
echo "Expected data:   verified"
echo "Writable:        yes"
