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

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)." >&2
    exit 1
fi

echo "==> Repo:      ${REPO_DIR}"
echo "==> DATA_PATH: ${DATA_PATH}"
echo ""

# --- Create directory structure ----------------------------------------------
echo "==> Creating directory tree..."
mkdir -p \
    "${DATA_PATH}/timescaledb" \
    "${DATA_PATH}/grafana" \
    "${DATA_PATH}/emqx" \
    "${DATA_PATH}/redis" \
    "${DATA_PATH}/minio"

# --- Set correct ownership per service ---------------------------------------
# UIDs are the container runtime UIDs, taken from each image's docs:
#   TimescaleDB (postgres user)   -> 999:999
#   Redis (redis user)            -> 999:999
#   Grafana                       -> 472:472
#   EMQX                          -> 1000:1000
#   MinIO                         -> 1000:1000

echo "==> Setting ownership..."
chown -R 999:999   "${DATA_PATH}/timescaledb"
chown -R 999:999   "${DATA_PATH}/redis"
chown -R 472:472   "${DATA_PATH}/grafana"
chown -R 1000:1000 "${DATA_PATH}/emqx"
chown -R 1000:1000 "${DATA_PATH}/minio"

# --- Set permissions ---------------------------------------------------------
# Directories need rwx for the owner; files need rw. No world access.
echo "==> Setting permissions..."
chmod -R u+rwX,go-rwx \
    "${DATA_PATH}/timescaledb" \
    "${DATA_PATH}/redis" \
    "${DATA_PATH}/grafana" \
    "${DATA_PATH}/emqx" \
    "${DATA_PATH}/minio"

# --- Verify ------------------------------------------------------------------
echo ""
echo "==> Final state:"
ls -ld \
    "${DATA_PATH}/timescaledb" \
    "${DATA_PATH}/grafana" \
    "${DATA_PATH}/emqx" \
    "${DATA_PATH}/redis" \
    "${DATA_PATH}/minio"

echo ""
echo "==> bootstrap-storage: done."
echo ""
echo "Next steps:"
echo "  1. Edit docker-compose.yml to remove the 'init-permissions' service"
echo "     and every 'depends_on: init-permissions' reference."
echo "  2. docker compose up -d"
