#!/bin/bash

# --- Configuration ---
BACKUP_DIR="/var/lib/lab-platform/backups"
DATA_DIR="/var/lib/lab-platform/data"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RETENTION_DAYS=30

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

echo "=== Starting Lab Platform Backup: $TIMESTAMP ==="

# 1. Database Backup (Logical Dump)
echo "Executing TimescaleDB logical dump..."
docker exec -t lab_timescaledb pg_dump -U lab_admin -d lab_platform --schema=platform_data --schema=public > "$BACKUP_DIR/db_dump_$TIMESTAMP.sql"

# 2. File Infrastructure Backup (MinIO, Grafana, EMQX data configs)
echo "Archiving volume files (MinIO, Grafana, EMQX)..."
tar -czf "$BACKUP_DIR/volumes_backup_$TIMESTAMP.tar.gz" \
    --exclude="$DATA_DIR/timescaledb" \
    "$DATA_DIR"

# 3. Compress the SQL file to save space
gzip "$BACKUP_DIR/db_dump_$TIMESTAMP.sql"

# 4. Enforce Retention Policy (Delete backups older than 30 days)
echo "Cleaning up backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -type f -mtime +$RETENTION_DAYS -delete

echo "=== Backup Completed Successfully ==="
