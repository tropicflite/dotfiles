#!/bin/bash
# Alert when any Docker container becomes unhealthy.
# Fires immediately on detection — before autoheal restarts the container.
# Runs as a persistent systemd service (docker-health-monitor.service).

NTFY_URL="http://localhost:2586/server-alerts"
EMAIL="nichols_matt@pm.me"

send_ntfy() {
    local name="$1"
    local pass
    pass=$(cat /home/matt/.config/ntfy/password 2>/dev/null) || return 0
    if ! curl -s -u "matt:$pass" \
        -H "Title: [server] Unhealthy container: $name" \
        -H "Priority: high" \
        -H "Tags: warning" \
        -d "Container $name is unhealthy on $(hostname) at $(date). autoheal will attempt a restart." \
        "$NTFY_URL" > /dev/null 2>&1; then
        shpass=$(cat /home/matt/.config/ntfy/ntfysh-password 2>/dev/null) && \
        curl -s -u "tropicflite:$shpass" \
            -H "Title: [server] Unhealthy container: $name" \
            -H "Priority: high" \
            -H "Tags: warning" \
            -d "Container $name is unhealthy on $(hostname) at $(date). autoheal will attempt a restart." \
            https://ntfy.sh/server-alerts > /dev/null || true
    fi
}

send_email() {
    local name="$1"
    printf "Subject: [server] Unhealthy container: %s\nTo: %s\nFrom: %s\n\nContainer %s is unhealthy on %s at %s.\n\nautoheal will attempt a restart. Run 'server-check' to verify recovery.\n" \
        "$name" "$EMAIL" "$EMAIL" "$name" "$(hostname)" "$(date)" | msmtp "$EMAIL"
}

docker events \
    --filter 'type=container' \
    --filter 'event=health_status' \
    --format '{{.Actor.Attributes.name}} {{.Action}}' | \
while IFS= read -r line; do
    name="${line% *}"
    action="${line#* }"
    if [[ "$action" == "health_status: unhealthy" ]]; then
        send_ntfy "$name"
        send_email "$name"
    fi
done
