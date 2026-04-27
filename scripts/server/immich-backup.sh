#!/bin/bash
set -euo pipefail

LOCKFILE=/tmp/immich-backup.lock
RCLONE_REMOTE="proton:backups/immich"
DUMP_DIR="/tmp/immich-backup"
RETENTION_DAYS=7

# PID-aware lockfile check
if [ -e "$LOCKFILE" ]; then
    OLD_PID=$(cat "$LOCKFILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[$(date)] Backup already running (PID $OLD_PID). Exiting."
        exit 1
    else
        echo "[$(date)] Stale lockfile found (PID $OLD_PID dead), removing."
        rm -f "$LOCKFILE"
    fi
fi

echo $$ > "$LOCKFILE"
trap "rm -f $LOCKFILE" EXIT

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DUMP_FILE="$DUMP_DIR/immich_${TIMESTAMP}.sql.gz"

mkdir -p "$DUMP_DIR"
echo "[$(date)] Starting Immich backup..."

# Dump Postgres
echo "[$(date)] Dumping Postgres..."
docker exec immich_postgres pg_dumpall -U postgres | gzip > "$DUMP_FILE"

# Stop VPN before rclone (Proton blocks VPN IPs)
echo "[$(date)] Stopping WireGuard VPN..."
sudo systemctl stop wg-watchdog wg0

# Sync photo library
echo "[$(date)] Syncing photo library..."
rclone sync /mnt/data/immich/library "$RCLONE_REMOTE/library" \
    --transfers=4 \
    --checkers=8 \
    --fast-list \
    --log-level INFO || echo "[$(date)] WARNING: rclone sync exited with non-zero status $?"

# Sync DB dump
echo "[$(date)] Syncing DB dump..."
rclone copy "$DUMP_FILE" "$RCLONE_REMOTE/postgres" \
    --fast-list \
    --log-level INFO || echo "[$(date)] WARNING: rclone copy exited with non-zero status $?"

# Restart VPN
echo "[$(date)] Restarting WireGuard VPN..."
sudo systemctl start wg-watchdog

# Clean up old local dumps
echo "[$(date)] Cleaning up local dumps older than ${RETENTION_DAYS} days..."
find "$DUMP_DIR" -name "*.sql.gz" -mtime +${RETENTION_DAYS} -delete

# Clean up old remote dumps
echo "[$(date)] Pruning remote dumps older than ${RETENTION_DAYS} days..."
rclone delete "$RCLONE_REMOTE/postgres" \
    --min-age "${RETENTION_DAYS}d" \
    --fast-list \
    --log-level INFO || echo "[$(date)] WARNING: rclone delete exited with non-zero status $?"

echo "[$(date)] Backup complete."
