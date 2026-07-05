#!/bin/bash
# Arr pipeline synthetic health check
# Installed to: /usr/local/bin/arr-pipeline-check.sh (symlink)
# Source: ~/dotfiles/scripts/server/arr-pipeline-check.sh
# Install: sudo ln -s ~/dotfiles/scripts/server/arr-pipeline-check.sh /usr/local/bin/arr-pipeline-check.sh
# Cron: 0 7 * * * /usr/local/bin/arr-pipeline-check.sh
#
# Built 2026-07-05 after a single stuck Jellyseerr request turned out to have
# four independent broken links (qBittorrent auth whitelist drift, stale
# Prowlarr->Sonarr indexer key, over-restrictive Jellyseerr default quality
# profiles, Sonarr rename-episodes off breaking Jellyfin identification) that
# none of the container-liveness monitoring (Homepage/Kuma) would ever catch,
# because the containers were all "up and healthy" the whole time. See
# memory: project_arr_pipeline_monitoring_gap_20260705.
#
# This actively exercises the pipeline instead of just checking container
# state: Sonarr/Radarr health, live indexer connectivity (via Prowlarr),
# live qBittorrent auth, Prowlarr's own health, a direct config-drift check
# on qBittorrent's auth whitelist (the one thing in this whole chain with no
# version control or audit trail), and a Jellyfin library scan for anything
# unidentified or missing episode numbers.
#
# Runs once daily, not more often: indexer/testall issues real outbound
# search queries to every configured indexer, so hammering it on a short
# interval risks looking like abuse to trackers (we tripped a transient 429
# from our own manual testing during the incident this was built for).

LOG=/var/log/arr-pipeline-check.log
TO="nichols_matt@pm.me"
HOST=$(hostname)
ALERTS=""

log() {
    printf '%s %b\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"
}

get_ip() {
    docker inspect "$1" --format '{{.NetworkSettings.Networks.arrs.IPAddress}}' 2>/dev/null
}

SONARR_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' /home/matt/docker/arrs/sonarr/config/config.xml 2>/dev/null)
RADARR_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' /home/matt/docker/arrs/radarr/config/config.xml 2>/dev/null)
PROWLARR_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' /home/matt/docker/arrs/prowlarr/config/config.xml 2>/dev/null)
JELLYFIN_KEY=$(sudo sqlite3 /opt/docker/jellyfin/config/data/jellyfin.db "SELECT AccessToken FROM ApiKeys WHERE Name='Jellyseerr' LIMIT 1;" 2>/dev/null)

SONARR_IP=$(get_ip sonarr)
RADARR_IP=$(get_ip radarr)
PROWLARR_IP=$(get_ip prowlarr)
JELLYFIN_IP=$(get_ip jellyfin)

if [ -z "$SONARR_IP" ] || [ -z "$RADARR_IP" ] || [ -z "$PROWLARR_IP" ] || [ -z "$JELLYFIN_IP" ]; then
    ALERTS="${ALERTS}One or more arr-stack containers (sonarr/radarr/prowlarr/jellyfin) are not running or not reachable on the arrs network.\n"
fi

# --- Sonarr: health, live indexer test, live download client test ---
if [ -n "$SONARR_IP" ] && [ -n "${SONARR_KEY}" ]; then
    H=$(curl -s --max-time 15 "http://$SONARR_IP:8989/api/v3/health" -H "X-Api-Key: ${SONARR_KEY}" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for h in d:
    print(f\"  [{h['type']}] {h['source']}: {h['message']}\")
" 2>/dev/null)
    [ -n "$H" ] && ALERTS="${ALERTS}Sonarr health:\n${H}\n"

    I=$(curl -s --max-time 60 -X POST "http://$SONARR_IP:8989/api/v3/indexer/testall" -H "X-Api-Key: ${SONARR_KEY}" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in d:
    if not r.get('isValid', True):
        for f in r.get('validationFailures', []):
            print(f\"  indexer {r['id']}: {f['errorMessage']}\")
" 2>/dev/null)
    [ -n "$I" ] && ALERTS="${ALERTS}Sonarr indexer test failures:\n${I}\n"

    D=$(curl -s --max-time 30 -X POST "http://$SONARR_IP:8989/api/v3/downloadclient/testall" -H "X-Api-Key: ${SONARR_KEY}" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in d:
    if not r.get('isValid', True):
        for f in r.get('validationFailures', []):
            print(f\"  download client {r['id']}: {f['errorMessage']}\")
" 2>/dev/null)
    [ -n "$D" ] && ALERTS="${ALERTS}Sonarr download client test failures:\n${D}\n"
fi

# --- Radarr: same three checks ---
if [ -n "$RADARR_IP" ] && [ -n "${RADARR_KEY}" ]; then
    H=$(curl -s --max-time 15 "http://$RADARR_IP:7878/api/v3/health" -H "X-Api-Key: ${RADARR_KEY}" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for h in d:
    print(f\"  [{h['type']}] {h['source']}: {h['message']}\")
" 2>/dev/null)
    [ -n "$H" ] && ALERTS="${ALERTS}Radarr health:\n${H}\n"

    I=$(curl -s --max-time 60 -X POST "http://$RADARR_IP:7878/api/v3/indexer/testall" -H "X-Api-Key: ${RADARR_KEY}" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in d:
    if not r.get('isValid', True):
        for f in r.get('validationFailures', []):
            print(f\"  indexer {r['id']}: {f['errorMessage']}\")
" 2>/dev/null)
    [ -n "$I" ] && ALERTS="${ALERTS}Radarr indexer test failures:\n${I}\n"

    D=$(curl -s --max-time 30 -X POST "http://$RADARR_IP:7878/api/v3/downloadclient/testall" -H "X-Api-Key: ${RADARR_KEY}" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in d:
    if not r.get('isValid', True):
        for f in r.get('validationFailures', []):
            print(f\"  download client {r['id']}: {f['errorMessage']}\")
" 2>/dev/null)
    [ -n "$D" ] && ALERTS="${ALERTS}Radarr download client test failures:\n${D}\n"
fi

# --- Prowlarr: health ---
if [ -n "$PROWLARR_IP" ] && [ -n "${PROWLARR_KEY}" ]; then
    P=$(curl -s --max-time 15 "http://$PROWLARR_IP:9696/api/v1/health" -H "X-Api-Key: ${PROWLARR_KEY}" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for h in d:
    print(f\"  [{h['type']}] {h['source']}: {h['message']}\")
" 2>/dev/null)
    [ -n "$P" ] && ALERTS="${ALERTS}Prowlarr health:\n${P}\n"
fi

# --- qBittorrent auth whitelist config drift (the one setting with no audit trail) ---
WHITELIST=$(grep -oP '(?<=WebUI\\AuthSubnetWhitelist=).*' /home/matt/docker/qbittorrent/config/qBittorrent/qBittorrent.conf 2>/dev/null)
if [ "$WHITELIST" != "172.20.0.0/16" ]; then
    ALERTS="${ALERTS}qBittorrent AuthSubnetWhitelist has drifted from the documented 172.20.0.0/16 (currently: '${WHITELIST:-unset}') — Sonarr/Radarr will fail to authenticate and eventually get IP-banned.\n"
fi

# --- Jellyfin: unidentified series/movies, episodes missing season/episode number ---
if [ -n "$JELLYFIN_IP" ] && [ -n "${JELLYFIN_KEY}" ]; then
    for TYPE in Series Movie; do
        U=$(curl -s --max-time 20 "http://$JELLYFIN_IP:8096/Items?IncludeItemTypes=$TYPE&Recursive=true&Fields=ProviderIds" -H "X-Emby-Token: ${JELLYFIN_KEY}" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for i in d.get('Items', []):
    if not i.get('ProviderIds'):
        print(f\"  {i['Name']}\")
" 2>/dev/null)
        [ -n "$U" ] && ALERTS="${ALERTS}Jellyfin unidentified ${TYPE}s (no provider match):\n${U}\n"
    done

    E=$(curl -s --max-time 20 "http://$JELLYFIN_IP:8096/Items?IncludeItemTypes=Episode&Recursive=true&Fields=ProviderIds" -H "X-Emby-Token: ${JELLYFIN_KEY}" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for i in d.get('Items', []):
    if 'IndexNumber' not in i:
        print(f\"  {i.get('SeriesName', '?')}: {i['Name']}\")
" 2>/dev/null)
    [ -n "$E" ] && ALERTS="${ALERTS}Jellyfin episodes missing season/episode number:\n${E}\n"
fi

# --- Report ---
if [ -n "$ALERTS" ]; then
    log "ISSUES FOUND:\n${ALERTS}"
    echo -e "Subject: [${HOST}] Arr Pipeline Check Alert\nTo: ${TO}\nFrom: matt@wayoffcourse.ca\n\nSynthetic end-to-end pipeline check found issues:\n\n${ALERTS}" | \
        NTFY_PRIORITY=high NTFY_TAGS=warning NTFY_BODY="Arr pipeline check found issues on ${HOST} — see email for details." \
        /usr/local/bin/send-mail
else
    log "OK - all checks passed"
fi
