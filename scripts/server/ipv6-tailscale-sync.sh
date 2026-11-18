#!/bin/bash
# ipv6-tailscale-sync.sh — give the server a global IPv6 address that ONLY
# tailscaled's own traffic can use (added 2026-11-18).
#
# Why: with IPv6 on both ends, Tailscale builds a direct path to the phone on
# Telus cellular instead of relaying via DERP. Measured 2026-11-18 on 5G with
# the exit node on: direct-over-v6 33 Mbps (= raw cellular 33-35) vs DERP
# 16 Mbps. IPv4 can't go direct: Telus CGNAT + router port forward/NAT-PMP
# deliberately removed (see the Android exit-node bug block in
# wg0-up-extra.sh). The Android routing-loop bug did NOT reproduce over the
# direct v6 path (Pixel 10 Pro Fold, server tailscale 1.104.7).
#
# Design — fail-closed, no VPN leak:
#   * The router (RT-AX86U Pro, Merlin) gets a /64 via Rogers DHCPv6-PD but
#     sends NO router adverts on the LAN (nvram ipv6_radvd=0, dhcp6s=0), so no
#     other LAN device gets IPv6. The server takes <prefix>::34 statically,
#     read from the router's nvram over SSH; this timer re-syncs if Rogers
#     ever changes the prefix.
#   * NO IPv6 default route in the main table. The only v6 default lives in
#     table 202, reachable only via ip -6 rules 102/103 for fwmark 0x80000
#     (tailscaled's SO_MARK) — mirrors the IPv4 Tailscale bypass in
#     wg0-up-extra.sh. Every other process gets ENETUNREACH on v6 and falls
#     back to IPv4 (i.e. through wg0/ProtonVPN) immediately.
#   * ip6tables V6TS-OUT / V6TS-IN on enp1s0 as defence in depth: egress only
#     for marked traffic + ICMPv6/link-local; ingress only established,
#     ICMPv6, link-local sources, and UDP 41641 (tailscaled).
#   * accept_ra on enp1s0 must stay 0 (a stray RA would plant a main-table
#     default route = leak). vpn-dns-regression-check.sh asserts all of this.
#
# Idempotent; run as root by ipv6-tailscale-sync.timer (boot + every 5 min).
# Router unreachable -> leave current state alone. Router IPv6 disabled or no
# prefix -> remove the address/route (firewall always stays).
#
# Deploy: symlinked to /usr/local/bin/ipv6-tailscale-sync.sh (dotfiles.map).

set -uo pipefail

IF=enp1s0
HOST_ID=34          # mirrors the IPv4 192.168.50.34
TABLE=202
MARK=0x80000/0xff0000
TS_PORT=41641
TAG=ipv6-tailscale-sync

# Under systemd stdout already lands in the journal; only add logger for manual runs.
log() { echo "$*"; [[ -n "${INVOCATION_ID:-}" ]] || logger -t "$TAG" -- "$*"; }

[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"

# ── 1. Firewall first (always, even with no address) ──────────────────────
ensure_chain() {   # $1=chain, rest: rules as single strings
    local chain=$1; shift
    ip6tables -N "$chain" 2>/dev/null || true
    local want have
    want=$(printf '%s\n' "$@")
    have=$(ip6tables -S "$chain" | sed -n "s/^-A $chain //p")
    if [[ "$want" != "$have" ]]; then
        ip6tables -F "$chain"
        local r; for r in "$@"; do eval "ip6tables -A $chain $r"; done
        log "rebuilt ip6tables chain $chain"
    fi
}
# Rule strings written exactly as `ip6tables -S` prints them, so the
# want/have comparison is stable.
ensure_chain V6TS-OUT \
    "-m mark --mark $MARK -j ACCEPT" \
    "-p ipv6-icmp -j ACCEPT" \
    "-d fe80::/10 -j ACCEPT" \
    "-d ff00::/8 -j ACCEPT" \
    "-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" \
    "-j REJECT --reject-with icmp6-adm-prohibited"
ensure_chain V6TS-IN \
    "-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" \
    "-p ipv6-icmp -j ACCEPT" \
    "-s fe80::/10 -j ACCEPT" \
    "-p udp -m udp --dport $TS_PORT -j ACCEPT" \
    "-j DROP"
ip6tables -C OUTPUT -o "$IF" -j V6TS-OUT 2>/dev/null || { ip6tables -I OUTPUT 1 -o "$IF" -j V6TS-OUT; log "hooked V6TS-OUT"; }
ip6tables -C INPUT  -i "$IF" -j V6TS-IN  2>/dev/null || { ip6tables -I INPUT 1 -i "$IF" -j V6TS-IN;  log "hooked V6TS-IN"; }

# Never learn routes from RAs (would put a default in main = leak).
sysctl -qw "net.ipv6.conf.$IF.accept_ra=0" "net.ipv6.conf.$IF.autoconf=0"

# ── 2. Ask the router for the current delegated prefix ─────────────────────
if ! info=$(runuser -u matt -- ssh -o BatchMode=yes -o ConnectTimeout=5 router \
        'nvram get ipv6_service; nvram get ipv6_prefix; nvram get ipv6_prefix_length; nvram get ipv6_rtr_addr' 2>/dev/null); then
    echo "router unreachable; leaving IPv6 state unchanged"
    exit 0
fi
{ read -r svc; read -r prefix; read -r plen; read -r gw; } <<<"$info"

remove_v6() {
    ip -6 rule del priority 103 2>/dev/null
    ip -6 rule del priority 102 2>/dev/null
    ip -6 route flush table "$TABLE" 2>/dev/null
    local a; for a in $(ip -6 -o addr show dev "$IF" scope global | awk '{print $4}'); do
        ip -6 addr del "$a" dev "$IF" && log "removed $a ($1)"
    done
}

if [[ "$svc" != "dhcp6" || -z "$prefix" || -z "$gw" ]]; then
    remove_v6 "router IPv6 off/no prefix: svc=$svc prefix=$prefix"
    exit 0
fi
if [[ "$plen" != "64" || "$prefix" != *:: ]]; then
    log "unexpected prefix $prefix/$plen -- not configuring (expected a /64 ending in ::)"
    exit 0
fi

addr="${prefix}${HOST_ID}"

# ── 3. Address (drop any stale global from an old prefix) ──────────────────
for a in $(ip -6 -o addr show dev "$IF" scope global | awk '{print $4}'); do
    [[ "$a" == "$addr/64" ]] || { ip -6 addr del "$a" dev "$IF"; log "removed stale $a"; }
done
if ! ip -6 -o addr show dev "$IF" | grep -q " $addr/64 "; then
    ip -6 addr add "$addr/64" dev "$IF" && log "added $addr/64 on $IF"
fi

# ── 4. Routing: v6 default only for tailscaled-marked traffic ─────────────
cur=$(ip -6 route show table "$TABLE" default 2>/dev/null)
if [[ "$cur" != "default via $gw dev $IF "* ]]; then
    ip -6 route replace default via "$gw" dev "$IF" table "$TABLE" && log "table $TABLE v6 default via $gw"
fi
rules=$(ip -6 rule show)
grep -q "^102:.*fwmark $MARK lookup main suppress_prefixlength 0" <<<"$rules" || \
    { ip -6 rule add priority 102 fwmark "$MARK" lookup main suppress_prefixlength 0; log "added v6 rule 102"; }
grep -q "^103:.*fwmark $MARK lookup $TABLE" <<<"$rules" || \
    { ip -6 rule add priority 103 fwmark "$MARK" lookup "$TABLE"; log "added v6 rule 103"; }

# Belt and braces: a main-table v6 default must never exist.
if ip -6 route show default | grep -q .; then
    ip -6 route show default | while read -r r; do ip -6 route del $r; done
    log "deleted unexpected main-table IPv6 default route"
fi
exit 0
