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
# Periodic forced data-plane probe (added 2026-07-26, second pass).
# Handshake-age-as-primary closed the false-POSITIVE problem but opened a
# false-NEGATIVE one: if the peer keeps completing handshakes while dropping
# actual traffic, a fresh handshake alone reads as healthy forever and the
# watchdog never acts. Every DATAPLANE_EVERY_N cycles we therefore ignore the
# handshake and require a real data-plane probe to pass. At BASE_SLEEP=30 that
# is roughly every 5 minutes while healthy. DATAPLANE_COUNTDOWN starts at 0 so
# the first check after startup is a forced probe — a watchdog restart is
# exactly when confirming real egress is most worthwhile.
DATAPLANE_EVERY_N=10
DATAPLANE_COUNTDOWN=0
FORCE_DATAPLANE=0
# Same strike treatment for the Tailscale coordination check further down, with
# its own counter: the two checks are independent and must not clear each
# other's strikes. Kept as a separate knob from HEALTH_STRIKES so the tunnel
# and coordination checks can be tuned apart if one proves noisier.
TS_STRIKES=3
TS_STRIKE_COUNT=0
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
#
# A fresh handshake proves the PEER is answering, not that TRAFFIC flows — the
# two can diverge (peer completing handshakes while dropping or misrouting
# payload). So when FORCE_DATAPLANE is set the handshake is ignored entirely
# and only a real data-plane probe counts. The caller sets it every
# DATAPLANE_EVERY_N cycles, and on every cycle while a failure is being
# confirmed — without that second condition a periodic probe could never
# accumulate strikes, because the intervening handshake-only cycles would
# reset the counter to zero before it ever reached HEALTH_STRIKES.
tunnel_healthy() {
    local age
    if (( FORCE_DATAPLANE )); then
        dataplane_ok
        return
    fi
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
    down_for=$(( now - TUNNEL_INCIDENT_START ))
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
        TUNNEL_FAIL_TYPE=""
        TUNNEL_CONSEC_FAILS=0
        TUNNEL_BACKOFF=$BASE_SLEEP
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
#
# Tracked per channel (TUNNEL vs TS), not in one shared slot: the tunnel and
# Tailscale coordination checks are independent (see HEALTH_STRIKE_COUNT /
# TS_STRIKE_COUNT above), but a single shared CUR_FAIL_TYPE meant a failure
# confirmed on one channel silently overwrote a still-open incident on the
# other — losing its recovery alert and down-duration entirely. CUR_BACKOFF
# stays a single loop-pacing variable, set explicitly from the acting
# channel's backoff at each call site below.
TUNNEL_FAIL_TYPE=""
TUNNEL_CONSEC_FAILS=0
TUNNEL_INCIDENT_START=0
TUNNEL_LAST_ALERT=0
TUNNEL_BACKOFF=$BASE_SLEEP

TS_FAIL_TYPE=""
TS_CONSEC_FAILS=0
TS_INCIDENT_START=0
TS_LAST_ALERT=0
TS_BACKOFF=$BASE_SLEEP

CUR_BACKOFF=$BASE_SLEEP

record_failure() {
    local channel="$1" type="$2" title="$3" body="$4"
    local -n fail_type="${channel}_FAIL_TYPE"
    local -n consec="${channel}_CONSEC_FAILS"
    local -n incident_start="${channel}_INCIDENT_START"
    local -n last_alert="${channel}_LAST_ALERT"
    local -n backoff="${channel}_BACKOFF"
    local now
    now=$(date +%s)

    if [[ "$fail_type" != "$type" ]]; then
        fail_type="$type"
        consec=0
        incident_start=$now
        backoff=$BASE_SLEEP
    fi
    consec=$((consec + 1))

    if [[ $consec -eq 1 ]]; then
        send_ntfy "$title" "$body"
        last_alert=$now
    elif (( now - last_alert >= ALERT_REPEAT_SECS )); then
        local down_for=$(( (now - incident_start) / 60 ))
        send_ntfy "$title (still down)" "$body Still failing after $consec attempts, down ~${down_for}m."
        last_alert=$now
    fi

    backoff=$(( backoff * 2 ))
    (( backoff > MAX_BACKOFF )) && backoff=$MAX_BACKOFF
}

record_recovery() {
    local channel="$1" title="$2"
    local -n fail_type="${channel}_FAIL_TYPE"
    local -n consec="${channel}_CONSEC_FAILS"
    local -n incident_start="${channel}_INCIDENT_START"
    local -n backoff="${channel}_BACKOFF"
    if [[ -n "$fail_type" && $consec -gt 0 ]]; then
        local now down_for
        now=$(date +%s)
        down_for=$(( now - incident_start ))
        send_ntfy "$title" "Recovered after $consec attempts, down $(( down_for / 60 ))m $(( down_for % 60 ))s." default white_check_mark
    fi
    fail_type=""
    consec=0
    backoff=$BASE_SLEEP
    if [[ "$channel" == "TUNNEL" ]]; then
        FAILED_OVER_THIS_INCIDENT=0
        FAILOVER_ISSUE_ALERTED_THIS_INCIDENT=0
    fi
}

while true; do
    sleep "$CUR_BACKOFF"

    # Check if wg0 exists
    if ! ip link show "$WG_IFACE" &>/dev/null; then
        logger -t "$LOG_TAG" "wg0 missing, bringing interface back up"
        wg-quick down "$WG_IFACE" 2>/dev/null; wg-quick up "$WG_IFACE"
        record_failure TUNNEL "wg0 interface missing" "[server] wg0 interface missing — bounced" "wg0 interface was missing; brought back up at $(date)."
        CUR_BACKOFF=$TUNNEL_BACKOFF
        sleep 15
        continue
    fi

    # Tunnel health: handshake age first, data-plane probe only as a
    # tie-breaker, and HEALTH_STRIKES consecutive failures before acting.
    # An empty CUR_ENDPOINT_IP still counts as a fault — it means wg0.conf is
    # missing or malformed, which failover_if_due needs to see.
    CUR_ENDPOINT_IP=$(get_endpoint_ip)
    # Decide whether this cycle must prove itself with real traffic rather than
    # accepting a fresh handshake. See the DATAPLANE_EVERY_N comment at the top
    # and tunnel_healthy() for why the strike-count condition is required.
    # `-n "$TUNNEL_FAIL_TYPE"` is what makes RECOVERY honest: after a bounce
    # that did not actually fix things, the countdown has been reset, so
    # without it the very next cycle would accept a fresh handshake, call the
    # tunnel healthy and emit a "wg0 back up" alert while traffic was still
    # dead. While a tunnel incident is unresolved, recovery must be proven by
    # real egress.
    if (( DATAPLANE_COUNTDOWN <= 0 || HEALTH_STRIKE_COUNT > 0 )) || [[ -n "$TUNNEL_FAIL_TYPE" ]]; then
        FORCE_DATAPLANE=1
        DATAPLANE_COUNTDOWN=$DATAPLANE_EVERY_N
    else
        FORCE_DATAPLANE=0
        DATAPLANE_COUNTDOWN=$(( DATAPLANE_COUNTDOWN - 1 ))
    fi
    if [[ -n "$CUR_ENDPOINT_IP" ]] && tunnel_healthy; then
        HEALTH_STRIKE_COUNT=0
        [[ "$TUNNEL_FAIL_TYPE" == "wg0 interface missing" || "$TUNNEL_FAIL_TYPE" == "WireGuard endpoint unreachable" ]] && \
            { record_recovery TUNNEL "[server] wg0 back up"; CUR_BACKOFF=$BASE_SLEEP; }
        # Bug fixed 2026-08-18: failover_if_due() blanks TUNNEL_FAIL_TYPE right
        # after a successful switch (so the new endpoint is monitored fresh and
        # no misleading "recovered" alert fires for the OLD endpoint) — but that
        # was the only signal record_recovery used to clear FAILED_OVER_THIS_INCIDENT.
        # With TUNNEL_FAIL_TYPE already blank, the guard above can never match
        # again, so record_recovery never ran and the latch stayed 1 forever
        # after a device's first auto-failover — permanently disabling
        # auto-failover until the watchdog itself restarted. Confirmed: the
        # latch set 2026-08-13 03:57 sat unresettable through a 758s-down
        # incident on 2026-08-18 that should have triggered a second failover
        # and silently didn't. Clear it here, independent of the alert-suppression
        # logic above, the first time the (possibly-new) endpoint proves healthy.
        if (( FAILED_OVER_THIS_INCIDENT )); then
            FAILED_OVER_THIS_INCIDENT=0
            FAILOVER_ISSUE_ALERTED_THIS_INCIDENT=0
            logger -t "$LOG_TAG" "Post-failover endpoint confirmed healthy, auto-failover latch cleared"
        fi
    else
        # Describe *which* signal failed. A fresh handshake with a dead data
        # plane is a materially different fault from an unreachable peer — it
        # points at routing/egress rather than the tunnel itself — and the
        # whole point of this session's work was that a misleading health
        # signal is worse than none.
        if [[ -z "$CUR_ENDPOINT_IP" ]]; then
            FAIL_DETAIL="wg0.conf is missing or has no Endpoint= line"
        elif (( FORCE_DATAPLANE )); then
            FAIL_DETAIL="data-plane probe failed with handshake age $(handshake_age)s — peer may be handshaking while traffic is dropped or misrouted"
        else
            FAIL_DETAIL="handshake stale (age $(handshake_age)s) and data-plane probe failed"
        fi
        HEALTH_STRIKE_COUNT=$(( HEALTH_STRIKE_COUNT + 1 ))
        if (( HEALTH_STRIKE_COUNT < HEALTH_STRIKES )); then
            logger -t "$LOG_TAG" "Tunnel health check failed (strike ${HEALTH_STRIKE_COUNT}/${HEALTH_STRIKES}): ${FAIL_DETAIL}"
            sleep "$STRIKE_SLEEP"
            continue
        fi
        logger -t "$LOG_TAG" "Tunnel unhealthy after ${HEALTH_STRIKES} consecutive checks (${FAIL_DETAIL}), bouncing wg0 interface"
        wg-quick down "$WG_IFACE" 2>/dev/null; wg-quick up "$WG_IFACE"
        record_failure TUNNEL "WireGuard endpoint unreachable" "[server] WireGuard endpoint unreachable — bounced" "$ENDPOINT_NAME tunnel failed ${HEALTH_STRIKES} consecutive health checks through $WG_IFACE: ${FAIL_DETAIL}. Interface bounced at $(date)."
        CUR_BACKOFF=$TUNNEL_BACKOFF
        HEALTH_STRIKE_COUNT=0
        failover_if_due
        sleep 15
        continue
    fi

    # Check if Tailscale can reach the coordination server
    if ! tailscale status 2>&1 | grep -q "coordination server" ; then
        # No coordination server complaint, Tailscale is healthy
        TS_STRIKE_COUNT=0
        [[ "$TS_FAIL_TYPE" == "Tailscale coordination unreachable" ]] && \
            { record_recovery TS "[server] Tailscale coordination back"; CUR_BACKOFF=$BASE_SLEEP; }
        continue
    fi

    # Strike rule added 2026-07-26, same reasoning as the tunnel check above and
    # matching ssh-watchdog.sh's existing FAIL_COUNT/MAX_FAILS convention.
    # `tailscale down`/`up` is not a free retry: it forces a full re-registration
    # with control and re-inserts ts-forward at FORWARD position 1, churning the
    # iptables rules wg0-up-extra.sh installs (documented race, see that script).
    # A genuine 35s WAN blip on 2026-07-26 was enough to fire it, and the restart
    # produced a knock-on spurious qBittorrent NAT-PMP down/recovered pair —
    # the blip itself would have self-healed with no intervention at all.
    TS_STRIKE_COUNT=$(( TS_STRIKE_COUNT + 1 ))
    if (( TS_STRIKE_COUNT < TS_STRIKES )); then
        logger -t "$LOG_TAG" "Tailscale coordination unreachable (strike ${TS_STRIKE_COUNT}/${TS_STRIKES}), re-checking"
        sleep "$STRIKE_SLEEP"
        continue
    fi

    logger -t "$LOG_TAG" "Tailscale coordination unreachable after ${TS_STRIKES} consecutive checks, restarting tailscaled"
    tailscale down
    tailscale up --accept-dns=false --operator=matt --advertise-routes=10.0.0.0/24,192.168.50.0/24 --hostname=server --advertise-exit-node
    # Close the race documented above: `tailscale up` just recreated ts-forward
    # from scratch, which wipes the ts-forward-internal copies of the exit-node
    # kill switch and IPv6 REJECT rule that wg0-up-extra.sh installs (it only
    # runs on a wg0-triggered PostUp, not a Tailscale-triggered restart like
    # this one). Without this, exit-node traffic loses its actual protection —
    # ts-forward's own MARK/ACCEPT terminates traversal before the FORWARD-chain
    # copy is ever reached — silently, until the next wg0 bounce happened to
    # reinsert it. Found live via vpn-dns-regression-check.sh, 2026-08-30.
    # Idempotent and safe with wg0 already up (see that script's own header).
    /usr/local/bin/wg0-up-extra.sh
    TS_STRIKE_COUNT=0
    record_failure TS "Tailscale coordination unreachable" "[server] Tailscale coordination unreachable — restarted" "Tailscale coordination server was unreachable for ${TS_STRIKES} consecutive checks; tailscaled bounced at $(date)."
    CUR_BACKOFF=$TS_BACKOFF
done
