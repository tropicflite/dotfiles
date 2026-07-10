#!/bin/bash
# nut-server.service no longer blocks its startup on the Tailscale IP existing
# (see nut-server.service.d/tailscale.conf and server-configs/nut/upsd.conf) —
# upsd starts immediately on 127.0.0.1+172.20.0.1 and just logs a warning for
# the not-yet-bindable Tailscale LISTEN. upsd only re-reads LISTEN lines on
# restart, not reload, so once Tailscale is actually up this restarts
# nut-server once to pick up the Tailscale-bound listener (for the remote
# WinNUT client). Triggered by tailscale-ready.service's OnSuccess=, so it
# runs on boot and after any self-heal restart — harmless no-op if nut-server
# is already listening on the Tailscale IP.
# Install: sudo cp ~/dotfiles/scripts/server/nut-tailscale-listen.sh /usr/local/bin/nut-tailscale-listen.sh && sudo chmod +x /usr/local/bin/nut-tailscale-listen.sh

set -euo pipefail

TS_IP=$(tailscale ip -4 2>/dev/null) || exit 0
[ -z "$TS_IP" ] && exit 0

ss -tln "( sport = :3493 )" 2>/dev/null | grep -q "$TS_IP:3493" && exit 0

# Never bounce upsd while upsmon is connected: the broken-pipe disconnect can
# skip DEADTIME and go straight to SHUTDOWNCMD — a real poweroff (2026-07-02
# incident; see docker/CLAUDE.md restart-danger bullet). Same stop/start
# wrapper as nut-apt-hook; the trap guarantees nut-monitor comes back even if
# the nut-server restart fails.
STOPPED_MONITOR=0
if systemctl is-active --quiet nut-monitor.service; then
    systemctl stop nut-monitor.service
    STOPPED_MONITOR=1
fi
trap 'if [ "$STOPPED_MONITOR" = 1 ]; then systemctl start nut-monitor.service; fi' EXIT

systemctl restart nut-server.service
