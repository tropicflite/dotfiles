#!/bin/bash
set -euo pipefail

# vpn-diskcheck.sh
# Checks VPN connectivity and disk space, sends email alerts
# Cron: */5 * * * * /home/matt/dotfiles/scripts/server/vpn-diskcheck.sh

ALERT_EMAIL="nichols_matt@pm.me"
VPN_TEST_IP="1.1.1.1"
DISK_THRESHOLD=85
LOG_TAG="vpn-diskcheck"
RUNTIME_DIR="/run/user/$(id -u)"

send_email() {
    local subject="$1"
    local body="$2"
    printf "To: %s\nSubject: [Server] %s\n\n%b\n" \
        "$ALERT_EMAIL" "$subject" "$body" | msmtp "$ALERT_EMAIL" || true
}

send_ntfy() {
    local title="$1" body="$2" priority="${3:-default}" tags="${4:-warning}"
    local pass
    pass=$(cat /home/matt/.config/ntfy/password 2>/dev/null) || return 0
    curl -s -u "matt:$pass" \
        -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" \
        -d "$body" http://localhost:2586/server-alerts > /dev/null || true
}

# ── Crash trap ───────────────────────────────────────────────────────────────
trap '_ec=$?
if [ "$_ec" -ne 0 ]; then
    _pass=$(cat /home/matt/.config/ntfy/password 2>/dev/null)
    [ -n "$_pass" ] && curl -s -u "matt:$_pass" \
        -H "Title: [server] vpn-diskcheck crashed" \
        -H "Priority: high" -H "Tags: rotating_light" \
        -d "vpn-diskcheck.sh crashed (exit ${_ec}) on $(hostname) at $(date). VPN kill switch may not have fired." \
        http://localhost:2586/server-alerts > /dev/null || true
fi' EXIT

# ── VPN Check ────────────────────────────────────────────────────────────────

VPN_FLAG="$RUNTIME_DIR/vpn_was_down"

if ping -c 2 -W 5 -I wg0 "$VPN_TEST_IP" > /dev/null 2>&1; then
    # VPN is up
    if [[ -f "$VPN_FLAG" ]]; then
        # Was down before, now recovered
        rm -f "$VPN_FLAG"
        systemctl start qbittorrent-compose.service
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
        logger -t "$LOG_TAG" "VPN down — stopping qbittorrent"
        systemctl stop qbittorrent-compose.service
        send_email "VPN DOWN — qBittorrent stopped" \
            "WireGuard VPN is DOWN on $(hostname) at $(date).\n\nqBittorrent has been stopped to prevent unprotected traffic.\n\nCheck wg0 and wg-watchdog status."
        send_ntfy "[server] VPN DOWN — qBittorrent stopped" \
            "WireGuard VPN is DOWN on $(hostname) at $(date). qBittorrent stopped." high rotating_light
    fi
    # If flag already exists, already alerted — don't spam
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
