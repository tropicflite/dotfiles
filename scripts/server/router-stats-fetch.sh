#!/bin/bash
OUTPUT="/home/matt/router-stats/router-stats.json"
TMP="${OUTPUT}.tmp"

if ssh -o BatchMode=yes -o ConnectTimeout=5 router /jffs/scripts/router-stats.sh > "$TMP" 2>/dev/null; then
  mv "$TMP" "$OUTPUT"
else
  rm -f "$TMP"
fi
