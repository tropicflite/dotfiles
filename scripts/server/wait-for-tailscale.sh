#!/bin/sh
# tailscaled.service is Type=notify and reports ready as soon as the daemon
# starts, but the actual `tailscale up` call (and the IP it assigns to
# tailscale0) happens later in an ExecStartPost. Compose units that bind to
# the Tailscale IP need to wait for that IP to actually exist, not just for
# tailscaled.service to be active.
# Install: sudo cp ~/dotfiles/scripts/server/wait-for-tailscale.sh /usr/local/bin/wait-for-tailscale.sh && sudo chmod +x /usr/local/bin/wait-for-tailscale.sh

for i in $(seq 1 60); do
    if tailscale ip -4 >/dev/null 2>&1; then
        exit 0
    fi
    sleep 1
done

echo "Timed out waiting for tailscale0 to get an IP" >&2
exit 1
