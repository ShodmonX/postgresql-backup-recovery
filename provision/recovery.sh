#!/usr/bin/env bash
set -euo pipefail

echo "==> Provisioning PostgreSQL recovery node on $(hostname)"

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------
# Install PostgreSQL recovery dependencies
# ------------------------------------------------------------

apt-get update

apt-get install -y \
  postgresql-16 \
  postgresql-client-16 \
  rsync


# ------------------------------------------------------------
# Prepare recovery node
# ------------------------------------------------------------

echo "==> Stopping PostgreSQL on recovery node"

systemctl stop postgresql


# ------------------------------------------------------------
# Verification
# ------------------------------------------------------------

if systemctl is-active --quiet postgresql; then
  echo "ERROR: PostgreSQL is still running on recovery node"
  exit 1
fi

echo "==> PostgreSQL recovery node is ready"
echo "==> PostgreSQL recovery provisioning completed"