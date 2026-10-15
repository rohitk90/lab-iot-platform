
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Configuration
BACKUP_DIR="/var/lib/lab-platform/backups"
DATA_DIR="/var/lib/lab-platform/data"
CONTAINER="lab_timescaledb"
DB_NAME="lab_platform"
DB_USER="lab_admin"
RETENTION_DAYS=30

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_SET="${BACKUP_DIR}/${TIMESTAMP}"
DB_TMP="${BACKUP_SET}/db_dump.dump.tmp"
ARCHIVE_TMP="${BACKUP_SET}/data_backup.tar.gz.tmp"

# Clean up incomplete files if any command fails.
cleanup() {
    rm -f -- "${DB_TMP:-}" "${ARCHIVE_TMP:-}"
}
trap cleanup EXIT

echo "=== Starting Lab Platform Backup: ${TIMESTAMP} ==="

# Preflight checks
command -v docker >/dev/null
command -v tar >/dev/null
command -v pg_restore >/dev/null
docker inspect "${CONTAINER}" >/dev/null
docker exec "${CONTAINER}" pg_isready -U "${DB_USER}" -d "${DB_NAME}" >/dev/null

mkdir -p "${BACKUP_SET}"

# 1. Full logical database backup.
# Custom format includes built-in compression and supports pg_restore.
echo "Creating PostgreSQL/TimescaleDB logical backup..."

docker exec "${CONTAINER}" \
    pg_dump -U "${DB_USER}" -d "${DB_NAME}" -Fc \
    > "${DB_TMP}"

# Validate the dump before accepting it.
pg_restore --list "${DB_TMP}" >/dev/null
mv "${DB_TMP}" "${BACKUP_SET}/db_dump.dump"

# 2. Archive persistent service data.
# TimescaleDB physical files are excluded because the logical dump
# above is the database backup.
echo "Archiving persistent service data..."

tar -czf "${ARCHIVE_TMP}" \
    --exclude='data/timescaledb' \
    -C /var/lib/lab-platform data

tar -tzf "${ARCHIVE_TMP}" >/dev/null
mv "${ARCHIVE_TMP}" "${BACKUP_SET}/data_backup.tar.gz"

# 3. Write a completion marker only after both backups validate.
printf 'Backup completed: %s\nDatabase: %s\n' \
    "${TIMESTAMP}" "${DB_NAME}" \
    > "${BACKUP_SET}/BACKUP_COMPLETE"

# 4. Remove expired complete backup sets.
echo "Applying ${RETENTION_DAYS}-day retention policy..."

find "${BACKUP_DIR}" \
    -mindepth 1 -maxdepth 1 \
    -type d -name '20????????_??????' \
    -mtime "+${RETENTION_DAYS}" \
    -exec rm -rf -- {} +

trap - EXIT
echo "=== Backup Completed Successfully: ${BACKUP_SET} ==="

