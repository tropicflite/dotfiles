#!/bin/bash
# Alert when any Docker container becomes unhealthy.
# Fires immediately on detection — before autoheal restarts the container.
# Runs as a persistent systemd service (docker-health-monitor.service).

EMAIL="nichols_matt@pm.me"

notify_unhealthy() {
    local name="$1"
    local body="Container $name is unhealthy on $(hostname) at $(date). autoheal will attempt a restart."
    printf "Subject: [server] Unhealthy container: %s\nTo: %s\nFrom: %s\n\nContainer %s is unhealthy on %s at %s.\n\nautoheal will attempt a restart. Run 'server-check' to verify recovery.\n" \
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
