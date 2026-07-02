#!/bin/bash
for i in $(seq 1 30); do
    tailscale ip 2>/dev/null | grep -q "^100\." && break || sleep 2
done
ip route show default | awk '/^default/ && /enp1s0/ {print $3; exit}' > /run/wg0-gateway
