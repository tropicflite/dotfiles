#!/bin/bash
ENDPOINT_IP="154.47.17.129"
WG_IFACE="wg0"
LOG_TAG="wg-watchdog"

send_ntfy() {
    local title="$1" body="$2" priority="${3:-default}" tags="${4:-warning}"
    local pass
    pass=$(cat /home/matt/.config/ntfy/password 2>/dev/null) || return 0
    curl -s -u "matt:$pass" \
        -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" \
        -d "$body" http://localhost:2586/server-alerts > /dev/null || true
}

while true; do
    sleep 30

    # Check if wg0 exists
    if ! ip link show "$WG_IFACE" &>/dev/null; then
        logger -t "$LOG_TAG" "wg0 missing, bringing interface back up"
        wg-quick down "$WG_IFACE" 2>/dev/null; wg-quick up "$WG_IFACE"
        send_ntfy "[server] wg0 interface missing — bounced" "wg0 interface was missing; brought back up at $(date)."
        sleep 15
        continue
    fi

    # Check if endpoint is reachable through the tunnel
    if ! ping -c 2 -W 5 -I "$WG_IFACE" "$ENDPOINT_IP" &>/dev/null; then
        logger -t "$LOG_TAG" "Endpoint unreachable, bouncing wg0 interface"
        wg-quick down "$WG_IFACE" 2>/dev/null; wg-quick up "$WG_IFACE"
        send_ntfy "[server] WireGuard endpoint unreachable — bounced" "Endpoint $ENDPOINT_IP unreachable through $WG_IFACE; interface bounced at $(date)."
        sleep 15
        continue
    fi

    # Check if Tailscale can reach the coordination server
    if ! tailscale status 2>&1 | grep -q "coordination server" ; then
        # No coordination server complaint, Tailscale is healthy
        continue
    fi

    logger -t "$LOG_TAG" "Tailscale coordination server unreachable, restarting tailscaled"
    tailscale down
    tailscale up --accept-dns=false --operator=matt --advertise-routes=10.0.0.0/24,192.168.50.0/24 --hostname=server --advertise-exit-node
    send_ntfy "[server] Tailscale coordination unreachable — restarted" "Tailscale coordination server was unreachable; tailscaled bounced at $(date)."
done
