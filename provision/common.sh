#!/usr/bin/env bash

set -euo pipefail

echo "==> Running common provisioning on $(hostname)"

export DEBIAN_FRONTEND=noninteractive

# Refresh package metadata only.
apt-get update -y

# Minimal utilities required by later provisioning and verification.
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  vim \
  jq

# Use the same timezone on every node.
timedatectl set-timezone Asia/Tashkent

# Internal host-only network name resolution.
HOSTS_BLOCK='
192.168.167.201 pg-primary
192.168.167.202 pg-replica
192.168.167.210 barman
192.168.167.220 pg-recovery
'

# Keep provisioning idempotent.
sed -i '/# BEGIN POSTGRESQL-BACKUP-RECOVERY/,/# END POSTGRESQL-BACKUP-RECOVERY/d' /etc/hosts

cat >> /etc/hosts <<EOF

# BEGIN POSTGRESQL-BACKUP-RECOVERY
${HOSTS_BLOCK}
# END POSTGRESQL-BACKUP-RECOVERY
EOF

echo "==> Common provisioning completed on $(hostname)"