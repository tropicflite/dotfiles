#!/bin/bash
iptables -I FORWARD -i br-pihole -o wg0 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD -i wg0 -o br-pihole -j ACCEPT 2>/dev/null || true
iptables -t nat -I POSTROUTING 1 -s 172.20.0.0/24 -o wg0 -j MASQUERADE 2>/dev/null || true
