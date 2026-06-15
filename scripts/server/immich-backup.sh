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
TO="nichols_matt@pm.me"
HOSTNAME=$(hostname)

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

send_alert() {
    local subject="$1"
    local body="$2"
    echo -e "Subject: [${HOSTNAME}] ${subject}\n\n${body}" | \
        msmtp -C /etc/msmtprc "$TO"
    local pass
    pass=$(cat /home/matt/.config/ntfy/password 2>/dev/null) || return 0
    curl -s -u "matt:$pass" \
        -H "Title: [server] ${subject}" \
        -H "Priority: high" \
        -H "Tags: rotating_light" \
        -d "${body}" \
        http://localhost:2586/server-alerts > /dev/null || true
}

error_exit() {
    local msg="$1"
    log "ERROR: $msg"
    send_alert "Immich Backup FAILED" "Backup failed on $(date).\n\nError: ${msg}\n\nCheck /var/log/immich-backup.log for details."
    exit 1
}

check_usb() {
    if ! mountpoint -q "$USB_MOUNT"; then
        error_exit "$USB_MOUNT is not mounted. Aborting."
    fi
    mkdir -p "$USB_PHOTO_DEST" "$USB_DB_DEST"
}

dump_db() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local dump_file="$USB_DB_DEST/immich_${timestamp}.sql.gz"
    log "Dumping Postgres database directly to USB..."
    docker exec "$DB_CONTAINER" pg_dumpall -U "$DB_USER" | gzip > "$dump_file" || \
        error_exit "Postgres dump failed."
    log "Cleaning up old DB dumps on USB (older than ${RETENTION_DAYS} days)..."
    find "$USB_DB_DEST" -name "immich_*.sql.gz" -mtime +"$RETENTION_DAYS" -delete
}

sync_photos() {
    log "Syncing photo library from $PHOTO_SOURCE to $USB_PHOTO_DEST..."
    local backup_dir="$USB_MOUNT/.deleted-$(date +%Y%m)"
    set +e
    rsync -ah --no-owner --no-group --info=stats2 --delete --backup --backup-dir="$backup_dir" \
        "$PHOTO_SOURCE/" "$USB_PHOTO_DEST/"
    local rsync_exit_code=$?
    set -e
    if [ $rsync_exit_code -eq 0 ]; then
        log "Photo sync completed successfully."
    elif [ $rsync_exit_code -eq 24 ]; then
        log "WARNING: rsync exit 24 (files vanished during sync) — normal for live systems."
    else
        error_exit "rsync failed with exit code $rsync_exit_code."
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
