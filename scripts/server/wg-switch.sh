#!/bin/bash
# Switch the active wg0 profile between the primary and failover ProtonVPN
# configs. Run manually (sudo wg-switch primary|failover) or invoked by
# wg-watchdog.sh when the primary endpoint has been unreachable past its
# failover threshold. No auto-failback — switching back to primary after
# it recovers is always a manual/watchdog-deliberate call, to avoid flapping
# between two endpoints if one is intermittently flaky.
set -euo pipefail

PROFILES_DIR="/etc/wireguard/profiles"
WG_CONF="/etc/wireguard/wg0.conf"
TARGET="${1:-}"

case "$TARGET" in
    primary|failover) ;;
    *)
        echo "Usage: wg-switch.sh primary|failover" >&2
        exit 1
        ;;
esac

SRC="$PROFILES_DIR/wg0-$TARGET.conf"
if [[ ! -f "$SRC" ]]; then
    echo "Missing profile: $SRC" >&2
    exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Must run as root (sudo wg-switch $TARGET)" >&2
    exit 1
fi

logger -t wg-switch "Switching wg0 to $TARGET profile"
wg-quick down "$WG_CONF" 2>/dev/null || true
install -m 600 -o root -g root "$SRC" "$WG_CONF"
wg-quick up "$WG_CONF"

ENDPOINT=$(grep -m1 '^Endpoint' "$WG_CONF" | sed -E 's/^Endpoint\s*=\s*([^:]+):.*/\1/')
echo "wg0 now on '$TARGET' profile, endpoint $ENDPOINT"
logger -t wg-switch "wg0 now on $TARGET profile, endpoint $ENDPOINT"
