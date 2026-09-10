#!/usr/bin/env bash
set -euo pipefail

RECOVERY_VM="pg-recovery"
DB_NAME="recovery_demo"


echo "==> Verifying PostgreSQL recovery result"


# ------------------------------------------------------------
# Verify recovery VM is reachable
# ------------------------------------------------------------

echo "==> Checking ${RECOVERY_VM}"

if ! vagrant ssh "${RECOVERY_VM}" -c "hostname" -- -T >/dev/null 2>&1; then
    echo "ERROR: ${RECOVERY_VM} is not reachable through Vagrant"
    exit 1
fi


# ------------------------------------------------------------
# Verify PostgreSQL service
# ------------------------------------------------------------

echo "==> Checking PostgreSQL service"

SERVICE_STATE="$(
    vagrant ssh "${RECOVERY_VM}" -c \
        "systemctl is-active postgresql" -- -T |
    tr -d '\r'
)"

if [[ "${SERVICE_STATE}" != "active" ]]; then
    echo "ERROR: PostgreSQL service is not active"
    echo "Current state: ${SERVICE_STATE}"
    exit 1
fi

echo "==> PostgreSQL service: active"


# ------------------------------------------------------------
# Verify PostgreSQL accepts connections
# ------------------------------------------------------------

echo "==> Checking PostgreSQL connectivity"

if ! vagrant ssh "${RECOVERY_VM}" -c \
    "pg_isready -q" -- -T; then

    echo "ERROR: PostgreSQL is not accepting connections"
    exit 1
fi

echo "==> PostgreSQL connectivity: OK"


# ------------------------------------------------------------
# Verify recovery has completed
# ------------------------------------------------------------

echo "==> Checking recovery state"

RECOVERY_STATE="$(
    vagrant ssh "${RECOVERY_VM}" -c \
        "sudo -u postgres psql -Atqc 'SELECT pg_is_in_recovery();'" -- -T |
    tr -d '\r'
)"

if [[ "${RECOVERY_STATE}" != "f" ]]; then
    echo "ERROR: PostgreSQL is still in recovery mode"
    echo "pg_is_in_recovery() = ${RECOVERY_STATE}"
    exit 1
fi

echo "==> Recovery state: completed"


# ------------------------------------------------------------
# Verify demo database exists
# ------------------------------------------------------------

echo "==> Checking database ${DB_NAME}"

DATABASE_EXISTS="$(
    vagrant ssh "${RECOVERY_VM}" -c \
        "sudo -u postgres psql -Atqc \"SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}');\"" -- -T |
    tr -d '\r'
)"

if [[ "${DATABASE_EXISTS}" != "t" ]]; then
    echo "ERROR: Database ${DB_NAME} does not exist"
    exit 1
fi

echo "==> Database ${DB_NAME}: found"


# ------------------------------------------------------------
# Verify expected row count
# ------------------------------------------------------------

echo "==> Checking recovered row count"

ROW_COUNT="$(
    vagrant ssh "${RECOVERY_VM}" -c \
        "sudo -u postgres psql ${DB_NAME} -Atqc 'SELECT count(*) FROM customer_orders;'" -- -T |
    tr -d '\r'
)"

if [[ "${ROW_COUNT}" != "3" ]]; then
    echo "ERROR: Expected 3 recovered rows, found '${ROW_COUNT}'"
    exit 1
fi

echo "==> Recovered rows: ${ROW_COUNT}"


# ------------------------------------------------------------
# Verify exact expected demo data
# ------------------------------------------------------------

echo "==> Checking expected demo records"

EXPECTED_ROW_COUNT="$(
    vagrant ssh "${RECOVERY_VM}" -c \
        "sudo -u postgres psql ${DB_NAME} -Atqc \"SELECT count(*) FROM customer_orders WHERE (customer, amount) IN (('Alice',125.50),('Bob',890.00),('Charlie',42.75));\"" -- -T |
    tr -d '\r'
)"

if [[ "${EXPECTED_ROW_COUNT}" != "3" ]]; then
    echo "ERROR: Recovered data does not match expected demo records"
    exit 1
fi

echo "==> Expected demo records: OK"


# ------------------------------------------------------------
# Verify instance is writable
# ------------------------------------------------------------

echo "==> Checking write capability"

if ! vagrant ssh "${RECOVERY_VM}" -c \
    "sudo -u postgres psql -v ON_ERROR_STOP=1 ${DB_NAME} -c '
        BEGIN;
        CREATE TABLE __recovery_write_probe (
            id integer
        );
        ROLLBACK;
    '" -- -T; then

    echo "ERROR: Recovery instance is not writable"
    exit 1
fi

echo "==> Write capability: OK"


# ------------------------------------------------------------
# Display recovered data
# ------------------------------------------------------------

echo "==> Recovered data"

vagrant ssh "${RECOVERY_VM}" -c \
    "sudo -u postgres psql ${DB_NAME} -c 'SELECT id, customer, amount, created_at FROM customer_orders ORDER BY id;'" -- -T


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