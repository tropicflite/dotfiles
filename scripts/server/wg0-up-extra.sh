#!/bin/bash
# Idempotent: delete any existing rules before inserting to prevent duplicates on wg0 restart

# Policy routing: exit-node traffic (arriving on tailscale0, destined for internet)
# routes through ProtonVPN (wg0). Table = off in wg0.conf means wg-quick adds no routes.
#
# Custom chain TS_EXIT_MARK marks packets by incoming interface (tailscale0), with
# early RETURN for destinations that should NOT go through wg0:
#   - 100.64.0.0/10: Tailscale CGNAT (peer traffic + server's own Tailscale IP 100.65.250.53)
#   - 192.168.50.0/24, 10.0.0.0/24: server's advertised Tailscale subnets → stay on LAN
# Marked packets use table 200 (default via wg0). ProtonVPN endpoint pinned via LAN
# in table 200 to avoid routing loop.
#
# DO NOT use source-based ip rules (from 100.64/10) — the server's own Tailscale IP
# (100.65.250.53) is in that range; source routing breaks replies to all Tailscale peers.
PROTON_ENDPOINT="154.47.17.129"
LAN_GW="192.168.50.1"
iptables -t mangle -N TS_EXIT_MARK 2>/dev/null || true
iptables -t mangle -F TS_EXIT_MARK
iptables -t mangle -A TS_EXIT_MARK -d 100.64.0.0/10 -j RETURN
iptables -t mangle -A TS_EXIT_MARK -d 192.168.50.0/24 -j RETURN
iptables -t mangle -A TS_EXIT_MARK -d 10.0.0.0/24 -j RETURN
iptables -t mangle -A TS_EXIT_MARK -j MARK --set-mark 0x200
iptables -t mangle -D PREROUTING -i tailscale0 -j TS_EXIT_MARK 2>/dev/null || true
iptables -t mangle -I PREROUTING 1 -i tailscale0 -j TS_EXIT_MARK
ip rule del fwmark 0x200 lookup 200 2>/dev/null || true
ip route flush table 200 2>/dev/null || true
ip route add "${PROTON_ENDPOINT}/32" via "$LAN_GW" table 200
ip route add 0.0.0.0/0 dev wg0 table 200
# Pi-hole must be reachable in table 200: mangle PREROUTING (TS_EXIT_MARK) runs before
# nat PREROUTING (DNAT), so DNS queries to internet IPs get marked 0x200 before the DNAT
# redirect changes their destination to 172.25.0.2. Without this route, marked DNS
# packets follow the default (wg0) instead of reaching Pi-hole on br-pihole.
ip route add 172.25.0.0/24 dev br-pihole table 200
ip rule add fwmark 0x200 lookup 200 priority 100

iptables -D FORWARD -i br-pihole -o wg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i wg0 -o br-pihole -j ACCEPT 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 172.25.0.0/24 -o wg0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 172.21.0.0/24 -o wg0 -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i tailscale0 -o wg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i wg0 -o tailscale0 -j ACCEPT 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 100.64.0.0/10 -o wg0 -j MASQUERADE 2>/dev/null || true

iptables -I FORWARD -i br-pihole -o wg0 -j ACCEPT
iptables -I FORWARD -i wg0 -o br-pihole -j ACCEPT
iptables -t nat -I POSTROUTING 1 -s 172.25.0.0/24 -o wg0 -j MASQUERADE
# Exit node: forward Tailscale CGNAT traffic through ProtonVPN
iptables -I FORWARD -i tailscale0 -o wg0 -j ACCEPT
iptables -I FORWARD -i wg0 -o tailscale0 -j ACCEPT
iptables -t nat -I POSTROUTING 1 -s 100.64.0.0/10 -o wg0 -j MASQUERADE

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
# tailscale0 (MTU 1280) <-> wg0 (MTU 1420) path
iptables -t mangle -D FORWARD -i tailscale0 -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -D FORWARD -i wg0 -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -I FORWARD 1 -i tailscale0 -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -I FORWARD 2 -i wg0 -o tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# REJECT IPv6 exit node forwarding (no IPv6 path through ProtonVPN wg0).
# Must fire before tailscale's ts-forward chain ACCEPTs the traffic.
# Added to BOTH FORWARD (position 1) and inside ts-forward (position 1): tailscale up
# re-inserts ts-forward at FORWARD pos 1 pushing our rule to pos 2, but the
# ts-forward insertion survives that race.
ip6tables -D FORWARD -i tailscale0 ! -o tailscale0 -j REJECT 2>/dev/null || true
ip6tables -I FORWARD 1 -i tailscale0 ! -o tailscale0 -j REJECT
ip6tables -D ts-forward -i tailscale0 ! -o tailscale0 -j REJECT 2>/dev/null || true
ip6tables -I ts-forward 1 -i tailscale0 ! -o tailscale0 -j REJECT
