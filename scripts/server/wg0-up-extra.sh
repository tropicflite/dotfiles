#!/bin/bash
# Idempotent: delete any existing rules before inserting to prevent duplicates on wg0 restart
iptables -D FORWARD -i br-pihole -o wg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i wg0 -o br-pihole -j ACCEPT 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 172.25.0.0/24 -o wg0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -s 172.21.0.0/24 -o wg0 -j MASQUERADE 2>/dev/null || true

iptables -I FORWARD -i br-pihole -o wg0 -j ACCEPT
iptables -I FORWARD -i wg0 -o br-pihole -j ACCEPT
iptables -t nat -I POSTROUTING 1 -s 172.25.0.0/24 -o wg0 -j MASQUERADE
