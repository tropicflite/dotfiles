#!/bin/bash
WG_CONF="/etc/wireguard/wg0.conf"
ENDPOINT_NAME="ProtonVPN"
WG_IFACE="wg0"
LOG_TAG="wg-watchdog"

BASE_SLEEP=30        # normal poll interval when healthy
MAX_BACKOFF=300       # cap retry interval once a failure is confirmed persistent (5 min)
ALERT_REPEAT_SECS=900 # while still down, re-alert at most this often (15 min)

# Tunnel health check tuning (rewritten 2026-07-26 — see tunnel_healthy()).
# HANDSHAKE_MAX_AGE: WireGuard rekeys every ~120s while traffic flows, and
#   PersistentKeepalive=25 forces a handshake even when idle. 180s gives a
#   full rekey interval of slack before we call a handshake stale.
# HEALTH_STRIKES: consecutive confirmed failures required before bouncing.
#   The old check had no strike rule at all, so a single lost probe pair was
#   enough to tear down the interface.
# STRIKE_SLEEP: extra gap between strikes. A strike iteration also pays the
#   loop's own CUR_BACKOFF sleep, so at the healthy 30s poll interval three
#   strikes cost roughly 80s of detection latency before a real fault is
#   acted on — a deliberate trade against the old check's zero-latency,
#   high-false-positive behaviour.
HANDSHAKE_MAX_AGE=180
HEALTH_STRIKES=3
STRIKE_SLEEP=10
HEALTH_STRIKE_COUNT=0
# Probes address hard-coded IPs, never hostnames: Pi-hole itself egresses via
# wg0, so a DNS-based probe could fail for reasons unrelated to the tunnel.
# HTTPS rather than plain HTTP because only 1.1.1.1 serves port 80 — all three
# of these resolvers present a valid cert for their own IP on 443 (verified
# 2026-07-26). Any single target answering proves the data plane works, so one
# host's outage can't masquerade as a tunnel fault.
DATAPLANE_TARGETS=(https://1.1.1.1 https://8.8.8.8 https://9.9.9.9)

# Auto-failover: after the primary endpoint has been continuously unreachable
# this long, switch to the standby ProtonVPN profile instead of continuing to
# retry the same dead endpoint. Chosen from the 2026-07-25 outage (2.5h flap,
# endpoint was ISP/Proton-side and self-recovered) — long enough to not
# fail over on a routine few-minute blip, short enough to cut a multi-hour
# outage down dramatically. No auto-failback: switching back to primary once
# it recovers is a manual call (`sudo wg-switch primary`) to avoid flapping
# if the failed endpoint is intermittently flaky rather than fully down.
FAILOVER_THRESHOLD_SECS=300
PROFILES_DIR="/etc/wireguard/profiles"
FAILED_OVER_THIS_INCIDENT=0
# Separate from FAILED_OVER_THIS_INCIDENT (which means "already switched
# successfully, don't try again"): this only dedupes alerts for the three
# ways the failover *attempt itself* can go wrong, so each still retries
# every cycle (in case a switch failure was transient) without re-alerting
# every ~5min while the same underlying problem persists.
FAILOVER_ISSUE_ALERTED_THIS_INCIDENT=0

get_endpoint_ip() {
    # Read live rather than hardcode: wg-switch.sh can repoint wg0.conf at a
    # different profile/endpoint entirely, and a stale hardcoded IP here would
    # mean the watchdog keeps pinging (and failing over away from) the wrong
    # server after a switch.
    grep -m1 '^Endpoint' "$WG_CONF" 2>/dev/null | sed -E 's/^Endpoint\s*=\s*([^:]+):.*/\1/'
}

handshake_age() {
    # Seconds since the peer last completed a handshake; -1 if never.
    local hs now
    hs=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    if [[ -z "$hs" || "$hs" == "0" ]]; then echo -1; return; fi
    now=$(date +%s)
    echo $(( now - hs ))
}

dataplane_ok() {
    local h
    for h in "${DATAPLANE_TARGETS[@]}"; do
        curl -s --interface "$WG_IFACE" --max-time 8 -o /dev/null "$h" && return 0
    done
    return 1
}

# Replaces the old `ping -c 2 -W 5 -I wg0 <endpoint>` check (2026-07-26).
# That check was wrong in two independent ways and produced 71 spurious
# teardowns in a single day (plus 125 ntfy alerts, 10 qBittorrent kill-switch
# stop/start cycles, and a Migadu daily-cap hit):
#
#   1. Wrong target. It pinged the endpoint's PUBLIC IP *through the tunnel* —
#      a hairpin back to the server's own outer address that Proton has no
#      obligation to answer — and did it over ICMP, which is routinely
#      deprioritised and rate-limited on path. Measured 4.5-13% loss to that
#      target at a moment when 40/40 HTTPS fetches through the same tunnel
#      succeeded and the handshake was fresh. It measured path ICMP policy,
#      not tunnel health.
#   2. No strike rule. `-c 2` means both probes had to survive; one bursty
#      two-packet loss bounced wg0 immediately.
#
# The authoritative liveness signal is WireGuard's own handshake age: a
# handshake younger than HANDSHAKE_MAX_AGE means the peer is cryptographically
# proven to be answering us. Only when that looks stale do we spend a real
# data-plane probe, and only HEALTH_STRIKES consecutive confirmed failures
# trigger a bounce.
tunnel_healthy() {
    local age
    age=$(handshake_age)
    (( age >= 0 && age <= HANDSHAKE_MAX_AGE )) && return 0
    # A stale handshake is necessary but not sufficient evidence of a fault,
    # so confirm with real traffic before acting on it.
    dataplane_ok
}

current_profile() {
    # Distinguish primary vs failover by comparing the live peer PublicKey
    # against each profile file, rather than tracking separate state that
    # could drift from what's actually loaded.
    local live_pubkey
    live_pubkey=$(grep -m1 '^PublicKey' "$WG_CONF" 2>/dev/null)
    if [[ -f "$PROFILES_DIR/wg0-primary.conf" ]] && grep -qF "$live_pubkey" "$PROFILES_DIR/wg0-primary.conf"; then
        echo "primary"
    elif [[ -f "$PROFILES_DIR/wg0-failover.conf" ]] && grep -qF "$live_pubkey" "$PROFILES_DIR/wg0-failover.conf"; then
        echo "failover"
    else
        echo "unknown"
    fi
}

failover_if_due() {
    local now down_for other
    now=$(date +%s)
    down_for=$(( now - INCIDENT_START ))
    (( down_for < FAILOVER_THRESHOLD_SECS )) && return
    (( FAILED_OVER_THIS_INCIDENT )) && return

    case "$(current_profile)" in
        primary)  other="failover" ;;
        failover) other="primary" ;;
        *)
            logger -t "$LOG_TAG" "Cannot determine current profile, skipping auto-failover"
            if (( ! FAILOVER_ISSUE_ALERTED_THIS_INCIDENT )); then
                send_ntfy "[server] wg0 auto-failover blocked" \
                    "Endpoint down ${down_for}s but the active profile couldn't be determined (wg0.conf's PublicKey matches neither wg0-primary.conf nor wg0-failover.conf) — auto-failover skipped. Needs manual intervention: check /etc/wireguard/wg0.conf and /etc/wireguard/profiles/." \
                    high rotating_light
                FAILOVER_ISSUE_ALERTED_THIS_INCIDENT=1
            fi
            return
            ;;
    esac

    if [[ ! -x /usr/local/bin/wg-switch.sh ]]; then
        logger -t "$LOG_TAG" "wg-switch.sh missing/not executable, skipping auto-failover"
        if (( ! FAILOVER_ISSUE_ALERTED_THIS_INCIDENT )); then
            send_ntfy "[server] wg0 auto-failover blocked" \
                "Endpoint down ${down_for}s but /usr/local/bin/wg-switch.sh is missing or not executable — auto-failover skipped. Needs manual intervention." \
                high rotating_light
            FAILOVER_ISSUE_ALERTED_THIS_INCIDENT=1
        fi
        return
    fi

    logger -t "$LOG_TAG" "Endpoint down ${down_for}s, auto-failing over to $other"
    if /usr/local/bin/wg-switch.sh "$other"; then
        # Latched until a genuine recovery (ping success) clears it in
        # record_recovery — deliberately NOT reset here, so if the new
        # profile also goes down we bounce/retry/alert on it same as before
        # this feature existed, rather than flapping back and forth between
        # the two endpoints every FAILOVER_THRESHOLD_SECS.
        FAILED_OVER_THIS_INCIDENT=1
        send_ntfy "[server] wg0 auto-failed over to $other" \
            "Primary endpoint unreachable for ${down_for}s; switched to the $other ProtonVPN profile. Run 'sudo wg-switch primary' once the original is confirmed healthy — this does not fail back automatically." \
            high rotating_light
        # Reset the incident/backoff bookkeeping so the new endpoint is
        # monitored fresh, without emitting a recovery alert for what was
        # never actually a success against the old endpoint.
        CUR_FAIL_TYPE=""
        CONSEC_FAILS=0
        CUR_BACKOFF=$BASE_SLEEP
    else
        logger -t "$LOG_TAG" "wg-switch.sh $other failed"
        if (( ! FAILOVER_ISSUE_ALERTED_THIS_INCIDENT )); then
            send_ntfy "[server] wg0 auto-failover attempt failed" \
                "Endpoint down ${down_for}s; attempted to switch to the $other profile but wg-switch.sh exited non-zero. wg0 may be in an inconsistent state — check manually (sudo wg show wg0, journalctl -t wg-switch)." \
                high rotating_light
            FAILOVER_ISSUE_ALERTED_THIS_INCIDENT=1
        fi
    fi
}

send_ntfy() {
    local title="$1" body="$2" priority="${3:-default}" tags="${4:-warning}"
    # No public-ntfy.sh fallback (removed 2026-07-02): the topic ID was committed
    # to dotfiles, making alert contents world-readable. Box-level outage
    # detection is healthchecks.io's job now; local ntfy failure alone is
    # covered by email from the other monitors.
    /usr/local/bin/send-alert "$title" "$body" "$priority" "$tags"
}

# Failures often come from an upstream condition (e.g. an ISP UDP block) that
# bouncing the interface can't fix — retrying every 30s just thrashes wg0 and
# forces a full tailscaled rebind each time, and spams an alert per attempt.
# Back off the retry interval while a given failure persists, and throttle
# alerts to one on onset + at most one per ALERT_REPEAT_SECS while it continues.
CUR_FAIL_TYPE=""
CONSEC_FAILS=0
INCIDENT_START=0
LAST_ALERT=0
CUR_BACKOFF=$BASE_SLEEP

record_failure() {
    local type="$1" title="$2" body="$3"
    local now
    now=$(date +%s)

    if [[ "$CUR_FAIL_TYPE" != "$type" ]]; then
        CUR_FAIL_TYPE="$type"
        CONSEC_FAILS=0
        INCIDENT_START=$now
        CUR_BACKOFF=$BASE_SLEEP
    fi
    CONSEC_FAILS=$((CONSEC_FAILS + 1))

    if [[ $CONSEC_FAILS -eq 1 ]]; then
        send_ntfy "$title" "$body"
        LAST_ALERT=$now
    elif (( now - LAST_ALERT >= ALERT_REPEAT_SECS )); then
        local down_for=$(( (now - INCIDENT_START) / 60 ))
        send_ntfy "$title (still down)" "$body Still failing after $CONSEC_FAILS attempts, down ~${down_for}m."
        LAST_ALERT=$now
    fi

    CUR_BACKOFF=$(( CUR_BACKOFF * 2 ))
    (( CUR_BACKOFF > MAX_BACKOFF )) && CUR_BACKOFF=$MAX_BACKOFF
}

record_recovery() {
    local title="$1"
    if [[ -n "$CUR_FAIL_TYPE" && $CONSEC_FAILS -gt 0 ]]; then
        local now down_for
        now=$(date +%s)
        down_for=$(( now - INCIDENT_START ))
        send_ntfy "$title" "Recovered after $CONSEC_FAILS attempts, down $(( down_for / 60 ))m $(( down_for % 60 ))s." default white_check_mark
    fi
    CUR_FAIL_TYPE=""
    CONSEC_FAILS=0
    CUR_BACKOFF=$BASE_SLEEP
    FAILED_OVER_THIS_INCIDENT=0
    FAILOVER_ISSUE_ALERTED_THIS_INCIDENT=0
}

while true; do
    sleep "$CUR_BACKOFF"

    # Check if wg0 exists
    if ! ip link show "$WG_IFACE" &>/dev/null; then
        logger -t "$LOG_TAG" "wg0 missing, bringing interface back up"
        wg-quick down "$WG_IFACE" 2>/dev/null; wg-quick up "$WG_IFACE"
        record_failure "wg0 interface missing" "[server] wg0 interface missing — bounced" "wg0 interface was missing; brought back up at $(date)."
        sleep 15
        continue
    fi

    # Tunnel health: handshake age first, data-plane probe only as a
    # tie-breaker, and HEALTH_STRIKES consecutive failures before acting.
    # An empty CUR_ENDPOINT_IP still counts as a fault — it means wg0.conf is
    # missing or malformed, which failover_if_due needs to see.
    CUR_ENDPOINT_IP=$(get_endpoint_ip)
    if [[ -n "$CUR_ENDPOINT_IP" ]] && tunnel_healthy; then
        HEALTH_STRIKE_COUNT=0
        [[ "$CUR_FAIL_TYPE" == "wg0 interface missing" || "$CUR_FAIL_TYPE" == "WireGuard endpoint unreachable" ]] && \
            record_recovery "[server] wg0 back up"
    else
        HEALTH_STRIKE_COUNT=$(( HEALTH_STRIKE_COUNT + 1 ))
        if (( HEALTH_STRIKE_COUNT < HEALTH_STRIKES )); then
            logger -t "$LOG_TAG" "Tunnel health check failed (strike ${HEALTH_STRIKE_COUNT}/${HEALTH_STRIKES}), re-checking"
            sleep "$STRIKE_SLEEP"
            continue
        fi
        logger -t "$LOG_TAG" "Tunnel unhealthy after ${HEALTH_STRIKES} consecutive checks, bouncing wg0 interface"
        wg-quick down "$WG_IFACE" 2>/dev/null; wg-quick up "$WG_IFACE"
        record_failure "WireGuard endpoint unreachable" "[server] WireGuard endpoint unreachable — bounced" "$ENDPOINT_NAME tunnel failed ${HEALTH_STRIKES} consecutive health checks (stale handshake and no data plane through $WG_IFACE); interface bounced at $(date)."
        HEALTH_STRIKE_COUNT=0
        failover_if_due
        sleep 15
        continue
    fi

    # Check if Tailscale can reach the coordination server
    if ! tailscale status 2>&1 | grep -q "coordination server" ; then
        # No coordination server complaint, Tailscale is healthy
        [[ "$CUR_FAIL_TYPE" == "Tailscale coordination unreachable" ]] && \
            record_recovery "[server] Tailscale coordination back"
        continue
    fi

    logger -t "$LOG_TAG" "Tailscale coordination server unreachable, restarting tailscaled"
    tailscale down
    tailscale up --accept-dns=false --operator=matt --advertise-routes=10.0.0.0/24,192.168.50.0/24 --hostname=server --advertise-exit-node
    record_failure "Tailscale coordination unreachable" "[server] Tailscale coordination unreachable — restarted" "Tailscale coordination server was unreachable; tailscaled bounced at $(date)."
done
