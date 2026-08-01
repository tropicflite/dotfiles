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
# 2026-07-27 UPDATE: gateway-ping-only detection was itself the problem — 81
# "gateway unreachable" blips and 5 disruptive radio bounces in ~20h, but
# NetworkManager/wpa_supplicant logs showed zero organic disassociation
# events except the ones the radio bounces caused themselves. Same class of
# bug as the 2026-07-26 wg0 fix: ICMP to the gateway isn't a reliable
# liveness signal (drops/delays for reasons unrelated to WiFi association).
# Now checks NetworkManager's own device state for wlan0 first — a real,
# zero-network-cost signal, like using WireGuard handshake age instead of
# ICMP-through-tunnel. A gateway ping failure while still "connected" is
# treated as likely transient ICMP noise: tracked separately, remedied only
# with a gentle soft reconnect, and never escalated to a radio bounce or
# NetworkManager restart — those are now reserved for confirmed association
# loss.
#
# 2026-08-01 UPDATE: the above fix introduced a dead-code bug. SOFT_STATE_FILE
# was only ever reset to 0 in the "real WiFi problem" branch, never when the
# gateway ping genuinely recovered — so once it climbed past 5 (which happens
# fast) the `-eq 5` exact-match trigger could never fire again until a full
# disassociation reset it. Confirmed via laptop's own syslog: 427 "transient
# ICMP loss" log lines since 07-26, counter reaching 327, zero "Soft
# reconnect" actions ever logged. This was a real, sustained failure mode
# (wlan0 stuck "connected" per NetworkManager but not actually passing
# traffic — a zombie association, plausibly the Broadcom `wl` driver quirk
# flagged as an unruled-out risk in the 07-27 note) that the watchdog
# silently did nothing about for hours, only cleared by a manual reboot.
# Fixed by (1) resetting SOFT_STATE_FILE in the healthy-gateway branch too,
# and (2) replacing the one-shot trigger with a repeating ladder that
# eventually escalates to a radio bounce / NetworkManager restart if gentle
# reconnects don't clear a sustained (not transient) condition. Thresholds
# are longer than the confirmed-disassociation ladder's on purpose — this
# path must still tolerate brief real ICMP noise without bouncing, per the
# original 07-27 fix's reasoning; it just can no longer go silent forever.

LOG_TAG="wifi-watchdog"
WIFI_CONN="NachoWiFi"
WIFI_IFACE="wlan0"
TS_PEER="100.65.250.53"  # server
PING_TIMEOUT=5
GW_STATE_FILE="/var/tmp/wifi-watchdog.gwfails"
SOFT_STATE_FILE="/var/tmp/wifi-watchdog.softfails"
TS_STATE_FILE="/var/tmp/wifi-watchdog.tsfails"

LOCK="/var/tmp/wifi-watchdog.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0

read_count() { [ -r "$1" ] && cat "$1" || echo 0; }

assoc_ok() {
    local state
    state=$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | awk -F: -v d="$WIFI_IFACE" '$1==d{print $2}')
    [ "$state" = "connected" ]
}

gw=$(ip route show default | awk '{print $3; exit}')
gw_ok=false
[ -n "$gw" ] && ping -c2 -W "$PING_TIMEOUT" "$gw" &>/dev/null && gw_ok=true

if $gw_ok; then
    gw_fails=$(read_count "$GW_STATE_FILE")
    [ "$gw_fails" -gt 0 ] && logger -t "$LOG_TAG" "Gateway recovered after ${gw_fails} failed check(s)"
    echo 0 > "$GW_STATE_FILE"

    soft_fails=$(read_count "$SOFT_STATE_FILE")
    [ "$soft_fails" -gt 0 ] && logger -t "$LOG_TAG" "Transient-ICMP-loss state cleared after ${soft_fails} check(s)"
    echo 0 > "$SOFT_STATE_FILE"

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

if assoc_ok; then
    # wlan0 is still connected per NetworkManager -- the gateway ping failure
    # is most likely transient ICMP loss, not a real WiFi problem. Track
    # separately and remedy gently; never escalate to a radio bounce or
    # NetworkManager restart off this signal alone.
    echo 0 > "$GW_STATE_FILE"
    soft_fails=$(($(read_count "$SOFT_STATE_FILE") + 1))
    echo "$soft_fails" > "$SOFT_STATE_FILE"
    logger -t "$LOG_TAG" "Gateway ping failed but wlan0 still connected, likely transient ICMP loss (${soft_fails})"

    if [ "$soft_fails" -eq 5 ] || [ "$soft_fails" -eq 15 ]; then
        logger -t "$LOG_TAG" "Soft reconnect (associated but unreachable): nmcli connection up ${WIFI_CONN}"
        nmcli connection up "$WIFI_CONN" &>/dev/null
    elif [ "$soft_fails" -eq 30 ]; then
        logger -t "$LOG_TAG" "Radio bounce (sustained transient-ICMP state, soft reconnects didn't clear it)"
        nmcli radio wifi off
        sleep 3
        nmcli radio wifi on
    elif [ "$soft_fails" -eq 60 ] || { [ "$soft_fails" -gt 60 ] && [ $((soft_fails % 60)) -eq 0 ]; }; then
        logger -t "$LOG_TAG" "Restarting NetworkManager (sustained transient-ICMP state)"
        service network-manager restart &>/dev/null
        sleep 5
        nmcli connection up "$WIFI_CONN" &>/dev/null
    fi
    exit 0
fi

# wlan0 is not connected at all per NetworkManager -- this is a real WiFi
# problem, escalate as before.
echo 0 > "$SOFT_STATE_FILE"
gw_fails=$(($(read_count "$GW_STATE_FILE") + 1))
echo "$gw_fails" > "$GW_STATE_FILE"
logger -t "$LOG_TAG" "wlan0 not connected, no default gateway reachable (${gw_fails})"

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
