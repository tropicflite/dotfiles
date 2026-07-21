#!/bin/bash
# NOTE: this only runs via systemd ExecStopPost (systemctl stop/restart
# wg0, or a service crash). wg-watchdog.sh calls `wg-quick down` directly,
# bypassing systemd, so this script does NOT run during a watchdog bounce —
# the exit-node kill switch and CONNMARK setup live in wg0-up-extra.sh
# (PostUp) instead, since that's the one code path every wg-quick
# invocation shares (boot, systemctl, and watchdog alike).
iptables -D FORWARD -i br-pihole -o wg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i wg0 -o br-pihole -j ACCEPT 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 172.25.0.0/24 -o wg0 -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i tailscale0 -o wg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i wg0 -o tailscale0 -j ACCEPT 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 100.64.0.0/10 -o wg0 -j MASQUERADE 2>/dev/null || true

# Exit-node kill switch (FORWARD -m mark --mark 0x200 ! -o wg0 -j DROP,
# installed in wg0-up-extra.sh) is intentionally left in place here — same
# fail-closed philosophy as the qBittorrent kill switch. Removing it on
# down would defeat the entire point.
conntrack -D -m 0x200 2>/dev/null || true
