#!/bin/bash
# Health monitoring script - daily digest
# Installed to: /usr/local/bin/health-monitor.sh
# Source: ~/dotfiles/scripts/server/health-monitor.sh
# Install: sudo cp ~/dotfiles/scripts/server/health-monitor.sh /usr/local/bin/health-monitor.sh && sudo chmod +x /usr/local/bin/health-monitor.sh
# Cron: 0 2 * * * /usr/local/bin/health-monitor.sh

DISK_THRESHOLD=80
MEM_THRESHOLD=10
LOAD_THRESHOLD=4.0
RESTART_STATE=/tmp/health-monitor-restarts
TO="nichols_matt@pm.me"
HOSTNAME=$(hostname)

ALERTS=""

# Disk usage
while IFS= read -r line; do
    usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')
    if [ "$usage" -gt "$DISK_THRESHOLD" ]; then
        ALERTS="${ALERTS}Disk ${mount}: ${usage}% used (threshold: ${DISK_THRESHOLD}%)\n"
    fi
done < <(df -h --output=source,size,used,avail,pcent,target -x tmpfs -x devtmpfs | tail -n +2)

# Memory
MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_AVAILABLE=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
MEM_PCT=$(( MEM_AVAILABLE * 100 / MEM_TOTAL ))
if [ "$MEM_PCT" -lt "$MEM_THRESHOLD" ]; then
    ALERTS="${ALERTS}Memory: only ${MEM_PCT}% available (threshold: ${MEM_THRESHOLD}%)\n"
fi

# Load average (15-min)
LOAD=$(awk '{print $3}' /proc/loadavg)
LOAD_INT=$(echo "$LOAD" | awk -F. '{print $1}')
LOAD_THRESH_INT=$(echo "$LOAD_THRESHOLD" | awk -F. '{print $1}')
if [ "$LOAD_INT" -ge "$LOAD_THRESH_INT" ]; then
    ALERTS="${ALERTS}Load average (15m): ${LOAD} (threshold: ${LOAD_THRESHOLD})\n"
fi

# Container restart counts
CURRENT_RESTARTS=$(docker ps --format '{{.Names}} {{.Status}}' | grep -oP '\(\K[0-9]+(?= restart)')
if [ -f "$RESTART_STATE" ]; then
    PREV_RESTARTS=$(cat "$RESTART_STATE")
    if [ "$CURRENT_RESTARTS" != "$PREV_RESTARTS" ]; then
        ALERTS="${ALERTS}Container restart counts changed:\n$(docker ps --format '  {{.Names}}: {{.Status}}')\n"
    fi
fi
echo "$CURRENT_RESTARTS" > "$RESTART_STATE"

# Failed systemd units
FAILED=$(systemctl --failed --no-legend --no-pager | grep -v '^$')
if [ -n "$FAILED" ]; then
    ALERTS="${ALERTS}Failed systemd units:\n${FAILED}\n"
fi

# Send alert if anything flagged
if [ -n "$ALERTS" ]; then
    echo -e "Subject: [${HOSTNAME}] Health Alert\n\nIssues detected:\n\n${ALERTS}" | \
        msmtp -C /etc/msmtprc "$TO"
fi
