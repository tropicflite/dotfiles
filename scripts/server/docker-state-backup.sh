#!/bin/bash
set -euo pipefail

# Nightly rsync of Docker container runtime state (bind-mounts and named volumes
# not captured by git) to /mnt/immich-backup/docker-state/.
# Runs as root (required for uptime-kuma data).
# Containers are left running during sync — SQLite WAL handles concurrent reads;
# the previous night's snapshot is available as fallback if a backup is inconsistent.
# Run via root crontab: 0 1 * * * /usr/local/bin/docker-state-backup.sh >> /var/log/docker-state-backup.log 2>&1

BACKUP_BASE="/mnt/immich-backup/docker-state"
USB_MOUNT="/mnt/immich-backup"
LOCKFILE="/tmp/docker-state-backup.lock"
HOSTNAME_SHORT=$(hostname)

# ---------------------- LOCK -------------------------------------------------
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Already running. Exiting."
    exit 1
fi

# ---------------------- FUNCTIONS --------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

send_alert() {
    local subject="$1" body="$2"
    printf "Subject: [%s] %s\n\n%s\n" "$HOSTNAME_SHORT" "$subject" "$body" | \
        NTFY_PRIORITY=high NTFY_TAGS=rotating_light NTFY_BODY="$body" \
        /usr/local/bin/send-mail
}

error_exit() {
    log "ERROR: $1"
    send_alert "Docker state backup FAILED" "Backup failed on $(date). Error: $1. Check /var/log/docker-state-backup.log."
    exit 1
}

check_usb() {
    mountpoint -q "$USB_MOUNT" || error_exit "$USB_MOUNT is not mounted."
    mkdir -p "$BACKUP_BASE"
}

# rsync one path to $BACKUP_BASE/<dest>, with monthly deleted-file retention.
# Usage: sync_path <src> <dest-name> [extra rsync args...]
sync_path() {
    local src="$1" dest_name="$2"
    shift 2
    local dest="${BACKUP_BASE}/${dest_name}"
    local backup_dir="${BACKUP_BASE}/.deleted-$(date +%Y%m)/${dest_name}"
    mkdir -p "$dest"
    set +e
    rsync -a --delete --backup --backup-dir="$backup_dir" "$@" "${src%/}/" "$dest/"
    local rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        log "  ${dest_name}: ok"
    elif [ "$rc" -eq 24 ]; then
        log "  ${dest_name}: ok (exit 24 — files vanished during sync, normal for live containers)"
    else
        error_exit "rsync ${dest_name} failed (exit ${rc})"
    fi
}

# ---------------------- MAIN -------------------------------------------------
log "========== Docker State Backup Started =========="
check_usb

DOCKER=/home/matt/docker

log "arrs stack..."
sync_path "$DOCKER/arrs/prowlarr/config"   prowlarr
sync_path "$DOCKER/arrs/sonarr/config"     sonarr
sync_path "$DOCKER/arrs/radarr/config"     radarr
sync_path "$DOCKER/arrs/bazarr/config"     bazarr
sync_path "$DOCKER/arrs/jellyseerr/config" jellyseerr

log "uptime-kuma..."
sync_path "$DOCKER/uptime-kuma" uptime-kuma

log "pihole (excluding gravity db)..."
sync_path "$DOCKER/pihole/pihole" pihole \
    --exclude='etc-pihole/gravity.db' \
    --exclude='etc-pihole/gravity_old.db' \
    --exclude='etc-pihole/gravity_backups/'

log "scrutiny..."
sync_path "$DOCKER/scrutiny/config" scrutiny

log "qbittorrent..."
sync_path "$DOCKER/qbittorrent/config" qbittorrent

log "jellyfin..."
sync_path /opt/docker/jellyfin/config jellyfin

log "tsdproxy tsnet state..."
sync_path "$DOCKER/tsdproxy/data" tsdproxy

log "ntfy (auth.db - users/passwords; found unbacked-up in 2026-07-02 rebuild.md audit)..."
sync_path "$DOCKER/ntfy/data" ntfy

log "claude memory (institutional memory notes, no git/other backup; found unbacked-up 2026-07-10)..."
sync_path /home/matt/.claude/projects/-home-matt/memory claude-memory

log "cleaning up .deleted-* dirs older than 30 days..."
find "$BACKUP_BASE" -maxdepth 1 -name '.deleted-*' -mtime +30 -exec rm -rf {} +

log "========== Docker State Backup Complete =========="
