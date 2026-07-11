#!/bin/bash
# wifi-watchdog.sh — self-heals laptop's WiFi/Tailscale connectivity.
# Cron-driven (SysVinit, no systemd) — see install instructions below.
#
# Background: the 2026-07-01 outage was a wpa_supplicant WRONG_KEY rejection
# that got stuck retry-looping for 14 minutes with no further handshake
# attempts, caused by a transient AP/power glitch, NOT an actual credential
# change (PSK confirmed unchanged, stored system-wide via wifi-sec.psk-flags=0
# so no keyring/login is needed to use it). That means a forced reassociation
# can resolve it without physical presence, even though NetworkManager itself
# never retried on its own.
#
# Distinguishes two failure layers so remediation matches the actual cause:
#   - LAN gateway unreachable -> WiFi association problem -> WiFi escalation ladder
#   - gateway OK but Tailscale peer unreachable -> tailscaled problem -> TS ladder
#
# Install (run once laptop is reachable):
#   sudo cp ~/dotfiles/scripts/laptop/wifi-watchdog.sh /usr/local/bin/wifi-watchdog.sh
#   sudo chmod +x /usr/local/bin/wifi-watchdog.sh
#   sudo crontab -e   # add: */2 * * * * /usr/local/bin/wifi-watchdog.sh
# Must run as root (nmcli radio/connection changes and `service` restarts
# need it; cron has no polkit agent to prompt for auth).
#
# NOTE: verify WIFI_CONN and the network-manager/tailscaled init script names
# against the live box before relying on this — written while laptop was
# offline and unreachable, so untested against the actual machine.

LOG_TAG="wifi-watchdog"
WIFI_CONN="NachoWiFi"
TS_PEER="100.65.250.53"  # server
PING_TIMEOUT=5
GW_STATE_FILE="/var/tmp/wifi-watchdog.gwfails"
TS_STATE_FILE="/var/tmp/wifi-watchdog.tsfails"

LOCK="/var/tmp/wifi-watchdog.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0

read_count() { [ -r "$1" ] && cat "$1" || echo 0; }

gw=$(ip route show default | awk '{print $3; exit}')
gw_ok=false
[ -n "$gw" ] && ping -c2 -W "$PING_TIMEOUT" "$gw" &>/dev/null && gw_ok=true

if $gw_ok; then
    gw_fails=$(read_count "$GW_STATE_FILE")
    [ "$gw_fails" -gt 0 ] && logger -t "$LOG_TAG" "Gateway recovered after ${gw_fails} failed check(s)"
    echo 0 > "$GW_STATE_FILE"

    ts_ok=false
    ping -c2 -W "$PING_TIMEOUT" "$TS_PEER" &>/dev/null && ts_ok=true

    if $ts_ok; then
        ts_fails=$(read_count "$TS_STATE_FILE")
        [ "$ts_fails" -gt 0 ] && logger -t "$LOG_TAG" "Tailscale peer recovered after ${ts_fails} failed check(s)"
        echo 0 > "$TS_STATE_FILE"
        exit 0
    fi

    ts_fails=$(($(read_count "$TS_STATE_FILE") + 1))
    echo "$ts_fails" > "$TS_STATE_FILE"
    logger -t "$LOG_TAG" "Gateway OK but Tailscale peer unreachable (${ts_fails})"

    if [ "$ts_fails" -eq 2 ]; then
        logger -t "$LOG_TAG" "tailscale up"
        tailscale up &>/dev/null
    elif [ "$ts_fails" -eq 5 ] || { [ "$ts_fails" -gt 5 ] && [ $((ts_fails % 5)) -eq 0 ]; }; then
        logger -t "$LOG_TAG" "Restarting tailscaled"
        service tailscaled restart &>/dev/null
        sleep 5
        tailscale up &>/dev/null
    fi
    exit 0
fi

gw_fails=$(($(read_count "$GW_STATE_FILE") + 1))
echo "$gw_fails" > "$GW_STATE_FILE"
logger -t "$LOG_TAG" "No default gateway reachable (${gw_fails})"

if [ "$gw_fails" -eq 2 ]; then
    logger -t "$LOG_TAG" "Soft reconnect: nmcli connection up ${WIFI_CONN}"
    nmcli connection up "$WIFI_CONN" &>/dev/null
elif [ "$gw_fails" -eq 5 ]; then
    logger -t "$LOG_TAG" "Radio bounce"
    nmcli radio wifi off
    sleep 3
    nmcli radio wifi on
elif [ "$gw_fails" -eq 8 ] || { [ "$gw_fails" -gt 8 ] && [ $((gw_fails % 8)) -eq 0 ]; }; then
    logger -t "$LOG_TAG" "Restarting NetworkManager"
    service network-manager restart &>/dev/null
    sleep 5
    nmcli connection up "$WIFI_CONN" &>/dev/null
fi
