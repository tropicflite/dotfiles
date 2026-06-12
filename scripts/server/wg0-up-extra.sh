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

# REJECT IPv6 exit node forwarding (no IPv6 path through ProtonVPN wg0)
# Gives phone immediate ICMP6 unreachable so apps fall back to IPv4 fast
ip6tables -D FORWARD -i tailscale0 ! -o tailscale0 -j REJECT 2>/dev/null || true
ip6tables -I FORWARD 1 -i tailscale0 ! -o tailscale0 -j REJECT
