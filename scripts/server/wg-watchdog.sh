#!/bin/bash
ENDPOINT_IP="154.47.17.158"
WG_IFACE="wg0"
LOG_TAG="wg-watchdog"

while true; do
    sleep 30

    # Check if wg0 exists
    if ! ip link show "$WG_IFACE" &>/dev/null; then
        logger -t "$LOG_TAG" "wg0 missing, restarting wg0.service"
        systemctl restart wg0.service
        sleep 15
        continue
    fi

    # Check if endpoint is reachable through the tunnel
    if ! ping -c 2 -W 5 -I "$WG_IFACE" "$ENDPOINT_IP" &>/dev/null; then
        logger -t "$LOG_TAG" "Endpoint unreachable, restarting wg0.service"
        systemctl restart wg0.service
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
    tailscale up --accept-dns=false --operator=matt
done
