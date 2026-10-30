#!/usr/bin/env bash
# ==============================================================================
# LAB IIOT PLATFORM - RESTORE FROM A LOCAL BACKUP SET
#
# Usage:  ./scripts/restore-db.sh /var/backups/lab-iot/20261030_180000
#
# This is destructive. It drops the existing platform_data schema, then
# re-creates it from the backup. It does NOT delete the whole database, only
# the schema that the backup covers.
# ==============================================================================

set -Eeuo pipefail

BACKUP_SET="${1:-}"
CONTAINER="lab_timescaledb"
DB_NAME="lab_platform"
DB_USER="lab_admin"

if [[ -z "${BACKUP_SET}" ]] || [[ ! -d "${BACKUP_SET}" ]]; then
    echo "Usage: $0 /path/to/backup_set" >&2
    exit 1
fi

# Verify the backup set is complete
if [[ ! -f "${BACKUP_SET}/BACKUP_COMPLETE" ]]; then
    echo "ERROR: ${BACKUP_SET} is not a complete backup (no BACKUP_COMPLETE marker)." >&2
    exit 1
fi

# Verify checksums
echo "==> Verifying checksums..."
(cd "${BACKUP_SET}" && sha256sum -c MANIFEST.sha256) \
    || { echo "ERROR: Checksum verification failed. Do NOT restore this backup." >&2; exit 1; }

DB_DUMP="${BACKUP_SET}/db_dump.dump"
GLOBALS="${BACKUP_SET}/cluster_globals.sql"
ARCHIVE="${BACKUP_SET}/data_backup.tar.gz"

for f in "${DB_DUMP}" "${GLOBALS}" "${ARCHIVE}"; do
    [[ -f "${f}" ]] || { echo "ERROR: Missing file ${f}" >&2; exit 1; }
done

echo ""
echo "WARNING: This will DROP and RECREATE platform_data in database ${DB_NAME}."
echo "         Backup set: ${BACKUP_SET}"
read -r -p "Type 'RESTORE' to proceed: " CONFIRM
[[ "${CONFIRM}" == "RESTORE" ]] || { echo "Aborted."; exit 1; }

# --- Restore database ---------------------------------------------------------
echo "==> Dropping existing platform_data schema..."
docker exec -i "${CONTAINER}" psql -U "${DB_USER}" -d "${DB_NAME}" \
    -c "DROP SCHEMA IF EXISTS platform_data CASCADE;"

echo "==> Restoring database from ${DB_DUMP}..."
docker exec -i "${CONTAINER}" pg_restore \
    -U "${DB_USER}" \
    -d "${DB_NAME}" \
    --no-owner \
    --no-privileges \
    < "${DB_DUMP}"

echo "==> Restored platform_data."

# --- Restore globals (optional; may require superuser) ------------------------
echo "==> Cluster globals backup is at ${GLOBALS}."
echo "    Restore manually if needed:"
echo "    docker exec -i ${CONTAINER} psql -U postgres < ${GLOBALS}"

# --- Restore other service data ----------------------------------------------
echo ""
read -r -p "Also restore ${ARCHIVE} into /var/lib/lab-platform? [y/N] " RESTORE_ARCHIVE
if [[ "${RESTORE_ARCHIVE,,}" == "y" ]]; then
    echo "==> Stopping dependent containers..."
    docker compose stop grafana emqx redis minio
    echo "==> Restoring archive..."
    tar -xzf "${ARCHIVE}" -C /var/lib/lab-platform
    echo "==> Restarting containers..."
    docker compose start grafana emqx redis minio
fi

echo ""
echo "=== Restore complete. Verify with: ==="
echo "    docker exec -it ${CONTAINER} psql -U ${DB_USER} -d ${DB_NAME} -c '\\dt platform_data.*'"
