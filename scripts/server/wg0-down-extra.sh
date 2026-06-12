#!/bin/bash
iptables -D FORWARD -i br-pihole -o wg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i wg0 -o br-pihole -j ACCEPT 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 172.25.0.0/24 -o wg0 -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i tailscale0 -o wg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i wg0 -o tailscale0 -j ACCEPT 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 100.64.0.0/10 -o wg0 -j MASQUERADE 2>/dev/null || true
