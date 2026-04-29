#!/bin/bash
set -euo pipefail
# ---------------------- CONFIGURATION ----------------------------------------
LOCKFILE="/tmp/immich-usb-backup.lock"
USB_MOUNT="/mnt/immich-backup"
PHOTO_SOURCE="/mnt/data/immich/library"
RETENTION_DAYS=7
USB_PHOTO_DEST="$USB_MOUNT/immich-library"
USB_DB_DEST="$USB_MOUNT/postgres"
DB_CONTAINER="immich_postgres"
DB_USER="postgres"
# ---------------------- LOCKFILE ---------------------------------------------
exec 9> "$LOCKFILE"
if ! flock -n 9; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup already running. Exiting."
    exit 1
fi
# ---------------------- FUNCTIONS --------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}
check_usb() {
    if ! mountpoint -q "$USB_MOUNT"; then
        log "ERROR: $USB_MOUNT is not mounted. Aborting."
        exit 1
    fi
    mkdir -p "$USB_PHOTO_DEST" "$USB_DB_DEST"
}
dump_db() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local dump_file="$USB_DB_DEST/immich_${timestamp}.sql.gz"
    log "Dumping Postgres database directly to USB..."
    docker exec "$DB_CONTAINER" pg_dumpall -U "$DB_USER" | gzip > "$dump_file"
    log "Cleaning up old DB dumps on USB (older than ${RETENTION_DAYS} days)..."
    find "$USB_DB_DEST" -name "immich_*.sql.gz" -mtime +"$RETENTION_DAYS" -delete
}
sync_photos() {
    log "Syncing photo library from $PHOTO_SOURCE to $USB_PHOTO_DEST..."
    local backup_dir="$USB_MOUNT/.deleted-$(date +%Y%m)"
    set +e
    rsync -ah --info=progress2 --delete --backup --backup-dir="$backup_dir" \
        "$PHOTO_SOURCE/" "$USB_PHOTO_DEST/"
    local rsync_exit_code=$?
    set -e
    if [ $rsync_exit_code -eq 0 ]; then
        log "Photo sync completed successfully."
    elif [ $rsync_exit_code -eq 24 ]; then
        log "WARNING: rsync exit 24 (files vanished during sync) — normal for live systems."
    else
        log "ERROR: rsync failed with exit code $rsync_exit_code."
        exit 1
    fi
    log "Cleaning up old .deleted-* dirs (older than 30 days)..."
    find "$USB_MOUNT" -maxdepth 1 -name ".deleted-*" -mtime +30 -exec rm -rf {} +
}
# ---------------------- MAIN -------------------------------------------------
log "========== Immich USB Backup Started =========="
check_usb
dump_db
sync_photos
log "========== Backup Complete =========="
