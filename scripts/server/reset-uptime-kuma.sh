#!/usr/bin/env bash
set -euo pipefail

DB="/home/matt/docker/uptime-kuma/kuma.db"
CONTAINER="uptime-kuma"

echo "Stopping $CONTAINER..."
docker stop "$CONTAINER"

echo "Clearing heartbeat and stats..."
sudo sqlite3 "$DB" "DELETE FROM heartbeat; DELETE FROM stat_hourly; DELETE FROM stat_daily; DELETE FROM stat_minutely;"

echo "Starting $CONTAINER..."
docker start "$CONTAINER"

echo "Done."
