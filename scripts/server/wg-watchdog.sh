#!/bin/bash
ENDPOINT_IP="139.28.218.130"
ENDPOINT_NAME="ProtonVPN"
WG_IFACE="wg0"
LOG_TAG="wg-watchdog"

BASE_SLEEP=30        # normal poll interval when healthy
MAX_BACKOFF=300       # cap retry interval once a failure is confirmed persistent (5 min)
ALERT_REPEAT_SECS=900 # while still down, re-alert at most this often (15 min)

send_ntfy() {
    local title="$1" body="$2" priority="${3:-default}" tags="${4:-warning}"
    # No public-ntfy.sh fallback (removed 2026-07-02): the topic ID was committed
    # to dotfiles, making alert contents world-readable. Box-level outage
    # detection is healthchecks.io's job now; local ntfy failure alone is
    # covered by email from the other monitors.
    /usr/local/bin/send-alert "$title" "$body" "$priority" "$tags"
}

# Failures often come from an upstream condition (e.g. an ISP UDP block) that
# bouncing the interface can't fix — retrying every 30s just thrashes wg0 and
# forces a full tailscaled rebind each time, and spams an alert per attempt.
# Back off the retry interval while a given failure persists, and throttle
# alerts to one on onset + at most one per ALERT_REPEAT_SECS while it continues.
CUR_FAIL_TYPE=""
CONSEC_FAILS=0
INCIDENT_START=0
LAST_ALERT=0
CUR_BACKOFF=$BASE_SLEEP

record_failure() {
    local type="$1" title="$2" body="$3"
    local now
    now=$(date +%s)

    if [[ "$CUR_FAIL_TYPE" != "$type" ]]; then
        CUR_FAIL_TYPE="$type"
        CONSEC_FAILS=0
        INCIDENT_START=$now
        CUR_BACKOFF=$BASE_SLEEP
    fi
    CONSEC_FAILS=$((CONSEC_FAILS + 1))

    if [[ $CONSEC_FAILS -eq 1 ]]; then
        send_ntfy "$title" "$body"
        LAST_ALERT=$now
    elif (( now - LAST_ALERT >= ALERT_REPEAT_SECS )); then
        local down_for=$(( (now - INCIDENT_START) / 60 ))
        send_ntfy "$title (still down)" "$body Still failing after $CONSEC_FAILS attempts, down ~${down_for}m."
        LAST_ALERT=$now
    fi

    CUR_BACKOFF=$(( CUR_BACKOFF * 2 ))
    (( CUR_BACKOFF > MAX_BACKOFF )) && CUR_BACKOFF=$MAX_BACKOFF
}

record_recovery() {
    local title="$1"
    if [[ -n "$CUR_FAIL_TYPE" && $CONSEC_FAILS -gt 0 ]]; then
        local now down_for
        now=$(date +%s)
        down_for=$(( now - INCIDENT_START ))
        send_ntfy "$title" "Recovered after $CONSEC_FAILS attempts, down $(( down_for / 60 ))m $(( down_for % 60 ))s." default white_check_mark
    fi
    CUR_FAIL_TYPE=""
    CONSEC_FAILS=0
    CUR_BACKOFF=$BASE_SLEEP
}

while true; do
    sleep "$CUR_BACKOFF"

    # Check if wg0 exists
    if ! ip link show "$WG_IFACE" &>/dev/null; then
        logger -t "$LOG_TAG" "wg0 missing, bringing interface back up"
        wg-quick down "$WG_IFACE" 2>/dev/null; wg-quick up "$WG_IFACE"
        record_failure "wg0 interface missing" "[server] wg0 interface missing — bounced" "wg0 interface was missing; brought back up at $(date)."
        sleep 15
        continue
    fi

    # Check if endpoint is reachable through the tunnel
    if ! ping -c 2 -W 5 -I "$WG_IFACE" "$ENDPOINT_IP" &>/dev/null; then
        logger -t "$LOG_TAG" "Endpoint unreachable, bouncing wg0 interface"
        wg-quick down "$WG_IFACE" 2>/dev/null; wg-quick up "$WG_IFACE"
        record_failure "WireGuard endpoint unreachable" "[server] WireGuard endpoint unreachable — bounced" "$ENDPOINT_NAME endpoint unreachable through $WG_IFACE; interface bounced at $(date)."
        sleep 15
        continue
    fi

    [[ "$CUR_FAIL_TYPE" == "wg0 interface missing" || "$CUR_FAIL_TYPE" == "WireGuard endpoint unreachable" ]] && \
        record_recovery "[server] wg0 back up"

    # Check if Tailscale can reach the coordination server
    if ! tailscale status 2>&1 | grep -q "coordination server" ; then
        # No coordination server complaint, Tailscale is healthy
        [[ "$CUR_FAIL_TYPE" == "Tailscale coordination unreachable" ]] && \
            record_recovery "[server] Tailscale coordination back"
        continue
    fi

    logger -t "$LOG_TAG" "Tailscale coordination server unreachable, restarting tailscaled"
    tailscale down
    tailscale up --accept-dns=false --operator=matt --advertise-routes=10.0.0.0/24,192.168.50.0/24 --hostname=server --advertise-exit-node
    record_failure "Tailscale coordination unreachable" "[server] Tailscale coordination unreachable — restarted" "Tailscale coordination server was unreachable; tailscaled bounced at $(date)."
done
