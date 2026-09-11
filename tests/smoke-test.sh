#!/usr/bin/env bash
set -euo pipefail

PRIMARY_VM="pg-primary"
REPLICA_VM="pg-replica"
BARMAN_VM="barman"
RECOVERY_VM="pg-recovery"
SERVER_NAME="pg-primary"

REPLICA_USER="replicator"
REPLICA_ADDRESS="192.168.167.202"
REPLICA_SLOT="pg_replica_slot"
BARMAN_SLOT="barman_wal_slot"

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

psql_query() {
  local vm="$1"
  local sql="$2"
  local database="${3:-postgres}"
  local sql_base64
  sql_base64="$(encode_base64 "${sql}")"

  run_vagrant "${vm}" \
    "echo ${sql_base64} | base64 -d | sudo -u postgres psql -v ON_ERROR_STOP=1 -d ${database} -Atq"
}

test_vm() {
  local vm="$1"

  if ! vagrant ssh "${vm}" -c "hostname" -- -T >/dev/null 2>&1; then
    echo "ERROR: VM '${vm}' is not reachable through Vagrant."
    exit 1
  fi

  echo "    ${vm}: OK"
}

echo
echo "========================================="
echo " INFRASTRUCTURE SMOKE TEST"
echo "========================================="

# ------------------------------------------------------------
# 1. VM reachability
# ------------------------------------------------------------

echo
echo "==> [1/6] Checking VM reachability"

test_vm "${PRIMARY_VM}"
test_vm "${REPLICA_VM}"
test_vm "${BARMAN_VM}"
test_vm "${RECOVERY_VM}"

# ------------------------------------------------------------
# 2. Primary PostgreSQL
# ------------------------------------------------------------

echo
echo "==> [2/6] Checking PostgreSQL primary"

PRIMARY_READY="$(run_vagrant "${PRIMARY_VM}" "pg_isready -q && echo READY")"

if [[ "${PRIMARY_READY}" != "READY" ]]; then
  echo "ERROR: PostgreSQL primary is not accepting connections."
  exit 1
fi

PRIMARY_RECOVERY_STATE="$(psql_query "${PRIMARY_VM}" "SELECT pg_is_in_recovery();")"

if [[ "${PRIMARY_RECOVERY_STATE}" != "f" ]]; then
  echo "ERROR: ${PRIMARY_VM} is unexpectedly in recovery mode."
  exit 1
fi

echo "    PostgreSQL: ready"
echo "    Role: primary"

# ------------------------------------------------------------
# 3. Replica PostgreSQL
# ------------------------------------------------------------

echo
echo "==> [3/6] Checking PostgreSQL replica"

REPLICA_READY="$(run_vagrant "${REPLICA_VM}" "pg_isready -q && echo READY")"

if [[ "${REPLICA_READY}" != "READY" ]]; then
  echo "ERROR: PostgreSQL replica is not accepting connections."
  exit 1
fi

REPLICA_RECOVERY_STATE="$(psql_query "${REPLICA_VM}" "SELECT pg_is_in_recovery();")"

if [[ "${REPLICA_RECOVERY_STATE}" != "t" ]]; then
  echo "ERROR: ${REPLICA_VM} is not operating as a standby."
  exit 1
fi

echo "    PostgreSQL: ready"
echo "    Recovery mode: true"

# ------------------------------------------------------------
# 4. Streaming replication
# ------------------------------------------------------------

echo
echo "==> [4/6] Checking streaming replication"

STREAMING_SQL="$(cat <<SQL
SELECT count(*)
FROM pg_stat_replication
WHERE usename = '${REPLICA_USER}'
  AND client_addr = inet '${REPLICA_ADDRESS}'
  AND state = 'streaming';
SQL
)"

STREAMING_REPLICA_COUNT="$(psql_query "${PRIMARY_VM}" "${STREAMING_SQL}")"

if [[ "${STREAMING_REPLICA_COUNT}" != "1" ]]; then
  echo "ERROR: Expected one streaming replica from ${REPLICA_ADDRESS} using user '${REPLICA_USER}', found '${STREAMING_REPLICA_COUNT}'."
  exit 1
fi

SYNC_STATE_SQL="$(cat <<SQL
SELECT sync_state
FROM pg_stat_replication
WHERE usename = '${REPLICA_USER}'
  AND client_addr = inet '${REPLICA_ADDRESS}'
LIMIT 1;
SQL
)"

REPLICA_SYNC_STATE="$(psql_query "${PRIMARY_VM}" "${SYNC_STATE_SQL}")"

echo "    Replica address: ${REPLICA_ADDRESS}"
echo "    Streaming state: streaming"
echo "    Sync state: ${REPLICA_SYNC_STATE}"

# ------------------------------------------------------------
# 5. Replication slots
# ------------------------------------------------------------

echo
echo "==> [5/6] Checking replication slots"

REPLICA_SLOT_SQL="$(cat <<SQL
SELECT slot_type || ':' || active
FROM pg_replication_slots
WHERE slot_name = '${REPLICA_SLOT}';
SQL
)"

REPLICA_SLOT_STATE="$(psql_query "${PRIMARY_VM}" "${REPLICA_SLOT_SQL}")"

if [[ "${REPLICA_SLOT_STATE}" != "physical:true" ]]; then
  echo "ERROR: Replication slot '${REPLICA_SLOT}' is missing, inactive, or not physical. Current state: '${REPLICA_SLOT_STATE}'"
  exit 1
fi

BARMAN_SLOT_SQL="$(cat <<SQL
SELECT slot_type || ':' || active
FROM pg_replication_slots
WHERE slot_name = '${BARMAN_SLOT}';
SQL
)"

BARMAN_SLOT_STATE="$(psql_query "${PRIMARY_VM}" "${BARMAN_SLOT_SQL}")"

if [[ "${BARMAN_SLOT_STATE}" != "physical:true" ]]; then
  echo "ERROR: Replication slot '${BARMAN_SLOT}' is missing, inactive, or not physical. Current state: '${BARMAN_SLOT_STATE}'"
  exit 1
fi

echo "    ${REPLICA_SLOT}: OK (physical, active)"
echo "    ${BARMAN_SLOT}: OK (physical, active)"

# ------------------------------------------------------------
# 6. Barman + recovery-node baseline state
# ------------------------------------------------------------

echo
echo "==> [6/6] Checking Barman and recovery-node baseline"

BARMAN_CONNECTION="$(
  run_vagrant "${BARMAN_VM}" \
    "sudo -u barman psql 'host=pg-primary port=5432 user=barman dbname=postgres' -Atc 'SELECT 1;'"
)"

if [[ "${BARMAN_CONNECTION}" != "1" ]]; then
  echo "ERROR: Barman cannot connect to ${SERVER_NAME}."
  exit 1
fi

echo "    Barman PostgreSQL connection: OK"

if ! vagrant ssh "${BARMAN_VM}" -c \
  "pgrep -u barman -f 'receive-wal ${SERVER_NAME}' >/dev/null" -- -T; then
  echo "ERROR: Barman receive-wal process is not running."
  exit 1
fi

echo "    Barman receive-wal: running"

# Optional informational status.
# WAL archive may legitimately be FAILED on a fresh deployment
# before the first complete WAL segment has been archived.
vagrant ssh "${BARMAN_VM}" -c \
  "sudo -u barman barman check ${SERVER_NAME} || true" -- -T

RECOVERY_SERVICE_STATE="$(
  run_vagrant "${RECOVERY_VM}" \
    "systemctl is-active postgresql || true"
)"

case "${RECOVERY_SERVICE_STATE}" in
  active)
    echo "    Recovery PostgreSQL: active"
    echo "    Note: recovery node has already been used or manually started"
    ;;
  inactive)
    echo "    Recovery PostgreSQL: inactive"
    echo "    Baseline recovery state: ready for restore"
    ;;
  failed)
    echo "ERROR: PostgreSQL service is in failed state on ${RECOVERY_VM}."
    exit 1
    ;;
  *)
    echo "ERROR: Unexpected PostgreSQL service state on ${RECOVERY_VM}: '${RECOVERY_SERVICE_STATE}'"
    exit 1
    ;;
esac

echo
echo "========================================="
echo " INFRASTRUCTURE SMOKE TEST: PASS"
echo "========================================="
echo "Primary:          OK"
echo "Replica:          streaming (${REPLICA_SYNC_STATE})"
echo "Replica slot:     active"
echo "Barman WAL slot:  active"
echo "Barman:           ready"
echo "Recovery node:    reachable"
echo
echo "Note: backup existence, WAL archival, and PITR results are"
echo "      validated by backup, verify-backup, and verify-recovery workflows."
