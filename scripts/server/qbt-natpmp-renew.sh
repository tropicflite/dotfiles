#!/bin/bash
# Keeps qBittorrent's forwarded port alive through ProtonVPN's NAT-PMP gateway.
#
# ProtonVPN does NOT honor a requested public port, but DOES honor the requested
# private port exactly, and keeps returning the SAME public port on repeated
# renewals of that same private-port mapping (confirmed empirically 2026-07-05:
# changing the private port gets a fresh random public port each time; renewing
# the same private port stays stable). So the private port is fixed forever at
# 6881 (== qBittorrent's listen_port, never changes) and only the dynamic public
# port needs to flow anywhere — into qBittorrent's `announce_port` preference,
# which libtorrent uses to tell trackers a different port than it's actually
# bound to. This means the inbound firewall rule (wg0:6881 -> qbittorrent
# container) is static and lives in wg0-up-extra.sh instead of here; this script
# never touches iptables.
#
# NAT-PMP lease is capped at 60s regardless of what's requested — renew well
# before that (see SLEEP_INTERVAL below) or the mapping (and the assigned public
# port) is lost and has to be re-established from scratch.

GATEWAY="10.2.0.1"
PORT=6881
LOG_TAG="qbt-natpmp"
STATE_DIR="${HOME}/.local/state/qbt-natpmp"
STATE_FILE="${STATE_DIR}/announce_port"
QBT_ENV="/home/matt/docker/homepage/.env"

mkdir -p "$STATE_DIR"

send_ntfy() {
    local title="$1" body="$2" priority="${3:-default}" tags="${4:-warning}"
    /usr/local/bin/send-alert "$title" "$body" "$priority" "$tags"
}

get_qbt_ip() {
    docker inspect qbittorrent --format '{{.NetworkSettings.Networks.arrs.IPAddress}}' 2>/dev/null
}

set_announce_port() {
    local port="$1"
    local qbt_ip qbt_pass cookie_jar
    qbt_ip=$(get_qbt_ip)
    if [ -z "$qbt_ip" ]; then
        logger -t "$LOG_TAG" "qBittorrent container not reachable, can't update announce_port"
        return 1
    fi
    qbt_pass=$(grep -oP "(?<=^QBIT_PASSWORD=').*(?=')" "$QBT_ENV")
    cookie_jar=$(mktemp)
    curl -s -c "$cookie_jar" --data-urlencode "username=admin" --data-urlencode "password=${qbt_pass}" \
        "http://${qbt_ip}:8080/api/v2/auth/login" > /dev/null
    curl -s -b "$cookie_jar" --data-urlencode "json={\"announce_port\": ${port}}" \
        "http://${qbt_ip}:8080/api/v2/app/setPreferences" > /dev/null
    local result=$?
    rm -f "$cookie_jar"
    return $result
}

LAST_SUCCESS_EPOCH=0
LAST_LIFETIME=60
ALERTED=false

while true; do
    UDP_OUT=$(natpmpc -g "$GATEWAY" -a "$PORT" "$PORT" udp 60 2>&1)
    TCP_OUT=$(natpmpc -g "$GATEWAY" -a "$PORT" "$PORT" tcp 60 2>&1)

    UDP_PORT=$(grep -oP 'Mapped public port \K\d+' <<< "$UDP_OUT")
    TCP_PORT=$(grep -oP 'Mapped public port \K\d+' <<< "$TCP_OUT")
    TCP_LIFETIME=$(grep -oP 'lifetime \K\d+' <<< "$TCP_OUT")

    if [ -z "$TCP_PORT" ] || [ -z "$UDP_PORT" ]; then
        logger -t "$LOG_TAG" "natpmpc request failed (udp: ${UDP_OUT##*$'\n'}; tcp: ${TCP_OUT##*$'\n'})"
        if ! $ALERTED && [ "$(date +%s)" -gt "$((LAST_SUCCESS_EPOCH + LAST_LIFETIME))" ]; then
            send_ntfy "[server] qBittorrent NAT-PMP forwarding down" \
                "natpmpc has failed to renew the port mapping and the previous lease has expired — qBittorrent is back to outbound-only. Check ProtonVPN/wg0 connectivity." \
                high warning
            ALERTED=true
        fi
        sleep 15
        continue
    fi

    if [ "$TCP_PORT" != "$UDP_PORT" ]; then
        logger -t "$LOG_TAG" "WARNING: tcp mapped port ($TCP_PORT) != udp mapped port ($UDP_PORT), using tcp"
    fi

    LAST_SUCCESS_EPOCH=$(date +%s)
    LAST_LIFETIME="${TCP_LIFETIME:-60}"

    if $ALERTED; then
        send_ntfy "[server] qBittorrent NAT-PMP forwarding recovered" \
            "Port mapping re-established (public port ${TCP_PORT})." \
            default white_check_mark
        ALERTED=false
    fi

    PREV_PORT=$(cat "$STATE_FILE" 2>/dev/null || echo "")
    if [ "$TCP_PORT" != "$PREV_PORT" ]; then
        if set_announce_port "$TCP_PORT"; then
            echo "$TCP_PORT" > "$STATE_FILE"
            logger -t "$LOG_TAG" "announce_port updated: ${PREV_PORT:-none} -> ${TCP_PORT}"
        else
            logger -t "$LOG_TAG" "failed to update qBittorrent announce_port to ${TCP_PORT}, will retry next cycle"
        fi
    fi

    SLEEP_INTERVAL=$(( LAST_LIFETIME / 2 ))
    [ "$SLEEP_INTERVAL" -lt 20 ] && SLEEP_INTERVAL=20
    sleep "$SLEEP_INTERVAL"
done
