#!/bin/bash
# Temperature monitoring script
# Installed to: /usr/local/bin/temp-monitor.sh
# Source: ~/dotfiles/scripts/server/temp-monitor.sh
# Install: sudo cp ~/dotfiles/scripts/server/temp-monitor.sh /usr/local/bin/temp-monitor.sh && sudo chmod +x /usr/local/bin/temp-monitor.sh
# Cron: */5 * * * * /usr/local/bin/temp-monitor.sh

THRESHOLD_CPU=75
THRESHOLD_NVME=70
THRESHOLD_HDD=50
COOLDOWN_FILE=/tmp/temp-monitor-cooldown
COOLDOWN_MINUTES=30
TO="nichols_matt@pm.me"
HOSTNAME=$(hostname)

# Check cooldown
if [ -f "$COOLDOWN_FILE" ]; then
    last=$(cat "$COOLDOWN_FILE")
    now=$(date +%s)
    elapsed=$(( (now - last) / 60 ))
    if [ "$elapsed" -lt "$COOLDOWN_MINUTES" ]; then
        exit 0
    fi
fi

ALERTS=""

# CPU temp
CPU_TEMP=$(sensors | awk '/Package id 0/ {gsub(/[^0-9.]/,"",$4); print int($4)}')
if [ "$CPU_TEMP" -gt "$THRESHOLD_CPU" ]; then
    ALERTS="${ALERTS}CPU Package: ${CPU_TEMP}°C (threshold: ${THRESHOLD_CPU}°C)\n"
fi

# NVMe temp
NVME_TEMP=$(sensors | awk '/^Composite/ {gsub(/[^0-9.]/,"",$2); print int($2)}')
if [ "$NVME_TEMP" -gt "$THRESHOLD_NVME" ]; then
    ALERTS="${ALERTS}NVMe: ${NVME_TEMP}°C (threshold: ${THRESHOLD_NVME}°C)\n"
fi

# HDD temp
HDD_TEMP=$(sudo /usr/sbin/smartctl -A /dev/sda | awk '/Temperature_Celsius/ {print int($10)}')
if [ "$HDD_TEMP" -gt "$THRESHOLD_HDD" ]; then
    ALERTS="${ALERTS}HDD: ${HDD_TEMP}°C (threshold: ${THRESHOLD_HDD}°C)\n"
fi

# Send alert if any thresholds exceeded
if [ -n "$ALERTS" ]; then
    echo -e "Subject: [${HOSTNAME}] Temperature Alert\n\nTemperature thresholds exceeded:\n\n${ALERTS}" | \
        msmtp -C /etc/msmtprc "$TO"
    date +%s > "$COOLDOWN_FILE"
fi
