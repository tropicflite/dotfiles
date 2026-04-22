#!/bin/bash

# Pi-hole routing through wg0
iptables -I FORWARD -i br-pihole -o wg0 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD -i wg0 -o br-pihole -j ACCEPT 2>/dev/null || true
iptables -t nat -I POSTROUTING 1 -s 172.20.0.0/24 -o wg0 -j MASQUERADE 2>/dev/null || true

# qBittorrent routing through wg0 only (kill switch)
iptables -I FORWARD -i br-qbittorrent -o wg0 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD -i wg0 -o br-qbittorrent -j ACCEPT 2>/dev/null || true
iptables -t nat -I POSTROUTING 1 -s 172.21.0.0/24 -o wg0 -j MASQUERADE 2>/dev/null || true
iptables -I FORWARD -i br-qbittorrent -o enp1s0 -j DROP 2>/dev/null || true
iptables -I FORWARD -i br-qbittorrent -o wlp2s0 -j DROP 2>/dev/null || true
