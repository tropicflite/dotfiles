#!/bin/bash
# laptop-online-watch.sh — one-shot cron watcher: waits for laptop to come
# back reachable over Tailscale, captures its wifi-watchdog syslog (the
# self-heal watchdog installed 2026-07-11, see dotfiles memory), alerts once
# with a quick WRONG_KEY verdict, then removes itself from the crontab.
#
# Built 2026-08-01 to diagnose the outage that started ~08:43 that day —
# laptop had a brief 4-min reconnect at 10:27-10:31 then dropped again,
# which doesn't fit the usual sub-30-min self-healing blip pattern seen
# 07-25 through 07-29. Reading the watchdog's own syslog tag on laptop is
# the only way to tell WRONG_KEY (needs physical presence, see
# project_laptop_wifi_flake_20260701) from the watchdog's own escalation
# ladder still grinding.
#
# NOTE: server had never SSH'd to laptop before this script (no prior
# known_hosts entry) — TOFU-accepted via the fixed host+IP pairing already in
# ~/.ssh/config. Confirmed working 2026-08-01: key auth succeeded, and
# passwordless sudo on laptop works over that same non-interactive session
# (needed because /var/log/syslog there is root:adm 0640, not
# world-readable — the capture below must use sudo or it silently returns
# nothing).
#
# Self-disabling: after a successful capture it strips its own line from
# the crontab, so it only ever fires once per install. Re-add the crontab
# line (server-configs/crontab) to arm it again for a future outage.

LOCK="/var/tmp/laptop-online-watch.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0

DONE_MARKER="/var/tmp/laptop-online-watch.done"
[ -f "$DONE_MARKER" ] && exit 0

SSH_OPTS=(-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

ssh "${SSH_OPTS[@]}" laptop true 2>/dev/null || exit 0

CAPTURE_DIR="/home/matt/laptop-diagnostics"
mkdir -p "$CAPTURE_DIR"
OUT="$CAPTURE_DIR/wifi-watchdog-$(date +%Y%m%d-%H%M%S).log"

ssh "${SSH_OPTS[@]}" laptop \
    "sudo grep -a wifi-watchdog /var/log/syslog /var/log/syslog.1 2>/dev/null" > "$OUT" 2>/dev/null

if [ ! -s "$OUT" ]; then
    # laptop's /var/log/syslog is root:adm 0640 — unprivileged grep silently
    # returns nothing there. If this happens even with sudo in the command
    # above, sudo itself is the thing to check (passwordless sudo confirmed
    # working 2026-08-01, but don't assume it stays that way).
    VERDICT="Capture came back empty — check sudo/syslog permissions on laptop before trusting this as a real 'no WRONG_KEY' result."
elif grep -q "WRONG_KEY" "$OUT" 2>/dev/null; then
    VERDICT="WRONG_KEY PSK rejection found in the log — matches the known needs-physical-presence failure mode, watchdog cannot self-heal this."
else
    VERDICT="No WRONG_KEY in the watchdog log — likely just the escalation ladder (soft reconnect / radio bounce / NM restart) grinding through a real association drop. See the capture for detail."
fi

/home/matt/bin/send-alert "Laptop back online — wifi-watchdog log captured" \
    "$VERDICT Saved to $OUT." default information_source

touch "$DONE_MARKER"
crontab -l | grep -v "laptop-online-watch.sh" | crontab -
