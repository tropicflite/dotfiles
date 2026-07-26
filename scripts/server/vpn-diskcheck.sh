#!/bin/bash
set -euo pipefail

# vpn-diskcheck.sh
# Checks VPN connectivity and disk space, sends email alerts
# Cron: */5 * * * * /home/matt/dotfiles/scripts/server/vpn-diskcheck.sh

ALERT_EMAIL="nichols_matt@pm.me"
# Still used by the routing check further down (`ip route get`), which asks
# which interface traffic to this address would actually use. The VPN-up test
# no longer pings it — see vpn_up().
VPN_TEST_IP="1.1.1.1"
# Data-plane probe targets for vpn_up(). Hard-coded IPs, never hostnames:
# Pi-hole itself egresses via wg0, so a DNS-dependent probe could fail for
# reasons unrelated to the tunnel. HTTPS rather than plain HTTP because only
# 1.1.1.1 serves port 80; all three present a valid cert for their own IP.
VPN_PROBE_URLS=(https://1.1.1.1 https://8.8.8.8 https://9.9.9.9)
VPN_PROBE_ATTEMPTS=3
DISK_THRESHOLD=85
LOG_TAG="vpn-diskcheck"
# /tmp, not /run/user/$(id -u) — the latter is torn down by systemd-logind
# whenever matt's last SSH session closes (Linger=no), which silently wiped
# these dedup flags between cron runs and caused repeat false-positive alerts
# (11 duplicate "VPN route missing" emails 2026-07-02/03 for a route that was
# actually fine). /tmp persists for the whole day regardless of login state.
RUNTIME_DIR="/tmp"

# Set by the VPN-down/recovery branches below so the crash trap can report
# whether the kill switch actually ran before the script died, instead of guessing.
VPN_DOWN_THIS_RUN=0
VPN_RECOVERY_THIS_RUN=0
KILL_SWITCH_ACTION="n/a"

send_email() {
    local subject="$1"
    local body="$2"
    printf "To: %s\nSubject: [Server] %s\n\n%b\n" \
        "$ALERT_EMAIL" "$subject" "$body" | msmtp "$ALERT_EMAIL" || true
}

send_ntfy() {
    local title="$1" body="$2" priority="${3:-default}" tags="${4:-warning}"
    /usr/local/bin/send-alert "$title" "$body" "$priority" "$tags"
}

# ── Crash trap ───────────────────────────────────────────────────────────────
trap '_ec=$?
if [ "$_ec" -ne 0 ]; then
    if [ "$VPN_DOWN_THIS_RUN" -eq 1 ] && [ "$KILL_SWITCH_ACTION" = "stopped" ]; then
        _msg="vpn-diskcheck.sh crashed (exit ${_ec}) on $(hostname) at $(date) AFTER qBittorrent was stopped — traffic is protected, but a later check (route/disk/alert) failed. Investigate."
    elif [ "$VPN_DOWN_THIS_RUN" -eq 1 ]; then
        _msg="vpn-diskcheck.sh crashed (exit ${_ec}) on $(hostname) at $(date) BEFORE qBittorrent could be stopped — kill switch did NOT fire, traffic may be unprotected. Check sudo/systemctl."
    elif [ "$VPN_RECOVERY_THIS_RUN" -eq 1 ] && [ "$KILL_SWITCH_ACTION" = "started" ]; then
        _msg="vpn-diskcheck.sh crashed (exit ${_ec}) on $(hostname) at $(date) AFTER qBittorrent was restarted post-VPN-recovery — a later check (route/disk/alert) failed. Investigate."
    elif [ "$VPN_RECOVERY_THIS_RUN" -eq 1 ]; then
        _msg="vpn-diskcheck.sh crashed (exit ${_ec}) on $(hostname) at $(date) BEFORE qBittorrent could be restarted after VPN recovery — it is likely still stopped. Check sudo/systemctl."
    else
        _msg="vpn-diskcheck.sh crashed (exit ${_ec}) on $(hostname) at $(date); VPN was already up/down with no state change this run, so the kill switch was not involved. Check the route/disk checks or send-alert connectivity."
    fi
    /usr/local/bin/send-alert "[server] vpn-diskcheck crashed" "$_msg" high rotating_light
fi' EXIT

# ── VPN Check ────────────────────────────────────────────────────────────────

VPN_FLAG="$RUNTIME_DIR/vpn_was_down"

# Replaces `ping -c 2 -W 5 -I wg0 1.1.1.1` (2026-07-26). That check measured
# path ICMP policy, not tunnel health. 1.1.1.1 rate-limits echo aggressively —
# 63% loss measured through this tunnel at a moment when 40/40 HTTPS fetches
# through the same tunnel succeeded and the WireGuard handshake was fresh — and
# requiring both of two probes to survive meant a single bursty loss read as a
# total VPN failure. It false-fired 11 times on 2026-07-26 alone, each firing
# stopping qBittorrent and sending an email, a direct contributor to hitting
# the Migadu daily send cap. wg-watchdog.sh had the same bug, fixed same day.
#
# Deliberately still forced through the interface (--interface wg0), preserving
# the original check's semantics: this tests whether the TUNNEL carries traffic,
# NOT whether traffic uses it by default. The routing check further below is
# what covers the latter, and the two must stay independent.
#
# Any one URL answering on any attempt proves the data plane works, so neither
# a single host's outage nor a burst of packet loss can fake a VPN failure.
# Worst case (genuine outage) this costs VPN_PROBE_ATTEMPTS * 3 * 8s of curl
# timeout plus 2 sleeps ≈ 78s, well inside the 5-minute cron interval.
vpn_up() {
    local attempt url
    for attempt in $(seq 1 "$VPN_PROBE_ATTEMPTS"); do
        for url in "${VPN_PROBE_URLS[@]}"; do
            curl -s --interface wg0 --max-time 8 -o /dev/null "$url" && return 0
        done
        if (( attempt < VPN_PROBE_ATTEMPTS )); then
            sleep 3
        fi
    done
    return 1
}

if vpn_up; then
    # VPN is up
    if [[ -f "$VPN_FLAG" ]]; then
        # Was down before, now recovered
        rm -f "$VPN_FLAG"
        VPN_RECOVERY_THIS_RUN=1
        sudo systemctl start qbittorrent-compose.service
        KILL_SWITCH_ACTION="started"
        send_email "VPN Recovered" \
            "WireGuard VPN is back up on $(hostname) at $(date)."
        send_ntfy "[server] VPN recovered" \
            "WireGuard VPN is back up on $(hostname) at $(date)." default white_check_mark
    fi
else
    # VPN is down
    if [[ ! -f "$VPN_FLAG" ]]; then
        # First time detecting it down — alert and kill qBittorrent
        touch "$VPN_FLAG"
        VPN_DOWN_THIS_RUN=1
        logger -t "$LOG_TAG" "VPN down — stopping qbittorrent"
        sudo systemctl stop qbittorrent-compose.service
        KILL_SWITCH_ACTION="stopped"
        send_email "VPN DOWN — qBittorrent stopped" \
            "WireGuard VPN is DOWN on $(hostname) at $(date).\n\nqBittorrent has been stopped to prevent unprotected traffic.\n\nCheck wg0 and wg-watchdog status."
        send_ntfy "[server] VPN DOWN — qBittorrent stopped" \
            "WireGuard VPN is DOWN on $(hostname) at $(date). qBittorrent stopped." high rotating_light
    fi
    # If flag already exists, already alerted — don't spam
fi

# ── VPN Routing Check ────────────────────────────────────────────────────────
# The vpn_up() probe above tests the TUNNEL (--interface wg0 forces it
# through, same as the ping it replaced). It does NOT test
# whether traffic actually USES the tunnel: if the main-table default route via
# wg0 is missing, the tunnel stays green while host + docker-bridge traffic
# egresses via the ISP and qBittorrent sits dead behind the kill switch. This
# exact state went undetected on 2026-07-02 (wg-watchdog bare wg-quick bounce).
#
# A single `ip route show table main default | grep wg0` snapshot walks a full
# netlink table dump, which raced Docker veth/bridge churn badly enough to
# produce 10 false-positive firings overnight on 2026-07-02/03 (both before
# and after the 2s-recheck debounce added that evening — the dump-race, not
# cron-burst timing, was the real cause). route-monitor.service (continuous
# `ip -ts monitor route`) logged zero real wg0 route events during any of the
# 10, and the diagnostic snapshot taken moments after each alert always showed
# the route present and healthy.
#
# `ip route get` instead asks the kernel to resolve one specific destination
# (a single RTM_GETROUTE FIB lookup, not a table dump), so it can't be caught
# mid-iteration by unrelated route churn on docker0/br-*. It also matches what
# we actually care about: which interface real traffic to VPN_TEST_IP would
# use. Keep the 2s recheck as a cheap second layer in case wg-watchdog is
# mid-flap.

ROUTE_FLAG="$RUNTIME_DIR/vpn_route_missing"
ROUTE_DIAG_LOG="/var/log/vpn-route-diag.log"

route_missing() {
    ip link show wg0 > /dev/null 2>&1 && ! ip route get "$VPN_TEST_IP" | head -1 | grep -q "dev wg0"
}

if route_missing; then
    sleep 2
fi

if route_missing; then
    if [[ ! -f "$ROUTE_FLAG" ]]; then
        touch "$ROUTE_FLAG"
        logger -t "$LOG_TAG" "wg0 up but main-table default route missing — traffic bypassing VPN"
        {
            echo "===== $(date -Is) ====="
            echo "--- ip route get $VPN_TEST_IP ---"; ip route get "$VPN_TEST_IP"
            echo "--- ip route show table main ---"; ip route show table main
            echo "--- ip route show table 200 ---"; ip route show table 200
            echo "--- ip rule show ---"; ip rule show
            echo "--- ip -s link show wg0 ---"; ip -s link show wg0
            echo "--- wg show wg0 ---"; sudo wg show wg0 2>&1
            echo "--- systemctl status wg0 wg-watchdog (no-pager) ---"
            systemctl status wg0.service wg-watchdog.service --no-pager -l 2>&1
        } | sudo tee -a "$ROUTE_DIAG_LOG" > /dev/null 2>&1 || true
        send_email "VPN route missing — traffic bypassing VPN" \
            "wg0 is up but the main-table default route via wg0 is missing on $(hostname) at $(date).\n\nHost and container traffic is egressing via the ISP; qBittorrent traffic is being dropped by the kill switch.\n\nFix: sudo ip route replace 0.0.0.0/0 dev wg0 metric 100\n(or: sudo systemctl restart wg0 — note this bounces the arrs/immich/filebrowser stacks via Requires=)"
        send_ntfy "[server] VPN route missing — traffic bypassing VPN" \
            "wg0 up but default route via wg0 gone. Fix: sudo ip route replace 0.0.0.0/0 dev wg0 metric 100" high rotating_light
    fi
else
    if [[ -f "$ROUTE_FLAG" ]]; then
        rm -f "$ROUTE_FLAG"
        send_ntfy "[server] VPN route restored" \
            "Main-table default route via wg0 is back on $(hostname) at $(date)." default white_check_mark
    fi
fi

# ── Disk Space Check ─────────────────────────────────────────────────────────

DISK_FLAG="$RUNTIME_DIR/disk_was_full"
DISK_ALERT=0
DISK_MSG=""

while IFS= read -r line; do
    usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')
    if [[ "$usage" -ge "$DISK_THRESHOLD" ]]; then
        DISK_ALERT=1
        DISK_MSG+="  $mount — ${usage}% used\n"
    fi
done < <(df -h | awk 'NR>1 && ($6 == "/" || $6 == "/mnt/data" || $6 == "/mnt/immich-backup")')

if [[ "$DISK_ALERT" -eq 1 ]]; then
    if [[ ! -f "$DISK_FLAG" ]]; then
        touch "$DISK_FLAG"
        send_email "Disk Space Warning" \
            "Disk usage above ${DISK_THRESHOLD}% on $(hostname) at $(date):\n\n${DISK_MSG}"
        send_ntfy "[server] Disk space warning" \
            "Disk usage above ${DISK_THRESHOLD}% on $(hostname):\n${DISK_MSG}" high warning
    fi
    # Flag already exists — already alerted, don't spam
else
    if [[ -f "$DISK_FLAG" ]]; then
        rm -f "$DISK_FLAG"
    fi
fi
