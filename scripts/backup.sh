#!/usr/bin/env bash
# ==============================================================================
# LAB IIOT PLATFORM - LOCAL BACKUP SCRIPT
# ==============================================================================

set -Eeuo pipefail
umask 077

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
BACKUP_DIR="/var/backups/lab-iot"
DATA_DIR="/var/lib/lab-platform/data"
CONTAINER="lab_timescaledb"
DB_NAME="lab_platform"
DB_USER="lab_admin"
RETENTION_DAYS=7
MIN_FREE_GB=20

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_SET="${BACKUP_DIR}/${TIMESTAMP}"

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
echo "=== Lab Platform Backup: ${TIMESTAMP} ==="

if [[ ! -d "${BACKUP_DIR}" ]]; then
    echo "ERROR: Backup directory ${BACKUP_DIR} does not exist." >&2
    echo "Run: sudo mkdir -p ${BACKUP_DIR} && sudo chown \$USER:\$USER ${BACKUP_DIR}" >&2
    exit 1
fi

if [[ ! -w "${BACKUP_DIR}" ]]; then
    echo "ERROR: Backup directory ${BACKUP_DIR} is not writable by $(whoami)." >&2
    exit 1
fi

BACKUP_MOUNT="$(df --output=target "${BACKUP_DIR}" | tail -1)"
AVAILABLE_GB="$(df --output=avail -BG "${BACKUP_DIR}" | tail -1 | tr -d 'G ')"
if (( AVAILABLE_GB < MIN_FREE_GB )); then
    echo "ERROR: Only ${AVAILABLE_GB}GB free on ${BACKUP_MOUNT}, need ${MIN_FREE_GB}GB." >&2
    exit 1
fi
echo "==> Destination: ${BACKUP_DIR} (mount: ${BACKUP_MOUNT}, ${AVAILABLE_GB}GB free)"

for cmd in docker tar pg_restore sha256sum; do
    command -v "$cmd" >/dev/null || { echo "ERROR: Missing tool: $cmd" >&2; exit 1; }
done

docker inspect "${CONTAINER}" >/dev/null
docker exec "${CONTAINER}" pg_isready -U "${DB_USER}" -d "${DB_NAME}" >/dev/null
echo "==> Database is reachable."

# ------------------------------------------------------------------------------
# Prepare
# ------------------------------------------------------------------------------
mkdir -p "${BACKUP_SET}"
DB_DUMP="${BACKUP_SET}/db_dump.dump"
ARCHIVE="${BACKUP_SET}/data_backup.tar.gz"
GLOBALS="${BACKUP_SET}/cluster_globals.sql"
MANIFEST="${BACKUP_SET}/MANIFEST.sha256"
MARKER="${BACKUP_SET}/BACKUP_COMPLETE"

cleanup_on_fail() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "ERROR: Backup failed (rc=${rc}). Removing incomplete set ${BACKUP_SET}." >&2
        sudo rm -rf -- "${BACKUP_SET}"
    fi
}
trap cleanup_on_fail EXIT

# ------------------------------------------------------------------------------
# 1. Cluster globals
# ------------------------------------------------------------------------------
echo "==> Dumping cluster globals..."
docker exec "${CONTAINER}" pg_dumpall -U "${DB_USER}" --globals-only > "${GLOBALS}"
[[ -s "${GLOBALS}" ]] || { echo "ERROR: Globals dump is empty." >&2; exit 1; }

# ------------------------------------------------------------------------------
# 2. Database dump
# ------------------------------------------------------------------------------
echo "==> Dumping database..."
docker exec "${CONTAINER}" pg_dump -U "${DB_USER}" -d "${DB_NAME}" -Fc > "${DB_DUMP}"

pg_restore --list "${DB_DUMP}" > /dev/null \
    || { echo "ERROR: Database dump failed validation." >&2; exit 1; }
echo "    Validated: ${DB_DUMP} ($(du -h "${DB_DUMP}" | cut -f1))"

# ------------------------------------------------------------------------------
# 3. Archive service data (sudo required for container-owned directories)
# ------------------------------------------------------------------------------
echo "==> Archiving persistent service data..."
sudo tar -czf "${ARCHIVE}" \
    --exclude='data/timescaledb' \
    -C "$(dirname "${DATA_DIR}")" "$(basename "${DATA_DIR}")"
sudo chown "${USER}:${USER}" "${ARCHIVE}"

tar -tzf "${ARCHIVE}" > /dev/null \
    || { echo "ERROR: Archive failed validation." >&2; exit 1; }
echo "    Validated: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"

# ------------------------------------------------------------------------------
# 4. Checksums + manifest
# ------------------------------------------------------------------------------
echo "==> Generating SHA-256 checksums..."
(
    cd "${BACKUP_SET}"
    sha256sum "$(basename "${GLOBALS}")" \
              "$(basename "${DB_DUMP}")" \
              "$(basename "${ARCHIVE}")" \
        > "$(basename "${MANIFEST}")"
)
echo "    Manifest: ${MANIFEST}"

# ------------------------------------------------------------------------------
# 5. Completion marker
# ------------------------------------------------------------------------------
{
    echo "Backup completed: ${TIMESTAMP}"
    echo "Database:        ${DB_NAME}"
    echo "Globals:         $(basename "${GLOBALS}")"
    echo "DB dump:         $(basename "${DB_DUMP}")"
    echo "Archive:         $(basename "${ARCHIVE}")"
    echo "Manifest:        $(basename "${MANIFEST}")"
    echo "Retention:       ${RETENTION_DAYS} days"
} > "${MARKER}"

trap - EXIT
echo "==> Backup set complete: ${BACKUP_SET}"

# ------------------------------------------------------------------------------
# 6. Retention (removes only old sets with a completion marker)
# ------------------------------------------------------------------------------
echo "==> Applying ${RETENTION_DAYS}-day retention policy..."
REMOVED=0
while IFS= read -r -d '' OLD_SET; do
    [[ "${OLD_SET}" == "${BACKUP_SET}" ]] && continue
    if [[ -f "${OLD_SET}/BACKUP_COMPLETE" ]]; then
        rm -rf -- "${OLD_SET}"
        REMOVED=$((REMOVED + 1))
    fi
done < <(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d \
           -name '20????????_??????' -mtime "+${RETENTION_DAYS}" -print0)
echo "    Removed ${REMOVED} expired backup set(s)."

echo "=== Backup Completed Successfully: ${BACKUP_SET} ==="
