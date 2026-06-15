#!/bin/bash
# Removes stale /opt/venv/.lock from immich_machine_learning and restarts it if found.
CONTAINER="immich_machine_learning"
LOCKFILE="/opt/venv/.lock"
LOG_TAG="immich-ml-lockfix"

# Wait up to 60s for the container to be running
for i in $(seq 1 12); do
    if docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
        break
    fi
    sleep 5
done

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    logger -t "$LOG_TAG" "$CONTAINER not running after wait, skipping"
    exit 0
fi

if docker exec "$CONTAINER" test -f "$LOCKFILE" 2>/dev/null; then
    logger -t "$LOG_TAG" "Stale $LOCKFILE found — removing and restarting $CONTAINER"
    docker exec "$CONTAINER" rm -f "$LOCKFILE"
    docker restart "$CONTAINER"
else
    logger -t "$LOG_TAG" "No stale lockfile found, nothing to do"
fi
