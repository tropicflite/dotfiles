#!/bin/bash
set -euo pipefail

RCLONE_REMOTE="proton:backups/immich"
LIBRARY_DIR="/mnt/data/immich/library"
DUMP_DIR="/tmp/immich-restore"

echo "[$(date)] Starting Immich restore..."

# Stop VPN (Proton blocks VPN IPs)
echo "[$(date)] Stopping WireGuard VPN..."
sudo systemctl stop wg-watchdog wg0

mkdir -p "$DUMP_DIR"

# Pull latest postgres dump
echo "[$(date)] Finding latest DB dump on Proton Drive..."
LATEST=$(rclone lsf "$RCLONE_REMOTE/postgres" --format "t;n" | sort -r | head -1 | cut -d';' -f2)
echo "[$(date)] Latest dump: $LATEST"
rclone copy "$RCLONE_REMOTE/postgres/$LATEST" "$DUMP_DIR/"

# Restore photo library
echo "[$(date)] Syncing photo library from Proton Drive (this will take a while)..."
rclone sync "$RCLONE_REMOTE/library" "$LIBRARY_DIR" \
    --transfers=4 \
    --checkers=8 \
    --log-level INFO

# Restart VPN
echo "[$(date)] Restarting WireGuard VPN..."
sudo systemctl start wg-watchdog

# Stop Immich before DB restore
echo "[$(date)] Stopping Immich services..."
cd ~/docker/immich && docker compose stop immich-server immich-microservices

# Restore DB
echo "[$(date)] Restoring Postgres from $LATEST..."
zcat "$DUMP_DIR/$LATEST" | docker exec -i immich_postgres psql -U postgres

# Restart Immich
echo "[$(date)] Starting Immich services..."
docker compose start immich-server immich-microservices

# Cleanup
rm -rf "$DUMP_DIR"

echo "[$(date)] Restore complete. Verify Immich at https://your-server/immich"
