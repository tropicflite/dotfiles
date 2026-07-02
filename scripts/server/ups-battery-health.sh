#!/bin/bash
# UPS battery health check — weekly digest + degradation alert
# Install: sudo cp ~/dotfiles/scripts/server/ups-battery-health.sh /usr/local/bin/ups-battery-health.sh && sudo chmod +x /usr/local/bin/ups-battery-health.sh
# Cron: 0 9 * * 0 /usr/local/bin/ups-battery-health.sh

UPS_NAME="apc1000"
BASELINE_DIR="/var/lib/ups-battery-health"
BASELINE_FILE="$BASELINE_DIR/baseline-wh"
ALERT_EMAIL="nichols_matt@pm.me"
MIN_RUNTIME_S=900    # 15 minutes — flag as critical regardless of baseline
DEGRADE_PCT=25       # percent Wh drop from baseline before alerting

mkdir -p "$BASELINE_DIR"

send_email() {
    printf "To: %s\nSubject: [Server] %s\nFrom: matt@wayoffcourse.ca\n\n%b\n" \
        "$ALERT_EMAIL" "$1" "$2" | msmtp "$ALERT_EMAIL" || true
}

send_ntfy() {
    local pass
    pass=$(cat /home/matt/.config/ntfy/password 2>/dev/null) || return 0
    curl -s -u "matt:$pass" \
        -H "Title: $1" -H "Priority: $2" -H "Tags: $3" \
        -d "$4" http://localhost:2586/server-alerts > /dev/null || true
}

# Read all UPS data in one shot
data=$(upsc "$UPS_NAME" 2>/dev/null)
if [ -z "$data" ]; then
    send_ntfy "[server] UPS health check failed" "high" "warning" "Could not reach UPS $UPS_NAME — nut-server may be down."
    exit 1
fi

status=$(echo   "$data" | awk -F': ' '/^ups\.status:/{print $2}')
charge=$(echo   "$data" | awk -F': ' '/^battery\.charge:/{print $2}')
runtime=$(echo  "$data" | awk -F': ' '/^battery\.runtime:/{print $2}')
load=$(echo     "$data" | awk -F': ' '/^ups\.load:/{print $2}')
voltage=$(echo  "$data" | awk -F': ' '/^battery\.voltage:/{print $2}')
nominal_w=$(echo "$data" | awk -F': ' '/^ups\.realpower\.nominal:/{print $2}')
mfr_date=$(echo "$data" | awk -F': ' '/^battery\.mfr\.date:/{print $2}')
xfer_reason=$(echo "$data" | awk -F': ' '/^input\.transfer\.reason:/{print $2}')
test_result=$(echo "$data" | awk -F': ' '/^ups\.test\.result:/{print $2}')

# Only assess capacity when fully charged on mains — battery.runtime is meaningless otherwise
if ! echo "$status" | grep -q "OL" || [ "${charge:-0}" -lt 99 ]; then
    send_ntfy "[server] UPS health check skipped" "low" "battery" \
        "UPS not fully charged on mains (status=$status charge=${charge}%) — health check deferred."
    exit 0
fi

# Estimated Wh = load_watts * runtime_hours
# This normalises runtime across different load levels for fair baseline comparison
wh=$(awk -v load="$load" -v nom="$nominal_w" -v rt="$runtime" \
    'BEGIN { printf "%.1f", (load/100 * nom) * (rt/3600) }')
load_w=$(awk -v load="$load" -v nom="$nominal_w" 'BEGIN { printf "%d", load/100*nom }')
runtime_min=$(( runtime / 60 ))
runtime_sec=$(( runtime % 60 ))

ALERTS=""

# Minimum runtime check
if [ "$runtime" -lt "$MIN_RUNTIME_S" ]; then
    ALERTS="CRITICAL: Runtime (${runtime_min}m ${runtime_sec}s) is below the 15-minute minimum. Battery likely needs replacement.\n"
fi

# Baseline comparison
if [ -f "$BASELINE_FILE" ]; then
    baseline_wh=$(cat "$BASELINE_FILE")
    drop=$(awk -v cur="$wh" -v base="$baseline_wh" \
        'BEGIN { d=(1 - cur/base)*100; printf "%.0f", (d<0) ? 0 : d }')
    baseline_note="Baseline: ${baseline_wh} Wh | Current: ${wh} Wh | Change: -${drop}%"
    if [ "$drop" -gt "$DEGRADE_PCT" ]; then
        ALERTS="${ALERTS}WARNING: Estimated capacity has dropped ${drop}% from baseline (${baseline_wh} Wh → ${wh} Wh). Battery may be degrading.\n"
    fi
    # Update baseline upward only — we want the best healthy reading as reference
    better=$(awk -v cur="$wh" -v base="$baseline_wh" 'BEGIN { print (cur+0 > base+0) ? "yes" : "no" }')
    [ "$better" = "yes" ] && echo "$wh" > "$BASELINE_FILE"
else
    # First run — store as baseline
    echo "$wh" > "$BASELINE_FILE"
    baseline_note="Baseline: ${wh} Wh (set today — first run)"
fi

# Build the stats block used in both ntfy and email
stats="Battery mfr date : ${mfr_date}
Charge            : ${charge}%
Runtime at load   : ${runtime_min}m ${runtime_sec}s
Load              : ${load}% (${load_w}W of ${nominal_w}W nominal)
Battery voltage   : ${voltage}V
Est. capacity     : ${wh} Wh
${baseline_note}
Last xfer reason  : ${xfer_reason}
Last self-test    : ${test_result}"

if [ -n "$ALERTS" ]; then
    send_email "UPS Battery Health Warning" "${ALERTS}\n${stats}"
    send_ntfy "[server] UPS battery health warning" "high" "warning,battery" \
        "$(printf '%b' "$ALERTS" | head -1)"
else
    send_ntfy "[server] UPS battery health OK" "low" "battery" \
        "Runtime: ${runtime_min}m ${runtime_sec}s at ${load}% load | Est. ${wh} Wh | ${baseline_note}"
fi
