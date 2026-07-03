#!/bin/bash
# Daily recyclarr sync with failure alerting.
# Run via cron: 0 3 * * * /home/matt/bin/recyclarr-sync.sh >> /var/log/recyclarr.log 2>&1

EMAIL="nichols_matt@pm.me"
LOG_TAG="recyclarr-sync"

output=$(docker exec recyclarr recyclarr sync 2>&1)
exit_code=$?

echo "[$(date -Iseconds)] exit=${exit_code}"
echo "$output"

if [ "$exit_code" -ne 0 ]; then
    logger -t "$LOG_TAG" "recyclarr sync failed (exit ${exit_code})"

    ntfy_body="recyclarr sync failed on $(hostname) at $(date) (exit ${exit_code}). Check /var/log/recyclarr.log."
    printf "Subject: [server] recyclarr sync failed\nTo: %s\nFrom: matt@wayoffcourse.ca\n\nrecyclarr sync failed on %s at %s (exit code %s).\n\nOutput:\n%s\n" \
        "$EMAIL" "$(hostname)" "$(date)" "$exit_code" "$output" | \
        NTFY_PRIORITY=high NTFY_TAGS=warning NTFY_BODY="$ntfy_body" \
        /usr/local/bin/send-mail
fi
