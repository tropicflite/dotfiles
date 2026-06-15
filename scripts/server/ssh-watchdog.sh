#!/bin/bash
LOG_TAG="ssh-watchdog"

send_ntfy() {
    local title="$1" body="$2" priority="${3:-default}" tags="${4:-warning}"
    local pass
    pass=$(cat /home/matt/.config/ntfy/password 2>/dev/null) || return 0
    curl -s -u "matt:$pass" \
        -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" \
        -d "$body" http://localhost:2586/server-alerts > /dev/null || true
}
MAX_FAILS=5
FAIL_COUNT=0

# Detect LAN gateway via enp1s0, retrying on startup in case network isn't fully up
GATEWAY=""
for i in $(seq 1 10); do
    GATEWAY=$(ip route show default | awk '/enp1s0/ {print $3; exit}')
    [ -n "$GATEWAY" ] && break
    sleep 5
done

if [ -z "$GATEWAY" ]; then
    logger -t "$LOG_TAG" "Could not detect LAN gateway after retries, exiting"
    exit 1
fi

logger -t "$LOG_TAG" "Starting: LAN gateway=${GATEWAY}"

while true; do
    sleep 60

    ssh_ok=false
    net_ok=false

    nc -z -w 10 127.0.0.1 28901 &>/dev/null && ssh_ok=true
    ping -c 2 -W 5 -I enp1s0 "$GATEWAY" &>/dev/null && net_ok=true

    if $ssh_ok && $net_ok; then
        if [ "$FAIL_COUNT" -gt 0 ]; then
            logger -t "$LOG_TAG" "Checks recovered after ${FAIL_COUNT} failure(s)"
        fi
        FAIL_COUNT=0
        continue
    fi

    FAIL_COUNT=$((FAIL_COUNT + 1))
    logger -t "$LOG_TAG" "Check failed (${FAIL_COUNT}/${MAX_FAILS}): ssh=${ssh_ok} net=${net_ok}"

    if ! $ssh_ok; then
        if ! systemctl is-active --quiet ssh; then
            logger -t "$LOG_TAG" "sshd is not active, restarting"
            systemctl restart ssh
            send_ntfy "[server] sshd was down — restarted" "sshd was not active; restarted at $(date). Fail count: ${FAIL_COUNT}/${MAX_FAILS}." high warning
            sleep 5
        else
            logger -t "$LOG_TAG" "sshd is active but port check failed, skipping restart"
        fi
    fi

    if [ "$FAIL_COUNT" -ge "$MAX_FAILS" ]; then
        logger -t "$LOG_TAG" "REBOOTING: ${MAX_FAILS} consecutive failures"
        send_ntfy "[server] Rebooting — ${MAX_FAILS} consecutive failures" "ssh=${ssh_ok} net=${net_ok}. Initiating reboot at $(date)." max rotating_light
        systemctl reboot
    fi
done
