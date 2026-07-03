#!/bin/bash
# Temperature monitoring script
# Installed to: /usr/local/bin/temp-monitor.sh
# Source: ~/dotfiles/scripts/server/temp-monitor.sh
# Install: sudo cp ~/dotfiles/scripts/server/temp-monitor.sh /usr/local/bin/temp-monitor.sh && sudo chmod +x /usr/local/bin/temp-monitor.sh
# Cron: */5 * * * * /usr/local/bin/temp-monitor.sh

THRESHOLD_CPU=75
THRESHOLD_NVME=70
THRESHOLD_HDD=55
# /tmp, not /run/user/$(id -u) — see vpn-diskcheck.sh for why (session-scoped,
# gets wiped on SSH logout, defeats the cooldown)
COOLDOWN_FILE="/tmp/temp-monitor-cooldown"
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
if [ -z "$CPU_TEMP" ]; then
    ALERTS="${ALERTS}WARNING: CPU temp sensor unreadable\n"
elif [ "$CPU_TEMP" -gt "$THRESHOLD_CPU" ]; then
    ALERTS="${ALERTS}CPU Package: ${CPU_TEMP}°C (threshold: ${THRESHOLD_CPU}°C)\n"
fi

# NVMe temp
NVME_TEMP=$(sensors | awk '/^Composite/ {gsub(/[^0-9.]/,"",$2); print int($2)}')
if [ -z "$NVME_TEMP" ]; then
    ALERTS="${ALERTS}WARNING: NVMe temp sensor unreadable\n"
elif [ "$NVME_TEMP" -gt "$THRESHOLD_NVME" ]; then
    ALERTS="${ALERTS}NVMe: ${NVME_TEMP}°C (threshold: ${THRESHOLD_NVME}°C)\n"
fi

# HDD temp (sda - USB backup drive)
HDD_TEMP=$(sudo /usr/sbin/smartctl -A /dev/sda | awk '/Temperature_Celsius/ {print int($10)}')
if [ -z "$HDD_TEMP" ]; then
    ALERTS="${ALERTS}WARNING: sda temp sensor unreadable\n"
elif [ "$HDD_TEMP" -gt "$THRESHOLD_HDD" ]; then
    ALERTS="${ALERTS}HDD (sda - backup): ${HDD_TEMP}°C (threshold: ${THRESHOLD_HDD}°C)\n"
fi

# HDD temp (sdb - Immich library drive)
SDB_TEMP=$(sudo /usr/sbin/smartctl -A /dev/sdb | awk '/Temperature_Celsius/ {print int($10)}')
if [ -z "$SDB_TEMP" ]; then
    ALERTS="${ALERTS}WARNING: sdb temp sensor unreadable\n"
elif [ "$SDB_TEMP" -gt "$THRESHOLD_HDD" ]; then
    ALERTS="${ALERTS}HDD (sdb - Immich library): ${SDB_TEMP}°C (threshold: ${THRESHOLD_HDD}°C)\n"
fi

# Send alert if any thresholds exceeded
if [ -n "$ALERTS" ]; then
    echo -e "Subject: [${HOSTNAME}] Temperature Alert\n\nTemperature thresholds exceeded:\n\n${ALERTS}" | \
        NTFY_PRIORITY=high NTFY_TAGS=thermometer NTFY_BODY="Temperature thresholds exceeded on ${HOSTNAME}:\n\n${ALERTS}" \
        /usr/local/bin/send-mail
    date +%s > "$COOLDOWN_FILE"
fi
