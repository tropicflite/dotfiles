#!/bin/bash
# Idempotent: delete any existing rules before inserting to prevent duplicates on wg0 restart
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
