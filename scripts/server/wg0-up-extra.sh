#!/bin/bash
# Idempotent: delete any existing rules before inserting to prevent duplicates on wg0 restart

# Policy routing: exit-node traffic (arriving on tailscale0, destined for internet)
# routes DIRECT via the ISP (enp1s0), bypassing ProtonVPN. Table = off in wg0.conf
# means wg-quick adds no routes.
#
# Changed 2026-08-20: ProtonVPN was found flapping between full speed and near-zero
# throughput second-to-second on BOTH the primary and failover endpoints, confirmed
# via repeated back-to-back curl tests through wg0 (not an MTU or endpoint issue —
# see session notes). Direct-via-ISP tested rock solid (178Mbps, sub-second) at the
# same time. Matt chose to bypass the VPN for exit-node (phone browsing) traffic
# specifically, in exchange for losing VPN protection/anonymization on that traffic.
# qBittorrent's own hard kill switch (still pinned to wg0 further below) is untouched
# by this — torrent traffic still requires the VPN, only exit-node browsing doesn't.
#
# Custom chain TS_EXIT_MARK marks packets by incoming interface (tailscale0), with
# early RETURN for destinations that should NOT go through the exit-node path:
#   - 100.64.0.0/10: Tailscale CGNAT (peer traffic + server's own Tailscale IP 100.65.250.53)
#   - 192.168.50.0/24, 10.0.0.0/24: server's advertised Tailscale subnets → stay on LAN
# Marked packets use table 200 (default via enp1s0/LAN gateway).
#
# DO NOT use source-based ip rules (from 100.64/10) — the server's own Tailscale IP
# (100.65.250.53) is in that range; source routing breaks replies to all Tailscale peers.
#
# PROTON_ENDPOINT is still read for the main-table routes below (qBittorrent/host
# traffic still goes via ProtonVPN) — wg-switch.sh can swap wg0.conf to a different
# ProtonVPN server/endpoint entirely, and a hardcoded value here was the exact
# foot-gun that broke routing during the 2026-07-05 manual server swap.
PROTON_ENDPOINT=$(grep -m1 '^Endpoint' /etc/wireguard/wg0.conf | sed -E 's/^Endpoint\s*=\s*([^:]+):.*/\1/')
LAN_GW="192.168.50.1"

# Main-table routes — moved here from wg0.service ExecStart (2026-07-02) so that
# EVERY wg-quick up path restores them: boot, systemctl, and wg-watchdog's bare
# wg-quick bounce. Before this, a watchdog bounce rebuilt iptables + table 200
# (this script, via PostUp) but silently dropped the main-table default route:
# tunnel up and green on every check, while host + docker-bridge traffic egressed
# via the ISP and qBittorrent sat dead behind its own kill switch.
# Endpoint pin must exist before the default flips to wg0, or the tunnel's own
# packets try to route through the tunnel. Gateway: prestart's snapshot if
# present (boot path), else derived live (watchdog path — prestart doesn't run).
GW=$(cat /run/wg0-gateway 2>/dev/null)
[ -z "$GW" ] && GW=$(ip route show default | awk '/^default/ && /enp1s0/ {print $3; exit}')
[ -z "$GW" ] && GW="$LAN_GW"
ip route replace "${PROTON_ENDPOINT}/32" via "$GW"
ip route replace 0.0.0.0/0 dev wg0 metric 100

iptables -t mangle -N TS_EXIT_MARK 2>/dev/null || true
iptables -t mangle -F TS_EXIT_MARK
iptables -t mangle -A TS_EXIT_MARK -d 100.64.0.0/10 -j RETURN
iptables -t mangle -A TS_EXIT_MARK -d 192.168.50.0/24 -j RETURN
iptables -t mangle -A TS_EXIT_MARK -d 10.0.0.0/24 -j RETURN
iptables -t mangle -A TS_EXIT_MARK -j MARK --set-mark 0x200
# Save mark 0x200 onto the connection (ctmark), restricted to that single bit
# so it can't clobber ts-forward's own 0x40000/0xff0000 mark. Lets the kill
# switch below flush stale connections by mark on the next wg0 up.
iptables -t mangle -A TS_EXIT_MARK -j CONNMARK --save-mark --nfmask 0x200 --ctmask 0x200
iptables -t mangle -D PREROUTING -i tailscale0 -j TS_EXIT_MARK 2>/dev/null || true
iptables -t mangle -I PREROUTING 1 -i tailscale0 -j TS_EXIT_MARK
ip rule del fwmark 0x200 lookup 200 2>/dev/null || true
ip route flush table 200 2>/dev/null || true
ip route add default via "$LAN_GW" dev enp1s0 table 200
# Pi-hole must be reachable in table 200: mangle PREROUTING (TS_EXIT_MARK) runs before
# nat PREROUTING (DNAT), so DNS queries to internet IPs get marked 0x200 before the DNAT
# redirect changes their destination to 172.25.0.2. Without this route, marked DNS
# packets follow the default (now enp1s0) instead of reaching Pi-hole on br-pihole.
ip route add 172.25.0.0/24 dev br-pihole table 200
ip rule add fwmark 0x200 lookup 200 priority 100

iptables -D FORWARD -i br-pihole -o wg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i wg0 -o br-pihole -j ACCEPT 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 172.25.0.0/24 -o wg0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 172.21.0.0/24 -o wg0 -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i tailscale0 -o enp1s0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i enp1s0 -o tailscale0 -j ACCEPT 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 100.64.0.0/10 -o wg0 -j MASQUERADE 2>/dev/null || true

iptables -I FORWARD -i br-pihole -o wg0 -j ACCEPT
iptables -I FORWARD -i wg0 -o br-pihole -j ACCEPT
iptables -t nat -I POSTROUTING 1 -s 172.25.0.0/24 -o wg0 -j MASQUERADE
# Exit node: forward Tailscale CGNAT traffic direct via the ISP (see 2026-08-20
# note above). ts-postrouting already MASQUERADEs all tailscale0-origin forwarded
# traffic generically (mark 0x40000/0xff0000, interface-agnostic), so no separate
# MASQUERADE rule is needed here for the enp1s0 path.
iptables -I FORWARD -i tailscale0 -o enp1s0 -j ACCEPT
iptables -I FORWARD -i enp1s0 -o tailscale0 -j ACCEPT

# Exit-node hard kill switch: packets marked 0x200 (tailscale0-origin traffic
# from TS_EXIT_MARK above) may only leave via enp1s0 (see 2026-08-20 note above —
# this used to pin to wg0/ProtonVPN, now pins to the direct ISP path instead).
# Without this, if enp1s0's route in table 200 were ever wrong/missing, the
# "fwmark 0x200 lookup 200" ip rule would fail to resolve and the kernel would
# fall through to the main table's default (dev wg0) — silently routing
# exit-node traffic back through the VPN instead of failing closed the way this
# rule intends. ts-forward's own ACCEPT (mark 0x40000/0xff0000) and
# ts-postrouting's MASQUERADE don't check which interface the packet left
# on — so without this rule, exit-node traffic wouldn't black-hole, it would
# silently go out whatever interface table 200 (or its main-table fallback)
# resolved to. Must sit ahead of the jump to ts-forward, or ts-forward's
# blanket ACCEPT wins the race and this rule is never reached — but
# `tailscale up` re-inserts ts-forward at FORWARD position 1 itself (same race
# documented on the ip6tables REJECT rule below), which would push a
# FORWARD-table-only copy behind it. Belt and suspenders like that rule: one
# copy in FORWARD (covers the common case, also runs ahead of
# DOCKER-USER/DOCKER-FORWARD), one copy inside ts-forward itself ahead of
# its own MARK/ACCEPT (survives tailscaled reasserting position 1). Neither
# copy is removed in wg0-down-extra.sh — same fail-closed philosophy as the
# qBittorrent switch below. The matching tailscaled.service ExecStartPost
# override (dotfiles: scripts/server/tailscaled-override.conf) must be kept
# in sync with whichever interface this points at — it re-applies the same
# rule on tailscaled-only restarts, which don't trigger this script.
iptables -D FORWARD -m mark --mark 0x200 ! -o enp1s0 -j DROP 2>/dev/null || true
iptables -I FORWARD 1 -m mark --mark 0x200 ! -o enp1s0 -j DROP
iptables -D ts-forward -m mark --mark 0x200 ! -o enp1s0 -j DROP 2>/dev/null || true
iptables -I ts-forward 1 -m mark --mark 0x200 ! -o enp1s0 -j DROP

# Flush any conntrack entries still carrying the 0x200 connmark from before
# this run (e.g. a connection that started leaking out enp1s0 during the gap
# before this script re-ran). The DROP above already blocks such packets on
# their very next FORWARD pass — conntrack ESTABLISHED state doesn't skip
# per-packet routing/filtering — but this clears stale state so nothing
# lingers half-NATed against the wrong interface.
conntrack -D -m 0x200 2>/dev/null || true

# qBittorrent hard kill switch: packets from the qbittorrent bridge (172.27.0.0/24)
# may only leave via wg0. If wg0 is down the kernel drops them immediately, closing
# the 5-minute gap in the vpn-diskcheck.sh software kill switch.
iptables -D FORWARD -s 172.27.0.0/24 ! -o wg0 -j DROP 2>/dev/null || true
iptables -I FORWARD -s 172.27.0.0/24 ! -o wg0 -j DROP

# qBittorrent NAT-PMP inbound port forward (added 2026-07-05): ProtonVPN's NAT-PMP
# gateway (10.2.0.1) forwards a dynamically-assigned public port to whatever fixed
# "private port" qbt-natpmp-renew.sh requests (always 6881, matching qBittorrent's
# listen_port) — so traffic always arrives on wg0 at 6881 regardless of the current
# public port. Only qBittorrent's announce_port (told to trackers) needs to track
# the changing public port; this forwarding rule itself is static and never needs
# to be rebuilt on renewal. qBittorrent's container has no published host port, so
# it's reached here directly by its container IP on the qbittorrent bridge.
iptables -t nat -D PREROUTING -i wg0 -p tcp --dport 6881 -j DNAT --to-destination 172.27.0.2:6881 2>/dev/null || true
iptables -t nat -D PREROUTING -i wg0 -p udp --dport 6881 -j DNAT --to-destination 172.27.0.2:6881 2>/dev/null || true
iptables -t nat -I PREROUTING 1 -i wg0 -p tcp --dport 6881 -j DNAT --to-destination 172.27.0.2:6881
iptables -t nat -I PREROUTING 1 -i wg0 -p udp --dport 6881 -j DNAT --to-destination 172.27.0.2:6881
iptables -D FORWARD -i wg0 -o br-qbittorrent -d 172.27.0.2 -p tcp --dport 6881 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i wg0 -o br-qbittorrent -d 172.27.0.2 -p udp --dport 6881 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD -i wg0 -o br-qbittorrent -d 172.27.0.2 -p tcp --dport 6881 -j ACCEPT
iptables -I FORWARD -i wg0 -o br-qbittorrent -d 172.27.0.2 -p udp --dport 6881 -j ACCEPT

# Fix UDP GRO forwarding for Tailscale exit node performance
ethtool -K enp1s0 rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || true

# Redirect DNS from Tailscale clients to Pi-hole: carrier DNS (e.g. Telus 75.156.200.x)
# only responds to queries from their own subscriber IPs, not from ProtonVPN's IP.
# Pi-hole (172.25.0.2) uses Quad9 upstream and routes out through wg0, solving that.
# This also gives all Tailscale clients ad-blocking via Pi-hole.
iptables -t nat -D PREROUTING -i tailscale0 -s 100.64.0.0/10 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1 2>/dev/null || true
iptables -t nat -D PREROUTING -i tailscale0 -s 100.64.0.0/10 -p tcp --dport 53 -j DNAT --to-destination 1.1.1.1 2>/dev/null || true
iptables -t nat -D PREROUTING -i tailscale0 -s 100.64.0.0/10 -p udp --dport 53 -j DNAT --to-destination 172.25.0.2 2>/dev/null || true
iptables -t nat -D PREROUTING -i tailscale0 -s 100.64.0.0/10 -p tcp --dport 53 -j DNAT --to-destination 172.25.0.2 2>/dev/null || true
iptables -t nat -I PREROUTING 1 -i tailscale0 -s 100.64.0.0/10 -p udp --dport 53 -j DNAT --to-destination 172.25.0.2
iptables -t nat -I PREROUTING 2 -i tailscale0 -s 100.64.0.0/10 -p tcp --dport 53 -j DNAT --to-destination 172.25.0.2

# MSS clamping for exit node TCP: prevents large packet drops through the
# tailscale0 (MTU 1280) <-> enp1s0 (MTU 1500) path (was <-> wg0 MTU 1420 before
# the 2026-08-20 ISP-bypass change above; kept for whichever interface is
# currently in the exit-node path).
iptables -t mangle -D FORWARD -i tailscale0 -o enp1s0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -D FORWARD -i enp1s0 -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -I FORWARD 1 -i tailscale0 -o enp1s0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -I FORWARD 2 -i enp1s0 -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# REJECT IPv6 exit node forwarding (no IPv6 path through ProtonVPN wg0).
# Must fire before tailscale's ts-forward chain ACCEPTs the traffic.
# Added to BOTH FORWARD (position 1) and inside ts-forward (position 1): tailscale up
# re-inserts ts-forward at FORWARD pos 1 pushing our rule to pos 2, but the
# ts-forward insertion survives that race.
ip6tables -D FORWARD -i tailscale0 ! -o tailscale0 -j REJECT 2>/dev/null || true
ip6tables -I FORWARD 1 -i tailscale0 ! -o tailscale0 -j REJECT
ip6tables -D ts-forward -i tailscale0 ! -o tailscale0 -j REJECT 2>/dev/null || true
ip6tables -I ts-forward 1 -i tailscale0 ! -o tailscale0 -j REJECT

# INTENTIONAL: block server from initiating direct WireGuard to external peers.
#
# Android Tailscale bug: when the phone uses this server as an exit node over a
# direct WireGuard connection, it fails to add a bypass route for the server's
# direct endpoint (99.241.47.35) outside the exit-node tunnel. All traffic —
# including the WireGuard keepalives themselves — gets routed through the exit-node
# tunnel, creating a routing loop that kills the phone's internet.
#
# The fix has two parts (both required):
#   1. Router: NAT-PMP disabled + static port forward for 41641 removed — phone
#      cannot initiate direct connections inbound to the server.
#   2. This rule: server cannot hole-punch a direct path outbound to the phone,
#      which would otherwise re-establish direct even without a port forward.
#
# LAN peers (mini, laptop, desktop) are unaffected — they reach the server via
# its LAN IP (192.168.50.34) directly, not through enp1s0 NAT. DERP relay uses
# TCP, not UDP 41641. Do NOT remove this rule or restore the router port forward
# without first verifying the Android bug is fixed in the installed Tailscale version.
iptables -D OUTPUT -o enp1s0 -p udp --sport 41641 ! -d 192.168.50.0/24 -j DROP 2>/dev/null || true
iptables -I OUTPUT -o enp1s0 -p udp --sport 41641 ! -d 192.168.50.0/24 -j DROP
