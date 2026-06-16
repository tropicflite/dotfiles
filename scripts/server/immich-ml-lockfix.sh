#!/bin/bash
# Removes stale /opt/venv/.lock from immich_machine_learning and restarts it if found.
# After any restart, waits for the container to become healthy and retries if needed.
CONTAINER="immich_machine_learning"
LOCKFILE="/opt/venv/.lock"
LOG_TAG="immich-ml-lockfix"
MAX_RESTARTS=3

wait_running() {
    for i in $(seq 1 12); do
        docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true && return 0
        sleep 5
    done
    return 1
}

wait_healthy() {
    for i in $(seq 1 24); do
        status=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)
        [ "$status" = "healthy" ] && return 0
        sleep 5
    done
    return 1
}

if ! wait_running; then
    logger -t "$LOG_TAG" "$CONTAINER not running after wait, skipping"
    exit 0
fi

if docker exec "$CONTAINER" test -f "$LOCKFILE" 2>/dev/null; then
    logger -t "$LOG_TAG" "Stale $LOCKFILE found — removing and restarting $CONTAINER"
    docker exec "$CONTAINER" rm -f "$LOCKFILE"
    docker restart "$CONTAINER"
else
    logger -t "$LOG_TAG" "No stale lockfile found, checking health"
fi

for attempt in $(seq 1 $MAX_RESTARTS); do
    if wait_healthy; then
        logger -t "$LOG_TAG" "$CONTAINER is healthy"
        exit 0
    fi
    logger -t "$LOG_TAG" "$CONTAINER not healthy after wait (attempt $attempt/$MAX_RESTARTS), restarting"
    docker restart "$CONTAINER"
done

logger -t "$LOG_TAG" "$CONTAINER still unhealthy after $MAX_RESTARTS restarts — giving up"
exit 1
