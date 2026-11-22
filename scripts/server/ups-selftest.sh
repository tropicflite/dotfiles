#!/bin/bash
# Monthly UPS quick self-test — alerts only on failure (dark cockpit).
# Install: symlinked — /usr/local/bin/ups-selftest.sh -> this file (dotfiles.map)
# Cron (root): 0 10 15 * * /usr/local/bin/ups-selftest.sh
# Runs as root: needs the [admin] password from /etc/nut/upsd.users for upscmd.
# Log: /var/log/ups-selftest.log (one line per run)
#
# A quick test takes ~40s: status cycles OL -> OL OFF -> CAL DISCHRG -> OL CHRG,
# and ups.test.result reads "Done and passed" ~20s after it's back on OL.
# Status never goes OB, so upssched's on-battery alerts don't fire.
# Battery recharges for a few hours afterwards — the 15th is never a Sunday
# 09:00 problem for ups-battery-health (it skips when not fully charged anyway).

UPS=apc1000
LOG=/var/log/ups-selftest.log
TIMEOUT=240

log() { echo "$(date -Iseconds) $*" >> "$LOG"; }

alert() {  # <subject> <body>
    printf "Subject: [Server] %s\nTo: alerts@wayoffcourse.ca\nFrom: matt@wayoffcourse.ca\n\n%b\n" "$1" "$2" |
        BYPASS_DIGEST=1 NTFY_PRIORITY=high NTFY_TAGS=warning,battery \
        NTFY_BODY="$(printf '%b' "$2" | head -1)" /usr/local/bin/send-mail
}

v() { upsc "$UPS" "$1" 2>/dev/null; }

status=$(v ups.status)
charge=$(v battery.charge)
if [ -z "$status" ]; then
    log "SKIP: UPS unreachable"
    alert "UPS self-test could not run" "Could not reach UPS $UPS via upsc — nut-server may be down."
    exit 1
fi
if [[ "$status" == *RB* ]]; then
    log "RB: replace-battery flag already set before test (status=$status)"
    alert "UPS battery needs replacement" "UPS $UPS status is '$status' (RB = replace battery) before the monthly self-test.\nBattery mfr date: $(v battery.mfr.date)"
fi
if [[ "$status" != OL* ]] || [ "${charge:-0}" -lt 95 ]; then
    log "SKIP: not on mains / not charged (status=$status charge=$charge)"
    exit 0
fi

pw=$(awk '/^\[admin\]/{f=1;next} /^\[/{f=0} f && /password/{sub(/.*=[ \t]*/,"");print}' /etc/nut/upsd.users)
if ! out=$(upscmd -u admin -p "$pw" "$UPS" test.battery.start.quick 2>&1); then
    unset pw
    log "FAIL: upscmd refused: $out"
    alert "UPS self-test could not start" "upscmd test.battery.start.quick failed on $UPS:\n$out"
    exit 1
fi
unset pw

# Wait for the test to visibly start (status leaves plain OL), then for it to
# return to OL and the result to settle.
start=$(date +%s); seen=0; back=0; v_min=$(v battery.voltage)
while (( $(date +%s) - start < TIMEOUT )); do
    sleep 3
    s=$(v ups.status); bv=$(v battery.voltage)
    awk -v a="$bv" -v b="$v_min" 'BEGIN{exit !(a+0 < b+0)}' && v_min=$bv
    if [[ "$s" =~ CAL|OFF|TEST|DISCHRG|OB ]]; then seen=1; back=0; continue; fi
    if (( seen )) && [[ "$s" == OL* ]]; then
        (( back == 0 )) && back=$(date +%s)
        r=$(v ups.test.result)
        # result lags ~18s behind the return to OL, and a stale "Done and passed"
        # from last month is still there until then — never read it sooner than 30s
        [[ "$r" == Done* || "$r" == Abort* ]] && (( $(date +%s) - back >= 30 )) && break
        (( $(date +%s) - back >= 90 )) && break
    fi
done

result=$(v ups.test.result)
status=$(v ups.status)
elapsed=$(( $(date +%s) - start ))
summary="result='$result' status='$status' min_batt_v=${v_min}V elapsed=${elapsed}s load=$(v ups.load)% runtime=$(v battery.runtime)s"
log "$summary"

if (( ! seen )); then
    alert "UPS self-test did not run" "upscmd accepted the quick test but the UPS status never changed within ${TIMEOUT}s.\n$summary"
    exit 1
fi
if [[ "$result" != "Done and passed" ]]; then
    alert "UPS self-test FAILED" "UPS $UPS monthly quick self-test result: '$result'. Battery likely needs replacement.\n$summary\nBattery mfr date: $(v battery.mfr.date)"
    exit 1
fi
if [[ "$status" == *RB* ]]; then
    alert "UPS battery needs replacement" "Self-test reported passed but UPS status is '$status' (RB = replace battery).\n$summary"
fi
exit 0
