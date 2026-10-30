#!/usr/bin/env bash
# ==============================================================================
# LAB IIOT PLATFORM — ONE-TIME STORAGE BOOTSTRAP
#
# Sets up the bind-mount directories for all persistent services with the
# correct ownership for each container's runtime UID. Run this ONCE after
# cloning the repo, or anytime you wipe the data directories.
#
# Usage:
#     sudo ./scripts/bootstrap-storage.sh
#
# Reads DATA_PATH from .env (defaults to /var/lib/lab-platform/data).
# ==============================================================================
set -euo pipefail

# Locate the repo root (this script lives in <repo>/scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load DATA_PATH from .env if present
if [[ -f "${REPO_DIR}/.env" ]]; then
    # shellcheck disable=SC1090
    set -a; source "${REPO_DIR}/.env"; set +a
fi

DATA_PATH="${DATA_PATH:-/var/lib/lab-platform/data}"
LOCAL_BACKUP_DIR="/var/backups/lab-iot"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. Create Data Directory Tree
# ------------------------------------------------------------------------------
echo "==> Creating data directory tree at ${DATA_PATH}..."
mkdir -p \
    "${DATA_PATH}/timescaledb" \
    "${DATA_PATH}/grafana" \
    "${DATA_PATH}/emqx" \
    "${DATA_PATH}/redis" \
    "${DATA_PATH}/minio"

# ------------------------------------------------------------------------------
# 2. Create Local Backup Directory
# ------------------------------------------------------------------------------
echo "==> Creating local backup directory at ${LOCAL_BACKUP_DIR}..."
mkdir -p "${LOCAL_BACKUP_DIR}"
# Assign ownership to the user who invoked sudo, so the backup script 
# (run as a normal user) can write to it.
REAL_USER="${SUDO_USER:-$USER}"
chown -R "${REAL_USER}:${REAL_USER}" "${LOCAL_BACKUP_DIR}"
chmod 700 "${LOCAL_BACKUP_DIR}"

# ------------------------------------------------------------------------------
# 3. Set Correct Ownership Per Service
# ------------------------------------------------------------------------------
# UIDs are the container runtime UIDs, verified against the running images:
#   TimescaleDB (postgres user)   -> 70:70
#   Redis (redis user)            -> 999:999
#   Grafana                       -> 472:472
#   EMQX                          -> 1000:1000
#   MinIO                         -> 1000:1000
echo "==> Setting container data ownership..."
chown -R 70:70      "${DATA_PATH}/timescaledb"
chown -R 999:999    "${DATA_PATH}/redis"
chown -R 472:472    "${DATA_PATH}/grafana"
chown -R 1000:1000  "${DATA_PATH}/emqx"
chown -R 1000:1000  "${DATA_PATH}/minio"

# ------------------------------------------------------------------------------
# 4. Set Restrictive Permissions
# ------------------------------------------------------------------------------
echo "==> Setting permissions..."
chmod -R u+rwX,go-rwx \
    "${DATA_PATH}/timescaledb" \
    "${DATA_PATH}/redis" \
    "${DATA_PATH}/grafana" \
    "${DATA_PATH}/emqx" \
    "${DATA_PATH}/minio"

# ------------------------------------------------------------------------------
# 5. Verify
# ------------------------------------------------------------------------------
echo ""
echo "==> Final state:"
ls -ld \
    "${DATA_PATH}/timescaledb" \
    "${DATA_PATH}/grafana" \
    "${DATA_PATH}/emqx" \
    "${DATA_PATH}/redis" \
    "${DATA_PATH}/minio" \
    "${LOCAL_BACKUP_DIR}"

echo ""
echo "==> bootstrap-storage: done."
echo ""
echo "Next steps:"
echo "  1. Ensure your .env file is populated with strong passwords."
echo "  2. Run: docker compose up -d"
