#!/usr/bin/env bash
set -euo pipefail

VM_NAME="pg-primary"
DB_NAME="recovery_demo"

echo "==> Setting up PITR demo data on ${VM_NAME}"

# ------------------------------------------------------------
# Verify VM is reachable
# ------------------------------------------------------------

if ! vagrant ssh "${VM_NAME}" -c "hostname" >/dev/null 2>&1; then
  echo "ERROR: ${VM_NAME} is not reachable through Vagrant"
  echo "Run 'vagrant up' first."
  exit 1
fi


# ------------------------------------------------------------
# Create demo database if it does not exist
# ------------------------------------------------------------

echo "==> Ensuring database ${DB_NAME} exists"

DB_EXISTS="$(
  vagrant ssh "${VM_NAME}" -c \
    "sudo -u postgres psql -Atqc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}';\"" \
    | tr -d '\r'
)"

if [[ "${DB_EXISTS}" != "1" ]]; then
  echo "==> Creating database ${DB_NAME}"

  vagrant ssh "${VM_NAME}" -c \
    "sudo -u postgres createdb '${DB_NAME}'"
fi


# ------------------------------------------------------------
# Create deterministic demo data
# ------------------------------------------------------------

echo "==> Creating demo table and data"

vagrant ssh "${VM_NAME}" -c \
  "sudo -u postgres psql -v ON_ERROR_STOP=1 '${DB_NAME}' -c \"
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
  \""


# ------------------------------------------------------------
# Verify expected row count
# ------------------------------------------------------------

ROW_COUNT="$(
  vagrant ssh "${VM_NAME}" -c \
    "sudo -u postgres psql '${DB_NAME}' -Atqc 'SELECT count(*) FROM customer_orders;'" \
    | tr -d '\r'
)"

if [[ "${ROW_COUNT}" != "3" ]]; then
  echo "ERROR: Expected 3 demo rows, found ${ROW_COUNT}"
  exit 1
fi


echo
echo "========================================="
echo " DEMO SETUP: PASS"
echo "========================================="
echo "Database: ${DB_NAME}"
echo "Table: customer_orders"
echo "Rows: ${ROW_COUNT}"