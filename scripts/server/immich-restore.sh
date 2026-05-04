#!/bin/bash
set -euo pipefail
# ---------------------- CONFIGURATION ----------------------------------------
USB_MOUNT="/mnt/immich-backup"
PHOTO_DEST="/mnt/data/immich/library"
USB_PHOTO_SOURCE="$USB_MOUNT/immich-library"
USB_DB_SOURCE="$USB_MOUNT/postgres"
DB_CONTAINER="immich_postgres"
DB_USER="postgres"
# ---------------------- FUNCTIONS --------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}
check_usb() {
    if ! mountpoint -q "$USB_MOUNT"; then
        log "ERROR: $USB_MOUNT is not mounted. Aborting."
        exit 1
    fi
}
pick_dump() {
    # Show available dumps and let user pick, defaulting to latest
    log "Available DB dumps:"
    ls -lt "$USB_DB_SOURCE"/*.sql.gz | awk '{print NR")", $9}'
    echo ""
    local latest
    latest=$(ls -t "$USB_DB_SOURCE"/*.sql.gz | head -1)
    read -rp "Enter dump path to restore [default: $latest]: " choice
    DUMP_FILE="${choice:-$latest}"
    if [ ! -f "$DUMP_FILE" ]; then
        log "ERROR: $DUMP_FILE not found."
        exit 1
    fi
    log "Using dump: $DUMP_FILE"
}
confirm() {
    echo ""
    echo "  !! WARNING: This will overwrite your live Immich data !!"
    echo ""
    read -rp "Type YES to continue: " answer
    if [ "$answer" != "YES" ]; then
        log "Aborted."
        exit 0
    fi
}
restore_db() {
    log "Stopping Immich containers (keeping Postgres running)..."
    docker stop immich_server immich_machine_learning immich_redis 2>/dev/null || true
    log "Dropping immich database to ensure clean restore..."
    docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS immich;"
    log "Restoring database from $DUMP_FILE..."
    zcat "$DUMP_FILE" | docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d postgres
    log "Verifying restore..."
    local count
    count=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d immich -tAc "SELECT COUNT(*) FROM assets;" 2>/dev/null || echo "ERROR")
    if [ "$count" = "ERROR" ] || [ "$count" = "0" ]; then
        log "WARNING: assets table empty or missing after restore — verify backup integrity before restarting."
        exit 1
    fi
    log "Restore verification: $count assets in database."
    log "Restarting Immich containers..."
    docker start immich_redis immich_machine_learning immich_server
}
restore_photos() {
    log "Restoring photo library from $USB_PHOTO_SOURCE to $PHOTO_DEST..."
    set +e
    rsync -ah --info=progress2 --delete "$USB_PHOTO_SOURCE/" "$PHOTO_DEST/"
    local exit_code=$?
    set -e
    if [ $exit_code -eq 0 ] || [ $exit_code -eq 24 ]; then
        log "Photo restore completed."
    else
        log "ERROR: rsync failed with exit code $exit_code."
        exit 1
    fi
}
# ---------------------- MAIN -------------------------------------------------
log "========== Immich USB Restore =========="
check_usb
pick_dump
confirm
restore_db
restore_photos
log "========== Restore Complete =========="
log "You may want to run a library rescan in the Immich web UI."
