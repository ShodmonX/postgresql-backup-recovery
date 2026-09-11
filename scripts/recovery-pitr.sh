#!/usr/bin/env bash
set -euo pipefail

BARMAN_VM="barman"
RECOVERY_VM="pg-recovery"
SERVER_NAME="pg-primary"
DB_NAME="recovery_demo"
RECOVERY_DATA="/var/lib/postgresql/16/main"

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

encode_base64() {
  printf '%s' "$1" | base64 | tr -d '\r\n'
}

# ------------------------------------------------------------
# Read recovery target
# ------------------------------------------------------------

if [[ ! -f "${TARGET_FILE}" ]]; then
  echo "ERROR: ${TARGET_FILE} not found. Run simulate-data-loss.sh first."
  exit 1
fi

RECOVERY_TARGET="$(tr -d '\r\n' < "${TARGET_FILE}")"

if [[ -z "${RECOVERY_TARGET}" ]]; then
  echo "ERROR: Recovery target is empty."
  exit 1
fi

echo "==> Recovery target: ${RECOVERY_TARGET}"

# ------------------------------------------------------------
# Verify required VMs
# ------------------------------------------------------------

for vm in "${BARMAN_VM}" "${RECOVERY_VM}"; do
  echo "==> Checking ${vm}"
  if ! vagrant ssh "${vm}" -c "hostname" -- -T >/dev/null 2>&1; then
    echo "ERROR: ${vm} is not reachable through Vagrant. Run 'vagrant up' first."
    exit 1
  fi
done

# ------------------------------------------------------------
# Process completed WAL segments
# ------------------------------------------------------------

echo "==> Processing completed WAL segments on Barman"
run_vagrant "${BARMAN_VM}" \
  "sudo -u barman barman archive-wal ${SERVER_NAME}" \
  >/dev/null

# ------------------------------------------------------------
# Select latest backup before recovery target
# ------------------------------------------------------------

echo "==> Selecting latest backup before recovery target"

BACKUP_LIST="$(
  run_vagrant "${BARMAN_VM}" \
    "sudo -u barman barman list-backups ${SERVER_NAME} --minimal"
)"

if [[ -z "${BACKUP_LIST}" ]]; then
  echo "ERROR: No Barman backups found."
  exit 1
fi

if ! TARGET_EPOCH="$(date -d "${RECOVERY_TARGET}" +%s 2>/dev/null)"; then
  echo "ERROR: Unable to parse recovery target timestamp '${RECOVERY_TARGET}'"
  exit 1
fi

# Barman backup IDs do not include an explicit timezone. Interpret them using
# the offset carried by PostgreSQL's recovery-target timestamp so selection is
# consistent even when Git Bash runs on a host with a different local timezone.
TARGET_OFFSET="$(printf '%s' "${RECOVERY_TARGET}" | grep -oE '[+-][0-9]{2}(:?[0-9]{2})?$' | tail -n 1 || true)"

BACKUP_ID=""
while IFS= read -r candidate; do
  candidate="$(printf '%s' "${candidate}" | tr -d '\r' | xargs)"

  if [[ ! "${candidate}" =~ ^[0-9]{8}T[0-9]{6}$ ]]; then
    continue
  fi

  candidate_iso="${candidate:0:4}-${candidate:4:2}-${candidate:6:2} ${candidate:9:2}:${candidate:11:2}:${candidate:13:2}"

  candidate_timestamp="${candidate_iso}"
  if [[ -n "${TARGET_OFFSET}" ]]; then
    candidate_timestamp+=" ${TARGET_OFFSET}"
  fi

  if ! candidate_epoch="$(date -d "${candidate_timestamp}" +%s 2>/dev/null)"; then
    continue
  fi

  if (( candidate_epoch <= TARGET_EPOCH )); then
    BACKUP_ID="${candidate}"
    break
  fi
done <<< "${BACKUP_LIST}"

if [[ -z "${BACKUP_ID}" ]]; then
  echo "ERROR: No backup exists before recovery target ${RECOVERY_TARGET}"
  exit 1
fi

echo "==> Selected backup: ${BACKUP_ID}"

# ------------------------------------------------------------
# Ensure Barman SSH key exists
# ------------------------------------------------------------

echo "==> Ensuring Barman SSH key exists"

CREATE_KEY_COMMAND="$(cat <<'REMOTE'
sudo install -d -o barman -g barman -m 700 /var/lib/barman/.ssh

if [ ! -f /var/lib/barman/.ssh/id_ed25519 ]; then
    sudo -u barman ssh-keygen \
        -q \
        -t ed25519 \
        -N '' \
        -f /var/lib/barman/.ssh/id_ed25519
fi

if [ ! -f /var/lib/barman/.ssh/id_ed25519.pub ]; then
    sudo -u barman sh -c \
        'ssh-keygen -y -f /var/lib/barman/.ssh/id_ed25519 > /var/lib/barman/.ssh/id_ed25519.pub'
fi
REMOTE
)"

CREATE_KEY_BASE64="$(encode_base64 "${CREATE_KEY_COMMAND}")"
run_vagrant "${BARMAN_VM}" \
  "echo ${CREATE_KEY_BASE64} | base64 -d | sudo bash" \
  >/dev/null

# ------------------------------------------------------------
# Retrieve public key
# ------------------------------------------------------------

echo "==> Retrieving Barman SSH public key"

PUBLIC_KEY_OUTPUT="$(
  run_vagrant "${BARMAN_VM}" \
    "sudo -u barman cat /var/lib/barman/.ssh/id_ed25519.pub"
)"

PUBLIC_KEY="$(printf '%s\n' "${PUBLIC_KEY_OUTPUT}" | grep '^ssh-ed25519 ' | sed -n '1p')"

if [[ -z "${PUBLIC_KEY}" ]]; then
  echo "ERROR: Barman SSH public key was not returned."
  exit 1
fi

# ------------------------------------------------------------
# Install key on recovery node
# ------------------------------------------------------------

echo "==> Installing Barman public key on ${RECOVERY_VM}"

INSTALL_KEY_COMMAND="$(cat <<EOF2
sudo install -d \\
    -o postgres \\
    -g postgres \\
    -m 700 \\
    /var/lib/postgresql/.ssh

sudo touch /var/lib/postgresql/.ssh/authorized_keys

sudo grep -qxF '${PUBLIC_KEY}' \\
    /var/lib/postgresql/.ssh/authorized_keys \\
    || echo '${PUBLIC_KEY}' \\
    | sudo tee -a /var/lib/postgresql/.ssh/authorized_keys >/dev/null

sudo chown postgres:postgres \\
    /var/lib/postgresql/.ssh/authorized_keys

sudo chmod 600 \\
    /var/lib/postgresql/.ssh/authorized_keys
EOF2
)"

INSTALL_KEY_BASE64="$(encode_base64 "${INSTALL_KEY_COMMAND}")"
run_vagrant "${RECOVERY_VM}" \
  "echo ${INSTALL_KEY_BASE64} | base64 -d | sudo bash" \
  >/dev/null

# ------------------------------------------------------------
# Register recovery host key on Barman
# ------------------------------------------------------------

echo "==> Registering ${RECOVERY_VM} SSH host key"

KNOWN_HOSTS_COMMAND="$(cat <<EOF2
sudo -u barman touch /var/lib/barman/.ssh/known_hosts

sudo -u barman ssh-keygen \\
    -R ${RECOVERY_VM} \\
    -f /var/lib/barman/.ssh/known_hosts \\
    >/dev/null 2>&1 || true

sudo -u barman sh -c \\
    'ssh-keyscan -H ${RECOVERY_VM} >> /var/lib/barman/.ssh/known_hosts'

sudo chmod 600 /var/lib/barman/.ssh/known_hosts
EOF2
)"

KNOWN_HOSTS_BASE64="$(encode_base64 "${KNOWN_HOSTS_COMMAND}")"
run_vagrant "${BARMAN_VM}" \
  "echo ${KNOWN_HOSTS_BASE64} | base64 -d | sudo bash" \
  >/dev/null

# ------------------------------------------------------------
# Verify Barman -> recovery SSH
# ------------------------------------------------------------

echo "==> Verifying Barman -> ${RECOVERY_VM} SSH"

REMOTE_HOSTNAME="$(
  run_vagrant "${BARMAN_VM}" \
    "sudo -u barman ssh -o BatchMode=yes -o StrictHostKeyChecking=yes postgres@${RECOVERY_VM} hostname"
)"

if [[ "${REMOTE_HOSTNAME}" != "${RECOVERY_VM}" ]]; then
  echo "ERROR: Unexpected SSH verification response: '${REMOTE_HOSTNAME}'"
  exit 1
fi

echo "==> SSH verification OK"

# ------------------------------------------------------------
# Prepare recovery node
# ------------------------------------------------------------

echo "==> Preparing PostgreSQL recovery node"

PREPARE_RECOVERY_COMMAND="$(cat <<EOF2
sudo systemctl stop postgresql

if systemctl is-active --quiet postgresql; then
    echo 'ERROR: PostgreSQL is still running'
    exit 1
fi

sudo rm -rf '${RECOVERY_DATA}'

sudo install \\
    -d \\
    -o postgres \\
    -g postgres \\
    -m 700 \\
    '${RECOVERY_DATA}'
EOF2
)"

PREPARE_BASE64="$(encode_base64 "${PREPARE_RECOVERY_COMMAND}")"
run_vagrant "${RECOVERY_VM}" \
  "echo ${PREPARE_BASE64} | base64 -d | sudo bash" \
  >/dev/null

# ------------------------------------------------------------
# Perform Barman PITR
# ------------------------------------------------------------

echo "==> Starting Barman PITR"

RECOVER_COMMAND="sudo -u barman barman recover --remote-ssh-command 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes postgres@${RECOVERY_VM}' --target-time '${RECOVERY_TARGET}' --target-action pause --no-get-wal ${SERVER_NAME} '${BACKUP_ID}' '${RECOVERY_DATA}'"
run_vagrant "${BARMAN_VM}" "${RECOVER_COMMAND}"

# ------------------------------------------------------------
# Start recovered PostgreSQL
# ------------------------------------------------------------

echo "==> Starting recovered PostgreSQL"
run_vagrant "${RECOVERY_VM}" \
  "sudo systemctl start postgresql" \
  >/dev/null

# ------------------------------------------------------------
# Wait until PITR target is reached
# ------------------------------------------------------------

echo "==> Waiting for PostgreSQL to reach PITR target"

WAIT_COMMAND="$(cat <<'REMOTE'
for i in $(seq 1 60); do
    state=$(sudo -u postgres psql -Atqc "SELECT pg_is_wal_replay_paused();" 2>/dev/null || true)

    if [ "$state" = "t" ]; then
        echo PITR_PAUSED
        exit 0
    fi

    sleep 1
done

echo PITR_TIMEOUT
exit 1
REMOTE
)"

WAIT_BASE64="$(encode_base64 "${WAIT_COMMAND}")"

if ! WAIT_OUTPUT="$(
  run_vagrant "${RECOVERY_VM}" \
    "echo ${WAIT_BASE64} | base64 -d | bash"
)"; then
  echo "==> PostgreSQL did not reach PITR target"
  vagrant ssh "${RECOVERY_VM}" -c \
    "sudo tail -n 100 /var/log/postgresql/postgresql-16-main.log" -- -T || true
  echo "ERROR: Recovery target was not reached within timeout."
  exit 1
fi

if ! printf '%s\n' "${WAIT_OUTPUT}" | grep -Fxq "PITR_PAUSED"; then
  echo "ERROR: Unexpected PITR wait result."
  exit 1
fi

echo "==> Recovery reached target and WAL replay is paused"

# ------------------------------------------------------------
# Verify recovered demo data before promotion
# ------------------------------------------------------------

echo "==> Verifying recovered demo data"

RECOVERED_ROWS="$(
  run_vagrant "${RECOVERY_VM}" \
    "sudo -u postgres psql ${DB_NAME} -Atqc 'SELECT count(*) FROM customer_orders;'"
)"

if [[ "${RECOVERED_ROWS}" != "3" ]]; then
  echo "ERROR: Expected 3 recovered rows, found '${RECOVERED_ROWS}'"
  vagrant ssh "${RECOVERY_VM}" -c \
    "sudo -u postgres psql ${DB_NAME} -c 'SELECT id, customer, amount, created_at FROM customer_orders ORDER BY id;'" -- -T || true
  echo "ERROR: PITR verification failed."
  exit 1
fi

run_vagrant "${RECOVERY_VM}" \
  "sudo -u postgres psql ${DB_NAME} -c 'SELECT id, customer, amount, created_at FROM customer_orders ORDER BY id;'"

# ------------------------------------------------------------
# Resume replay and promote
# ------------------------------------------------------------

echo "==> Resuming WAL replay"
run_vagrant "${RECOVERY_VM}" \
  "sudo -u postgres psql -c 'SELECT pg_wal_replay_resume();'" \
  >/dev/null

echo "==> Waiting for recovery completion"

PROMOTION_WAIT_COMMAND="$(cat <<'REMOTE'
for i in $(seq 1 30); do
    state=$(sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null || true)

    if [ "$state" = "f" ]; then
        echo PROMOTED
        exit 0
    fi

    sleep 1
done

echo PROMOTION_TIMEOUT
exit 1
REMOTE
)"

PROMOTION_BASE64="$(encode_base64 "${PROMOTION_WAIT_COMMAND}")"

if ! PROMOTION_OUTPUT="$(
  run_vagrant "${RECOVERY_VM}" \
    "echo ${PROMOTION_BASE64} | base64 -d | bash"
)"; then
  vagrant ssh "${RECOVERY_VM}" -c \
    "sudo tail -n 100 /var/log/postgresql/postgresql-16-main.log" -- -T || true
  echo "ERROR: Recovery node was not promoted within timeout."
  exit 1
fi

if ! printf '%s\n' "${PROMOTION_OUTPUT}" | grep -Fxq "PROMOTED"; then
  echo "ERROR: Unexpected promotion result."
  exit 1
fi

# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

RECOVERY_STATE="$(
  run_vagrant "${RECOVERY_VM}" \
    "sudo -u postgres psql -Atqc 'SELECT pg_is_in_recovery();'"
)"

if [[ "${RECOVERY_STATE}" != "f" ]]; then
  echo "ERROR: Recovery node is still in recovery mode."
  exit 1
fi

echo
echo "========================================="
echo " PITR WORKFLOW: PASS"
echo "========================================="
echo "Backup:          ${BACKUP_ID}"
echo "Recovery target: ${RECOVERY_TARGET}"
echo "Recovered rows:  ${RECOVERED_ROWS}"
echo "Recovery node:   ${RECOVERY_VM}"
echo "Status:          promoted and writable"
