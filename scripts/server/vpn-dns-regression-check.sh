#!/bin/bash
# Regression check for the VPN/Tailscale-exit-node/DNS routing stack.
#
# This is NOT a liveness monitor (that's wg-watchdog.sh + vpn-diskcheck.sh —
# they answer "is the tunnel up right now?"). This answers a different
# question: "do all the specific fixes this stack has needed since 2026-07
# still hold?" Every check below encodes one incident from that history —
# a kill switch, a routing rule, or a DNS bypass that was fixed once,
# because state that looks fine in isolation (tunnel up, handshake fresh)
# can still be missing the one rule that made a past incident possible again.
#
# Deliberately read-only: inspects live iptables/ip state and, for two
# checks, config source files — never modifies anything. Safe to run
# on demand after touching wg0-up-extra.sh, wg-switch.sh, wg-watchdog.sh,
# or any Pi-hole/Tailscale config, in addition to its own timer.
#
# Usage: vpn-dns-regression-check.sh [-v|--report]
#   -v, --report   Print the full PASS/FAIL table (also auto-shown on a tty).
#   (no args)      Run silently except for alerting; exit 1 if anything failed.
#
# Deploy: symlinked to /usr/local/bin/vpn-dns-regression-check.sh (dotfiles.map).
# Runs via vpn-dns-regression-check.timer every 10 min, as root (no User= in
# the .service, matching wg-watchdog.service) — reading iptables/ip6tables
# state needs root. Re-execs itself under sudo for ad-hoc matt/~/bin use.

if [[ $EUID -ne 0 ]]; then
    exec sudo -E "$0" "$@"
fi

set -uo pipefail

WG_CONF="/etc/wireguard/wg0.conf"
WG_UP_EXTRA="/home/matt/dotfiles/scripts/server/wg0-up-extra.sh"
WG_WATCHDOG_SRC="/usr/local/bin/wg-watchdog.sh"
VPN_DISKCHECK_SRC="/home/matt/dotfiles/scripts/server/vpn-diskcheck.sh"
PROFILES_DIR="/etc/wireguard/profiles"
LAN_GW="192.168.50.1"
STATE_DIR="/var/tmp/vpn-dns-regression-check"
FAILING_FILE="$STATE_DIR/failing_checks"
LAST_ALERT_FILE="$STATE_DIR/last_alert_time"
LOCK_FILE="$STATE_DIR/lock"
# Real newline for building alert bodies. Plain "\n" inside a double-quoted
# bash string is never interpreted (that's zsh's/echo -e's job, not bash's) —
# found 2026-08-31 via code review, confirmed against an alert already sent:
# the body was literal backslash-n text end to end, not line breaks.
NL=$'\n'
ALERT_REPEAT_SECS=3600   # re-alert on an unresolved failure at most hourly
LOG_TAG="vpn-dns-regression-check"

mkdir -p "$STATE_DIR"

REPORT=0
[[ "${1:-}" == "-v" || "${1:-}" == "--report" ]] && REPORT=1
[[ -t 1 ]] && REPORT=1

PROTON_ENDPOINT=$(grep -m1 '^Endpoint' "$WG_CONF" 2>/dev/null | sed -E 's/^Endpoint\s*=\s*([^:]+):.*/\1/')
TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
[[ -z "$TS_IP" ]] && TS_IP="100.65.250.53"   # fallback: known tailnet IP (see CLAUDE.md)

declare -A DETAIL
declare -A LABEL
CHECKS=()

add_check() { CHECKS+=("$1"); LABEL["$1"]="$2"; }

add_check exitnode_ks_forward   "Exit-node kill switch (FORWARD)"
add_check exitnode_ks_tsforward "Exit-node kill switch (inside ts-forward)"
add_check qbt_ks_forward        "qBittorrent kill switch (FORWARD)"
add_check ts_exit_mark_wired    "TS_EXIT_MARK chain wired from mangle PREROUTING"
add_check ts_exit_mark_exempt   "TS_EXIT_MARK exempts Tailscale mesh/LAN traffic (not just exit-node)"
add_check fwmark_ip_rule        "fwmark 0x200 -> table 200 ip rule"
add_check table200_default      "table 200 default route via wg0"
add_check table200_pihole       "table 200 route to Pi-hole (br-pihole)"
add_check table200_endpoint_pin "table 200 ProtonVPN endpoint pinned via LAN"
add_check maintable_endpoint_pin "main table ProtonVPN endpoint pinned via LAN (no routing loop)"
add_check maintable_default_wg0 "main table default route resolves via wg0"
add_check no_source_based_rule  "no source-based ip rule for 100.64.0.0/10 (known danger)"
add_check no_table201_leftover  "no leftover table-201 detour (2026-08-20, reverted 08-21)"
add_check dns_bypass_return     "Tailscale DNS RETURN-bypass rules present"
add_check dns_no_hairpin        "no DNAT/hairpin DNS rules (regressed once already)"
add_check dns_functional        "DNS actually resolves via server's Tailscale IP"
add_check ipv6_reject_forward   "IPv6 exit-node REJECT (FORWARD)"
add_check ipv6_reject_tsforward "IPv6 exit-node REJECT (inside ts-forward)"
add_check natpmp_outbound_block "Direct-WireGuard-outbound block (Android exit-node bug)"
add_check mss_clamp             "MSS clamping for tailscale0<->wg0"
add_check wg_switch_present     "wg-switch.sh present and executable"
add_check wg_profile_resolvable "wg0.conf's active profile identifiable (primary/failover)"
add_check watchdog_latch_fix    "wg-watchdog.sh: auto-failover latch-clear fix (2026-08-18) present"
add_check mainroute_in_postup   "wg0-up-extra.sh: main-table route restore (2026-07-02 fix) present"
add_check diskcheck_tmp_dedup   "vpn-diskcheck.sh: dedup flags in /tmp, not /run/user (2026-07-02/03 fix)"

# ── Individual checks ─────────────────────────────────────────────────────

check_exitnode_ks_forward() {
    iptables -C FORWARD -m mark --mark 0x200 ! -o wg0 -j DROP 2>/dev/null
}

check_exitnode_ks_tsforward() {
    iptables -C ts-forward -m mark --mark 0x200 ! -o wg0 -j DROP 2>/dev/null
}

check_qbt_ks_forward() {
    iptables -C FORWARD -s 172.27.0.0/24 ! -o wg0 -j DROP 2>/dev/null
}

check_ts_exit_mark_wired() {
    iptables -t mangle -C PREROUTING -i tailscale0 -j TS_EXIT_MARK 2>/dev/null
}

# Added 2026-08-31 (code review finding): check_ts_exit_mark_wired only
# proved the chain is reached, not that its own contents are still correct.
# Without these three RETURN lines, TS_EXIT_MARK would mark and force into
# table 200 (via wg0) EVERY packet arriving on tailscale0 -- including
# Tailscale mesh/peer traffic and the server's own replies, not just
# exit-node traffic -- breaking normal Tailscale connectivity while every
# other check here (fwmark_ip_rule, table200_default, etc.) still reports
# PASS, since the mark and the routing table both still exist and work.
check_ts_exit_mark_exempt() {
    iptables -t mangle -C TS_EXIT_MARK -d 100.64.0.0/10 -j RETURN 2>/dev/null && \
    iptables -t mangle -C TS_EXIT_MARK -d 192.168.50.0/24 -j RETURN 2>/dev/null && \
    iptables -t mangle -C TS_EXIT_MARK -d 10.0.0.0/24 -j RETURN 2>/dev/null
}

check_fwmark_ip_rule() {
    ip rule show | grep -q "fwmark 0x200 lookup 200"
}

check_table200_default() {
    ip route show table 200 2>/dev/null | grep -q "^default dev wg0"
}

check_table200_pihole() {
    ip route show table 200 2>/dev/null | grep -q "172\.25\.0\.0/24 dev br-pihole"
}

check_table200_endpoint_pin() {
    [[ -n "$PROTON_ENDPOINT" ]] && ip route show table 200 2>/dev/null | grep -q "^${PROTON_ENDPOINT} via ${LAN_GW}"
}

check_maintable_endpoint_pin() {
    [[ -n "$PROTON_ENDPOINT" ]] && ip route show table main 2>/dev/null | grep -q "^${PROTON_ENDPOINT} via"
}

check_maintable_default_wg0() {
    ip route get 1.1.1.1 2>/dev/null | head -1 | grep -q "dev wg0"
}

check_no_source_based_rule() {
    ! ip rule show | grep -q "from 100\.64\.0\.0/10"
}

check_no_table201_leftover() {
    ! ip rule show | grep -q "lookup 201" && [[ -z "$(ip route show table 201 2>/dev/null)" ]]
}

check_dns_bypass_return() {
    iptables -t nat -C PREROUTING -i tailscale0 -s 100.64.0.0/10 -p udp --dport 53 -j RETURN 2>/dev/null && \
    iptables -t nat -C PREROUTING -i tailscale0 -s 100.64.0.0/10 -p tcp --dport 53 -j RETURN 2>/dev/null
}

check_dns_no_hairpin() {
    ! iptables -t nat -C PREROUTING -i tailscale0 -s 100.64.0.0/10 -p udp --dport 53 -j DNAT --to-destination 172.25.0.2 2>/dev/null && \
    ! iptables -t nat -C PREROUTING -i tailscale0 -s 100.64.0.0/10 -p tcp --dport 53 -j DNAT --to-destination 172.25.0.2 2>/dev/null && \
    ! iptables -t nat -C PREROUTING -i tailscale0 -s 100.64.0.0/10 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1 2>/dev/null && \
    ! iptables -t nat -C PREROUTING -i tailscale0 -s 100.64.0.0/10 -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1 2>/dev/null && \
    ! iptables -t nat -C POSTROUTING -o br-pihole -d 172.25.0.2 -p udp --dport 53 -j MASQUERADE 2>/dev/null && \
    ! iptables -t nat -C POSTROUTING -o br-pihole -d 172.25.0.2 -p tcp --dport 53 -j MASQUERADE 2>/dev/null
}

check_dns_functional() {
    command -v dig >/dev/null 2>&1 || return 0   # dig missing: can't test, don't fail the whole suite over tooling
    dig +time=3 +tries=1 "@${TS_IP}" example.com +short 2>/dev/null | grep -qE '^[0-9]'
}

check_ipv6_reject_forward() {
    ip6tables -C FORWARD -i tailscale0 ! -o tailscale0 -j REJECT 2>/dev/null
}

check_ipv6_reject_tsforward() {
    ip6tables -C ts-forward -i tailscale0 ! -o tailscale0 -j REJECT 2>/dev/null
}

check_natpmp_outbound_block() {
    iptables -C OUTPUT -o enp1s0 -p udp --sport 41641 ! -d 192.168.50.0/24 -j DROP 2>/dev/null
}

check_mss_clamp() {
    iptables -t mangle -C FORWARD -i tailscale0 -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null && \
    iptables -t mangle -C FORWARD -i wg0 -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
}

check_wg_switch_present() {
    [[ -x /usr/local/bin/wg-switch.sh ]]
}

check_wg_profile_resolvable() {
    local live_pubkey
    live_pubkey=$(grep -m1 '^PublicKey' "$WG_CONF" 2>/dev/null)
    [[ -n "$live_pubkey" ]] || return 1
    if [[ -f "$PROFILES_DIR/wg0-primary.conf" ]] && grep -qF "$live_pubkey" "$PROFILES_DIR/wg0-primary.conf" 2>/dev/null; then
        return 0
    elif [[ -f "$PROFILES_DIR/wg0-failover.conf" ]] && grep -qF "$live_pubkey" "$PROFILES_DIR/wg0-failover.conf" 2>/dev/null; then
        return 0
    fi
    return 1
}

check_watchdog_latch_fix() {
    [[ -f "$WG_WATCHDOG_SRC" ]] && grep -q "auto-failover latch cleared" "$WG_WATCHDOG_SRC" 2>/dev/null
}

check_mainroute_in_postup() {
    [[ -f "$WG_UP_EXTRA" ]] && grep -q "ip route replace 0.0.0.0/0 dev wg0" "$WG_UP_EXTRA" 2>/dev/null
}

check_diskcheck_tmp_dedup() {
    [[ -f "$VPN_DISKCHECK_SRC" ]] && grep -q 'RUNTIME_DIR="/tmp"' "$VPN_DISKCHECK_SRC" 2>/dev/null && \
    ! grep -q 'RUNTIME_DIR="/run/user' "$VPN_DISKCHECK_SRC" 2>/dev/null
}

# ── Failure detail messages (only consulted when a check fails) ───────────

detail_for() {
    case "$1" in
        exitnode_ks_forward)   echo "Missing: iptables -I FORWARD 1 -m mark --mark 0x200 ! -o wg0 -j DROP -- exit-node traffic would leak out the real ISP interface if wg0 disappears." ;;
        exitnode_ks_tsforward) echo "Missing: iptables -I ts-forward 1 -m mark --mark 0x200 ! -o wg0 -j DROP -- ts-forward's own MARK/ACCEPT (0x40000) terminates traversal before the FORWARD-chain copy is ever reached, so THIS copy is the one that actually matters whenever a packet's input interface is tailscale0. A 'tailscale down; tailscale up' (wg-watchdog's coordination-restart path included) recreates ts-forward from scratch and wipes this; only a wg0-triggered PostUp (wg0-up-extra.sh) re-inserts it." ;;
        qbt_ks_forward)        echo "Missing: iptables -I FORWARD -s 172.27.0.0/24 ! -o wg0 -j DROP -- qBittorrent traffic could leak if wg0 is down." ;;
        ts_exit_mark_wired)    echo "mangle PREROUTING is not jumping tailscale0 traffic into TS_EXIT_MARK -- exit-node traffic won't get marked 0x200 at all, silently defeating the whole policy-routing setup." ;;
        ts_exit_mark_exempt)   echo "TS_EXIT_MARK is missing one or more of its RETURN exemptions (100.64.0.0/10, 192.168.50.0/24, 10.0.0.0/24). Without them, ALL tailscale0-origin traffic gets marked 0x200 and forced via wg0 -- not just exit-node traffic -- breaking Tailscale mesh/peer connectivity and the server's own replies to peers." ;;
        fwmark_ip_rule)        echo "ip rule 'fwmark 0x200 lookup 200' is missing -- marked packets fall through to the main table instead of being forced via wg0." ;;
        table200_default)      echo "table 200 has no 'default dev wg0' route -- exit-node traffic marked 0x200 has nowhere to go." ;;
        table200_pihole)       echo "table 200 has no route to 172.25.0.0/24 dev br-pihole -- DNS queries from Tailscale clients (marked 0x200 before the Pi-hole DNAT/RETURN rule sees them) would try to exit via wg0 instead of reaching Pi-hole." ;;
        table200_endpoint_pin) echo "table 200 has no LAN-gateway pin for the ProtonVPN endpoint (${PROTON_ENDPOINT:-<unresolved>}) -- risk of a routing loop for the tunnel's own packets." ;;
        maintable_endpoint_pin) echo "main table has no LAN-gateway pin for the ProtonVPN endpoint (${PROTON_ENDPOINT:-<unresolved>}) -- same routing-loop risk in the main table." ;;
        maintable_default_wg0) echo "Main-table default route does not resolve via wg0 (2026-07-02 incident: tunnel green, but host/bridge traffic silently egressing via the ISP with qBittorrent kill-switch-dead behind it). Fix: sudo ip route replace 0.0.0.0/0 dev wg0 metric 100" ;;
        no_source_based_rule)  echo "DANGER: a source-based ip rule for 100.64.0.0/10 exists. This breaks replies to every Tailscale peer, including the server's own IP (100.65.250.53) which is in that range. Never use source-based routing here -- see feedback_tailscale_routing memory. Remove it: ip rule del from 100.64.0.0/10 ..." ;;
        no_table201_leftover)  echo "The reverted 2026-08-20 ISP-direct detour (table 201) is back -- Pi-hole's own upstream DNS would bypass ProtonVPN again, contradicting Matt's 2026-08-21 explicit privacy-over-reliability call." ;;
        dns_bypass_return)     echo "The nat PREROUTING RETURN rules for Tailscale-client DNS (port 53 -> server's own Tailscale IP) are missing -- Tailscale clients' DNS queries won't reach Pi-hole via local delivery." ;;
        dns_no_hairpin)        echo "A DNAT-to-Pi-hole or hairpin-MASQUERADE DNS rule is present again. This exact approach was tried 2026-08-20, looked correct, and was found broken again 2026-08-21 (conntrack never correlated Pi-hole's reply back to the original connection, root cause never isolated). Do not re-add it -- bypass via RETURN, not DNAT+hairpin. See the History comment in wg0-up-extra.sh." ;;
        dns_functional)        echo "dig against the server's own Tailscale IP (${TS_IP}) got no answer within 3s -- the Tailscale-client DNS path is down end-to-end, regardless of what the iptables rules look like." ;;
        ipv6_reject_forward)   echo "Missing: ip6tables -I FORWARD 1 -i tailscale0 ! -o tailscale0 -j REJECT -- IPv6 exit-node forwarding isn't blocked (no IPv6 path through ProtonVPN wg0 exists, so this would misroute rather than cleanly reject)." ;;
        ipv6_reject_tsforward) echo "Missing: ip6tables -I ts-forward 1 -i tailscale0 ! -o tailscale0 -j REJECT -- same ts-forward-priority issue as the v4 exit-node kill switch above; a tailscale restart wipes this copy." ;;
        natpmp_outbound_block) echo "Missing: iptables -I OUTPUT -o enp1s0 -p udp --sport 41641 ! -d 192.168.50.0/24 -j DROP -- without this (and the paired router NAT-PMP/port-forward removal), the Android exit-node routing-loop bug can return: re-verify the Android Tailscale bug is actually fixed upstream before assuming this is safe to drop." ;;
        mss_clamp)             echo "TCPMSS clamping between tailscale0 and wg0 is missing -- expect large-packet drops on exit-node TCP connections (MTU 1280 vs 1420 mismatch)." ;;
        wg_switch_present)     echo "/usr/local/bin/wg-switch.sh is missing or not executable -- wg-watchdog's auto-failover silently no-ops (it only logs + alerts once, then gives up) whenever the primary endpoint goes down." ;;
        wg_profile_resolvable) echo "wg0.conf's live PublicKey matches neither wg0-primary.conf nor wg0-failover.conf -- auto-failover can't tell which profile is active and will refuse to switch (same as the 2026-08-13/18 latch incident's failure mode, different cause)." ;;
        watchdog_latch_fix)    echo "The 2026-08-18 fix (clearing FAILED_OVER_THIS_INCIDENT independent of TUNNEL_FAIL_TYPE once the new endpoint proves healthy) is no longer present in the deployed wg-watchdog.sh. Without it, auto-failover can silently latch disabled for days after its first use -- exactly what happened 2026-08-13 through 2026-08-18." ;;
        mainroute_in_postup)   echo "wg0-up-extra.sh no longer restores the main-table default route. If this logic moved back into wg0.service's ExecStart, a bare wg-quick bounce (wg-watchdog.sh) would silently drop it again -- the exact 2026-07-02 incident." ;;
        diskcheck_tmp_dedup)   echo "vpn-diskcheck.sh's dedup flags are no longer pinned to /tmp (or have regressed to /run/user/\$(id -u)), which systemd-logind tears down on SSH logout -- the 2026-07-02/03 incident that produced 11 duplicate 'VPN route missing' emails and contributed to a Migadu daily-cap hit." ;;
        *) echo "Check failed." ;;
    esac
}

# ── Run all checks ──────────────────────────────────────────────────────────

failed_ids=()
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'

(( REPORT )) && printf "${BOLD}=== VPN/DNS routing stack regression check -- $(date '+%Y-%m-%d %H:%M') ===${NC}\n\n"

for id in "${CHECKS[@]}"; do
    if "check_${id}"; then
        (( REPORT )) && printf "  ${GREEN}✓${NC} %s\n" "${LABEL[$id]}"
    else
        failed_ids+=("$id")
        DETAIL[$id]=$(detail_for "$id")
        if (( REPORT )); then
            printf "  ${RED}✗${NC} %s\n" "${LABEL[$id]}"
            printf "      %s\n" "${DETAIL[$id]}"
        fi
        logger -t "$LOG_TAG" "FAIL: ${LABEL[$id]} -- ${DETAIL[$id]}"
    fi
done

(( REPORT )) && { echo; if [[ ${#failed_ids[@]} -eq 0 ]]; then printf "${GREEN}All ${#CHECKS[@]} checks passed.${NC}\n"; else printf "${RED}${#failed_ids[@]}/${#CHECKS[@]} checks failed.${NC}\n"; fi; }

# ── Alerting (state-diffed, same dedup philosophy as wg-watchdog.sh /
#    docker-health-monitor.sh: alert on new failures immediately, repeat at
#    most hourly while still failing, alert once on recovery, never spam a
#    steady state either way) ────────────────────────────────────────────

# flock-guarded: a manual run (per this script's own header, expected after
# any config edit) can overlap the timer's own run. Without a lock, two
# concurrent read-modify-writes of FAILING_FILE/LAST_ALERT_FILE can clobber
# each other into a duplicate or missed alert. Non-blocking — if another
# instance holds the lock, this run skips its own alert-diffing silently
# (the checks above still ran and logged); the next timer tick reconciles
# whatever the true state is, same tolerance-for-a-skipped-beat philosophy
# as the dedup logic itself.
exec 200>"$LOCK_FILE"
if flock -n 200; then

mapfile -t prev_failing < <([[ -f "$FAILING_FILE" ]] && sort "$FAILING_FILE" || true)
mapfile -t cur_failing < <(printf '%s\n' "${failed_ids[@]:-}" | grep -v '^$' | sort)

new_failures=(); for id in "${cur_failing[@]:-}"; do [[ -z "$id" ]] && continue; printf '%s\n' "${prev_failing[@]:-}" | grep -qxF "$id" || new_failures+=("$id"); done
recovered=(); for id in "${prev_failing[@]:-}"; do [[ -z "$id" ]] && continue; printf '%s\n' "${cur_failing[@]:-}" | grep -qxF "$id" || recovered+=("$id"); done

if [[ ${#new_failures[@]} -gt 0 ]]; then
    body="New failure(s) in the VPN/DNS routing regression check on $(hostname) at $(date):${NL}${NL}"
    for id in "${cur_failing[@]}"; do
        body+="- ${LABEL[$id]}${NL}  ${DETAIL[$id]}${NL}${NL}"
    done
    /usr/local/bin/send-alert "[server] VPN/DNS regression check FAILED" "$body" high rotating_light
    date +%s > "$LAST_ALERT_FILE"
elif [[ ${#cur_failing[@]} -gt 0 ]]; then
    now=$(date +%s)
    last=$(cat "$LAST_ALERT_FILE" 2>/dev/null || echo 0)
    if (( now - last >= ALERT_REPEAT_SECS )); then
        body="Still failing (${#cur_failing[@]} check(s)) on $(hostname) at $(date):${NL}${NL}"
        for id in "${cur_failing[@]}"; do
            body+="- ${LABEL[$id]}${NL}"
        done
        /usr/local/bin/send-alert "[server] VPN/DNS regression check still failing" "$body" high rotating_light
        date +%s > "$LAST_ALERT_FILE"
    fi
fi

if [[ ${#recovered[@]} -gt 0 ]]; then
    body="Recovered on $(hostname) at $(date):${NL}${NL}"
    for id in "${recovered[@]}"; do
        body+="- ${LABEL[$id]}${NL}"
    done
    /usr/local/bin/send-alert "[server] VPN/DNS regression check recovered" "$body" default white_check_mark
fi

if [[ ${#cur_failing[@]} -eq 0 ]]; then
    rm -f "$FAILING_FILE" "$LAST_ALERT_FILE"
else
    printf '%s\n' "${cur_failing[@]}" > "$FAILING_FILE"
fi

fi   # flock
flock -u 200

[[ ${#failed_ids[@]} -eq 0 ]]
