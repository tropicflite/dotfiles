#!/bin/bash
# Alert when any Docker container becomes unhealthy.
# Fires immediately on detection — before autoheal restarts the container.
# Runs as a persistent systemd service (docker-health-monitor.service).
#
# 2026-07-27: added a per-container cooldown -- jellyseerr flapped unhealthy
# twice in one evening (17:32, 19:25) off transient Internet blips, each a
# separate email with zero debounce. Same "don't re-alert on the same cause
# repeating" lesson as the NAT-PMP/wg0/wifi-watchdog fixes today. A *different*
# container going unhealthy still alerts immediately (per-container state),
# and the same container gets a fresh alert again once the cooldown expires
# if it's still/again unhealthy -- this only suppresses rapid re-flapping.

EMAIL="nichols_matt@pm.me"
COOLDOWN_SECONDS=1800
STATE_DIR="/var/tmp/docker-health-monitor"
mkdir -p "$STATE_DIR"

notify_unhealthy() {
    local name="$1"
    local state_file="${STATE_DIR}/${name}.last_alert"
    local now
    now=$(date +%s)

    if [ -f "$state_file" ]; then
        local last elapsed
        last=$(cat "$state_file")
        elapsed=$(( now - last ))
        if [ "$elapsed" -lt "$COOLDOWN_SECONDS" ]; then
            logger -t docker-health-monitor "Suppressing repeat unhealthy alert for $name (${elapsed}s since last alert, cooldown ${COOLDOWN_SECONDS}s)"
            return
        fi
    fi

    echo "$now" > "$state_file"
    local body="Container $name is unhealthy on $(hostname) at $(date). autoheal will attempt a restart."
    printf "Subject: [server] Unhealthy container: %s\nTo: %s\nFrom: %s\n\nContainer %s is unhealthy on %s at %s.\n\nautoheal will attempt a restart. Run 'server-health' to verify recovery.\n" \
        "$name" "$EMAIL" "$EMAIL" "$name" "$(hostname)" "$(date)" | \
        NTFY_PRIORITY=high NTFY_TAGS=warning NTFY_BODY="$body" /usr/local/bin/send-mail
}

docker events \
    --filter 'type=container' \
    --filter 'event=health_status' \
    --format '{{.Actor.Attributes.name}} {{.Action}}' | \
while IFS= read -r line; do
    name="${line% *}"
    action="${line#* }"
    if [[ "$action" == "health_status: unhealthy" ]]; then
        notify_unhealthy "$name"
    fi
done
