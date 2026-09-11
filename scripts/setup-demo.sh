#!/usr/bin/env bash
set -euo pipefail

VM_NAME="pg-primary"
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

echo "==> Setting up PITR demo data on ${VM_NAME}"

# ------------------------------------------------------------
# Verify VM is reachable
# ------------------------------------------------------------

echo "==> Checking ${VM_NAME}"

if ! vagrant ssh "${VM_NAME}" -c "hostname" -- -T >/dev/null 2>&1; then
  echo "ERROR: ${VM_NAME} is not reachable through Vagrant. Run 'vagrant up' first."
  exit 1
fi

# ------------------------------------------------------------
# Create demo database if it does not exist
# ------------------------------------------------------------

echo "==> Ensuring database ${DB_NAME} exists"

DB_LIST="$(run_vagrant "${VM_NAME}" "sudo -u postgres psql -Atqc 'SELECT datname FROM pg_database;'")"

if ! printf '%s\n' "${DB_LIST}" | grep -Fxq "${DB_NAME}"; then
  echo "==> Creating database ${DB_NAME}"
  run_vagrant "${VM_NAME}" "sudo -u postgres createdb ${DB_NAME}" >/dev/null
fi

# ------------------------------------------------------------
# Create deterministic demo data
# ------------------------------------------------------------

echo "==> Creating demo table and data"

SETUP_SQL="$(cat <<'SQL'
CREATE TABLE IF NOT EXISTS customer_orders (
    id bigserial PRIMARY KEY,
    customer text NOT NULL,
    amount numeric(12,2) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

TRUNCATE TABLE customer_orders RESTART IDENTITY;

INSERT INTO customer_orders (customer, amount)
VALUES
    ('Alice', 125.50),
    ('Bob', 890.00),
    ('Charlie', 42.75);

SELECT * FROM customer_orders ORDER BY id;
SQL
)"

SQL_BASE64="$(encode_base64 "${SETUP_SQL}")"
run_vagrant "${VM_NAME}" \
  "echo ${SQL_BASE64} | base64 -d | sudo -u postgres psql -v ON_ERROR_STOP=1 ${DB_NAME}"

# ------------------------------------------------------------
# Verify expected row count
# ------------------------------------------------------------

ROW_COUNT="$(
  run_vagrant "${VM_NAME}" \
    "sudo -u postgres psql ${DB_NAME} -Atqc 'SELECT count(*) FROM customer_orders;'"
)"

if [[ "${ROW_COUNT}" != "3" ]]; then
  echo "ERROR: Expected 3 demo rows, found '${ROW_COUNT}'"
  exit 1
fi

echo
echo "========================================="
echo " DEMO SETUP: PASS"
echo "========================================="
echo "Database: ${DB_NAME}"
echo "Table: customer_orders"
echo "Rows: ${ROW_COUNT}"
