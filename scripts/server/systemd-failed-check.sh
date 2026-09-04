#!/bin/bash
# Alert promptly when any systemd unit is in a failed state.
#
# health-monitor.sh already checks `systemctl --failed`, but only as part of
# its once-a-day 2am digest -- a unit that fails right after that run can sit
# failed for up to ~24h with zero alert. That gap let homepage-compose.service
# and tsdproxy-compose.service (both hit a transient containerd EOF racing a
# docker engine restart, 2026-09-04 06:54, and had no restart policy at the
# time) stay down for ~7h, taking out the dashboard and every tsdproxy-fronted
# Tailscale hostname, until Matt happened to ask about it. This check exists
# to close that window; health-monitor.sh's daily check is left in place as
# a harmless backstop.
#
# Same state-diffed alerting philosophy as wg-watchdog.sh / docker-health-
# monitor.sh / vpn-dns-regression-check.sh: alert on a new failure
# immediately, repeat at most hourly while still failing, alert once on
# recovery, never spam a steady state either way.
#
# Deploy: symlinked to /usr/local/bin/systemd-failed-check.sh (dotfiles.map).
# Runs via systemd-failed-check.timer every 5 min, as matt (systemctl --failed
# needs no privilege). Doesn't need root, unlike vpn-dns-regression-check.sh
# (which reads iptables state).

set -uo pipefail

STATE_DIR="/var/tmp/systemd-failed-check"
FAILING_FILE="$STATE_DIR/failing_units"
LAST_ALERT_FILE="$STATE_DIR/last_alert_time"
LOCK_FILE="$STATE_DIR/lock"
ALERT_REPEAT_SECS=3600   # re-alert on an unresolved failure at most hourly
NL=$'\n'                 # see vpn-dns-regression-check.sh 2026-08-31 note:
                          # "\n" in a double-quoted bash string never expands

mkdir -p "$STATE_DIR"

mapfile -t cur_failing < <(systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{print $2}' | sort)

if [[ -t 1 ]]; then
    if [[ ${#cur_failing[@]} -eq 0 ]]; then
        echo "No failed units."
    else
        printf 'Failed units:\n'
        printf '  %s\n' "${cur_failing[@]}"
    fi
fi

# flock-guarded: see vpn-dns-regression-check.sh for why (a manual/ad-hoc
# run overlapping the timer's own run could otherwise clobber state into a
# duplicate or missed alert).
exec 200>"$LOCK_FILE"
if flock -n 200; then

mapfile -t prev_failing < <([[ -f "$FAILING_FILE" ]] && sort "$FAILING_FILE" || true)

new_failures=(); for u in "${cur_failing[@]:-}"; do [[ -z "$u" ]] && continue; printf '%s\n' "${prev_failing[@]:-}" | grep -qxF "$u" || new_failures+=("$u"); done
recovered=(); for u in "${prev_failing[@]:-}"; do [[ -z "$u" ]] && continue; printf '%s\n' "${cur_failing[@]:-}" | grep -qxF "$u" || recovered+=("$u"); done

if [[ ${#new_failures[@]} -gt 0 ]]; then
    body="New failed systemd unit(s) on $(hostname) at $(date):${NL}${NL}"
    for u in "${cur_failing[@]}"; do
        body+="- ${u}${NL}"
    done
    body+="${NL}systemctl status <unit> / journalctl -u <unit> for detail."
    /usr/local/bin/send-alert "[server] systemd unit(s) failed" "$body" high rotating_light
    date +%s > "$LAST_ALERT_FILE"
elif [[ ${#cur_failing[@]} -gt 0 ]]; then
    now=$(date +%s)
    last=$(cat "$LAST_ALERT_FILE" 2>/dev/null || echo 0)
    if (( now - last >= ALERT_REPEAT_SECS )); then
        body="Still failed (${#cur_failing[@]} unit(s)) on $(hostname) at $(date):${NL}${NL}"
        for u in "${cur_failing[@]}"; do
            body+="- ${u}${NL}"
        done
        /usr/local/bin/send-alert "[server] systemd unit(s) still failed" "$body" high rotating_light
        date +%s > "$LAST_ALERT_FILE"
    fi
fi

if [[ ${#recovered[@]} -gt 0 ]]; then
    body="Recovered on $(hostname) at $(date):${NL}${NL}"
    for u in "${recovered[@]}"; do
        body+="- ${u}${NL}"
    done
    /usr/local/bin/send-alert "[server] systemd unit(s) recovered" "$body" default white_check_mark
fi

if [[ ${#cur_failing[@]} -eq 0 ]]; then
    rm -f "$FAILING_FILE" "$LAST_ALERT_FILE"
else
    printf '%s\n' "${cur_failing[@]}" > "$FAILING_FILE"
fi

fi   # flock
flock -u 200

[[ ${#cur_failing[@]} -eq 0 ]]
