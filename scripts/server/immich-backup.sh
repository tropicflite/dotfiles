#!/bin/bash

set -euo pipefail

LOCKFILE=/tmp/immich-backup.lock

if [ -e "$LOCKFILE" ]; then
    echo "[$(date)] Backup already running (lockfile exists). Exiting."
    exit 1
fi

trap "rm -f $LOCKFILE" EXIT
touch $LOCKFILE

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DUMP_DIR="/tmp/immich-backup"
DUMP_FILE="$DUMP_DIR/immich_${TIMESTAMP}.sql.gz"
RCLONE_REMOTE="proton:backups/immich"
RETENTION_DAYS=7

mkdir -p "$DUMP_DIR"

echo "[$(date)] Starting Immich backup..."

# Dump Postgres
echo "[$(date)] Dumping Postgres..."
docker exec immich_postgres pg_dumpall -U postgres | gzip > "$DUMP_FILE"

# Sync photo library
echo "[$(date)] Syncing photo library..."
rclone sync /mnt/data/immich/library "$RCLONE_REMOTE/library" \
    --transfers=4 \
    --checkers=8 \
    --log-level INFO

# Sync DB dump
echo "[$(date)] Syncing DB dump..."
rclone copy "$DUMP_FILE" "$RCLONE_REMOTE/postgres" \
    --log-level INFO

# Clean up old local dumps
echo "[$(date)] Cleaning up local dumps older than ${RETENTION_DAYS} days..."
find "$DUMP_DIR" -name "*.sql.gz" -mtime +${RETENTION_DAYS} -delete

# Clean up old remote dumps
echo "[$(date)] Pruning remote dumps older than ${RETENTION_DAYS} days..."
rclone delete "$RCLONE_REMOTE/postgres" \
    --min-age "${RETENTION_DAYS}d" \
    --log-level INFO

echo "[$(date)] Backup complete."
