#!/bin/bash
# tailscale-ready.service Requires=tailscaled.service, and ntfy-compose/radicale-compose
# both Requires=tailscale-ready.service — deliberately, so a real `stop` of tailscaled
# propagates and takes them down too (see docker/CLAUDE.md, 2026-07-01 incident). But a
# transient tailscaled *restart* (crash-loop during network instability) can also cause
# tailscale-ready's start job to fail with a one-off "dependency" result, which strands
# it (and ntfy/radicale behind it) in `failed` with nothing to retry — nothing brings
# them back once tailscaled stabilizes. This runs on a timer to catch and clear exactly
# that stranded case, without touching the intentional Requires= chain.
# Install: sudo cp ~/dotfiles/scripts/server/tailscale-ready-selfheal.sh /usr/local/bin/tailscale-ready-selfheal.sh && sudo chmod +x /usr/local/bin/tailscale-ready-selfheal.sh

set -euo pipefail

UNITS=(tailscale-ready.service ntfy-compose.service radicale-compose.service)
STRANDED=()

for unit in "${UNITS[@]}"; do
    if systemctl is-failed --quiet "$unit"; then
        STRANDED+=("$unit")
    fi
done

[ "${#STRANDED[@]}" -eq 0 ] && exit 0

# Still genuinely down (no Tailscale IP yet), not stranded — leave it for the next tick.
tailscale ip -4 >/dev/null 2>&1 || exit 0

for unit in "${UNITS[@]}"; do
    systemctl is-failed --quiet "$unit" && systemctl reset-failed "$unit"
done
systemctl start tailscale-ready.service
systemctl start ntfy-compose.service radicale-compose.service

BODY="Self-healed on $(hostname) at $(date): ${STRANDED[*]} were stranded in 'failed' by a transient tailscaled restart. Tailscale has an IP again, so they were reset and restarted."
printf "Subject: [server] Self-healed stranded services\nTo: nichols_matt@pm.me\nFrom: nichols_matt@pm.me\n\n%s\n" "$BODY" | \
    NTFY_PRIORITY=default NTFY_TAGS=recycle NTFY_BODY="$BODY" /usr/local/bin/send-mail
