#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock
sshd
crond

STAMP="$HOME/.last-upgrade"
NOW=$(date +%s)
LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
if (( NOW - LAST > 86400 )); then
    date +%s > "$STAMP"
    "$HOME/bin/termux-upgrade"
fi
