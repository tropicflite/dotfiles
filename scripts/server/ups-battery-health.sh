#!/bin/bash
# UPS battery health check — weekly digest + degradation alert
# Install: symlinked — /usr/local/bin/ups-battery-health.sh -> this file (dotfiles.map)
# Cron: 0 9 * * 0 /usr/local/bin/ups-battery-health.sh
#
# Method (rewritten 2026-11-22): compare runtime against a baseline recorded
# at the SAME load %. The old method (load_W x runtime = "Wh") was not
# load-invariant — APC's runtime model plus 1%-step load quantisation made the
# "Wh" figure swing 81.6 -> 55.8 between 13% and 7% load with zero real change,
# and its upward-only baseline locked in the best-looking load. A real worn
# battery shows up as less runtime at the same load, which is what we test.
#
# The current reading is the median runtime over the last hour of
# ups-charge-log samples (1/min) at the most common load, since battery.runtime
# flickers between two values minute to minute. Falls back to live upsc.
#
# Baseline file: one line per load %: "<load> <runtime_s> <YYYY-MM-DD>".
# Upward-only per load. Seed/reseed from history: ups-battery-health.sh --seed

UPS_NAME="apc1000"
BASELINE_DIR="/var/lib/ups-battery-health"
BASELINE_FILE="$BASELINE_DIR/baseline-runtime-by-load"
CHARGE_LOG="/var/log/ups-charge.log"
ALERT_EMAIL="alerts@wayoffcourse.ca"
MIN_RUNTIME_S=900    # 15 minutes — flag as critical regardless of baseline
DEGRADE_PCT=25       # percent runtime drop vs same-load baseline before alerting
WINDOW=60            # recent log samples (minutes) to take the median over
MIN_SAMPLES=10       # need this many fully-charged OL samples at the modal load

mkdir -p "$BASELINE_DIR"

send_email() {
    printf "To: %s\nSubject: [Server] %s\nFrom: matt@wayoffcourse.ca\n\n%b\n" \
        "$ALERT_EMAIL" "$1" "$2" | msmtp "$ALERT_EMAIL" || true
}

send_ntfy() {
    /usr/local/bin/send-alert "$1" "$4" "$2" "$3"
}

# Print "load runtime" pairs from ups-charge-log lines, fully-charged steady OL only
# (status=OL exactly — excludes OL_CHRG, OB, CAL, etc.)
log_pairs() {
    awk '{ c=s=r=l=""
           for (i=2;i<=NF;i++) { split($i,kv,"=")
             if (kv[1]=="charge") c=kv[2]; else if (kv[1]=="status") s=kv[2]
             else if (kv[1]=="runtime") r=kv[2]+0; else if (kv[1]=="load") l=kv[2]+0 }
           if (c=="100" && s=="OL" && r>0) print l, r }'
}

# stdin: "load runtime" pairs -> stdout: "load median_runtime count" per load
median_by_load() {
    sort -n -k1,1 -k2,2 | awk '
        { if ($1!=cur && n) { emit() } cur=$1; v[++n]=$2 }
        END { if (n) emit() }
        function emit(  m) { m = (n%2) ? v[(n+1)/2] : int((v[n/2]+v[n/2+1])/2)
                             print cur, m, n; n=0; delete v }'
}

if [ "$1" = "--seed" ]; then
    # Rebuild baseline from all available telemetry (current + rotated logs)
    { for f in $(ls -r "$CHARGE_LOG".*.gz 2>/dev/null); do zcat "$f"; done
      cat "$CHARGE_LOG".1 "$CHARGE_LOG" 2>/dev/null; } | log_pairs | median_by_load |
        awk -v d="$(date +%F)" -v min="$MIN_SAMPLES" '$3>=min { print $1, $2, d }' > "$BASELINE_FILE"
    echo "Seeded $BASELINE_FILE:"; cat "$BASELINE_FILE"
    exit 0
fi

# Read all UPS data in one shot
data=$(upsc "$UPS_NAME" 2>/dev/null)
if [ -z "$data" ]; then
    send_ntfy "[server] UPS health check failed" "high" "warning" "Could not reach UPS $UPS_NAME — nut-server may be down."
    exit 1
fi

get() { echo "$data" | awk -F': ' -v k="$1" '$1==k {print $2}'; }
status=$(get ups.status)
charge=$(get battery.charge)
voltage=$(get battery.voltage)
nominal_w=$(get ups.realpower.nominal)
mfr_date=$(get battery.mfr.date)
xfer_reason=$(get input.transfer.reason)
test_result=$(get ups.test.result)

# Only assess when fully charged on mains — battery.runtime is meaningless otherwise
if ! echo "$status" | grep -q "OL" || [ "${charge:-0}" -lt 99 ]; then
    send_ntfy "[server] UPS health check skipped" "low" "battery" \
        "UPS not fully charged on mains (status=$status charge=${charge}%) — health check deferred."
    exit 0
fi

# Current reading: median runtime at the modal load over the last WINDOW samples
read -r load runtime samples < <(tail -n "$WINDOW" "$CHARGE_LOG" 2>/dev/null | log_pairs |
    median_by_load | sort -k3,3nr | head -1)
if [ -z "$load" ] || [ "${samples:-0}" -lt "$MIN_SAMPLES" ]; then
    load=$(get ups.load); runtime=$(get battery.runtime); samples="1 (live)"
fi

load_w=$(awk -v l="$load" -v n="$nominal_w" 'BEGIN { printf "%d", l/100*n }')
fmt() { printf '%dm %02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

ALERTS=""

if [ "$runtime" -lt "$MIN_RUNTIME_S" ]; then
    ALERTS="CRITICAL: Runtime ($(fmt "$runtime")) at ${load}% load is below the 15-minute minimum. Battery likely needs replacement.\n"
fi

baseline=$(awk -v l="$load" '$1==l' "$BASELINE_FILE" 2>/dev/null)
if [ -n "$baseline" ]; then
    read -r _ base_rt base_date <<< "$baseline"
    drop=$(awk -v c="$runtime" -v b="$base_rt" 'BEGIN { d=(1-c/b)*100; printf "%.0f", (d<0)?0:d }')
    baseline_note="Baseline at ${load}%: $(fmt "$base_rt") (${base_date}) | Change: -${drop}%"
    if [ "$drop" -gt "$DEGRADE_PCT" ]; then
        ALERTS="${ALERTS}WARNING: Runtime at ${load}% load has dropped ${drop}% from baseline ($(fmt "$base_rt") → $(fmt "$runtime")). Battery may be degrading.\n"
    fi
    if [ "$runtime" -gt "$base_rt" ]; then
        awk -v l="$load" -v r="$runtime" -v d="$(date +%F)" '$1==l {$2=r; $3=d} {print}' \
            "$BASELINE_FILE" > "$BASELINE_FILE.tmp" && mv "$BASELINE_FILE.tmp" "$BASELINE_FILE"
    fi
else
    echo "$load $runtime $(date +%F)" >> "$BASELINE_FILE"
    sort -n -o "$BASELINE_FILE" "$BASELINE_FILE"
    baseline_note="No baseline at ${load}% load yet — recorded $(fmt "$runtime") as baseline"
fi

stats="Battery mfr date : ${mfr_date}
Charge            : ${charge}%
Runtime at load   : $(fmt "$runtime") (median of ${samples} samples)
Load              : ${load}% (~${load_w}W of ${nominal_w}W nominal)
Battery voltage   : ${voltage}V
${baseline_note}
Last xfer reason  : ${xfer_reason}
Last self-test    : ${test_result}"

if [ -n "$ALERTS" ]; then
    send_email "UPS Battery Health Warning" "${ALERTS}\n${stats}"
    send_ntfy "[server] UPS battery health warning" "high" "warning,battery" \
        "$(printf '%b' "$ALERTS" | head -1)"
else
    send_ntfy "[server] UPS battery health OK" "low" "battery" \
        "Runtime: $(fmt "$runtime") at ${load}% load | ${baseline_note}"
fi
