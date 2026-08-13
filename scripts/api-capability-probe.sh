#!/usr/bin/env bash
# api-capability-probe.sh — ground-truth what the media stack's APIs actually
# expose, before anything is built on top of them.
#
# STRICTLY READ-ONLY. Every call is a GET, with one exception: qBittorrent's
# /auth/login is a POST because its API has no other way to obtain a session.
# Nothing here creates, updates, deletes, searches, or triggers a command.
#
# WHY IT RUNS OVER SSH RATHER THAN STRAIGHT AT THE LAN IP
# -------------------------------------------------------
# Each *arr's API key is equivalent to full control of that app. The Ansible
# `servarr` role deliberately talks to 127.0.0.1 so the key never leaves the
# container, and this probe keeps that property: the curl runs ON the host, the
# key is read from that host's own config, and only the RESPONSE crosses the
# LAN. Keys are never printed and never land in your shell history.
#
# (A dashboard cannot preserve this property — it has to hold every key
# centrally. That is a real security decision, not an implementation detail;
# see docs/DASHBOARD-CAPABILITIES.md § "Auth is the hard part".)
#
# USAGE — run from the Mac on the LAN, with id_ed25519_ansible loaded:
#   ./scripts/api-capability-probe.sh              # summary: what answered
#   ./scripts/api-capability-probe.sh -v           # + a shape sample per probe
#   ./scripts/api-capability-probe.sh -o ./out     # also dump raw JSON per probe
#
# Requires: ssh, jq (locally — the LXCs are not assumed to have it).
set -uo pipefail

VERBOSE=0
OUTDIR=""
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_ansible}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)

while getopts "vo:k:h" opt; do
  case "$opt" in
    v) VERBOSE=1 ;;
    o) OUTDIR="$OPTARG" ;;
    k) SSH_KEY="$OPTARG" ;;
    h) sed -n '2,30p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }
[[ -n "$OUTDIR" ]] && mkdir -p "$OUTDIR"

# host -> ip. Mirrors ansible/inventory/hosts.yml (live legacy IPs; PET-49).
declare -A IP=(
  [lidarr]=192.168.50.14  [seerr]=192.168.50.33   [plex]=192.168.50.140
  [sonarr]=192.168.50.15  [radarr]=192.168.50.16  [prowlarr]=192.168.50.20
  [qbittorrent-vpn]=192.168.50.21
)
# *arr: port + API version. Lidarr/Prowlarr never moved off v1.
declare -A ARR_PORT=([sonarr]=8989 [radarr]=7878 [lidarr]=8686 [prowlarr]=9696)
declare -A ARR_VER=( [sonarr]=v3   [radarr]=v3   [lidarr]=v1   [prowlarr]=v1  )

PASS=0; FAIL=0; SKIP=0
declare -a NOTES=()

# report <host> <label> <json-or-empty> <jq-shape-expr>
report() {
  local host="$1" label="$2" body="$3" shape="${4:-type}"
  if [[ -z "$body" ]] || ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    printf '  %-34s \033[31mNO / NOT JSON\033[0m\n' "$label"
    FAIL=$((FAIL + 1))
    return 1
  fi
  printf '  %-34s \033[32mYES\033[0m\n' "$label"
  PASS=$((PASS + 1))
  if [[ "$VERBOSE" == 1 ]]; then
    printf '%s' "$body" | jq -r "$shape" 2>/dev/null | sed 's/^/      /' | head -14
  fi
  if [[ -n "$OUTDIR" ]]; then
    printf '%s' "$body" > "$OUTDIR/${host}.${label//[^a-zA-Z0-9]/_}.json"
  fi
}

# ssh_curl <host> <remote-shell-snippet> — runs on the host, echoes stdout here.
ssh_curl() {
  local host="$1" snippet="$2"
  ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "root@${IP[$host]}" "$snippet" 2>/dev/null
}

hr() { printf '\n\033[1m── %s\033[0m (%s)\n' "$1" "${IP[$1]:-?}"; }

# ---------------------------------------------------------------- the *arrs --
# config.xml holds the key and the port; read both on the host, same as the
# Ansible role does, rather than pinning them here.
probe_arr() {
  local host="$1" port="${ARR_PORT[$1]}" ver="${ARR_VER[$1]}"
  hr "$host"

  local pre="K=\$(sed -n 's|.*<ApiKey>\\(.*\\)</ApiKey>.*|\\1|p' /var/lib/$host/config.xml)"
  local get="curl -sS --max-time 20 -H \"X-Api-Key: \$K\""
  local base="http://127.0.0.1:$port/api/$ver"

  report "$host" "system/status (version)" \
    "$(ssh_curl "$host" "$pre; $get $base/system/status")" \
    '{version, appName, instanceName, isLinux, packageUpdateMechanism, startTime}'

  report "$host" "health (active warnings)" \
    "$(ssh_curl "$host" "$pre; $get $base/health")" \
    'if length==0 then "no health warnings" else .[] | "\(.type): \(.message)" end'

  report "$host" "queue (+errors, downloadId)" \
    "$(ssh_curl "$host" "$pre; $get \"$base/queue?pageSize=200&includeUnknownSeriesItems=true&includeUnknownMovieItems=true\"")" \
    '{total: .totalRecords, sample: (.records[0] // {} | {title, status, trackedDownloadStatus, trackedDownloadState, errorMessage, downloadId, downloadClient, indexer})}'

  report "$host" "update (feed: installed/installable)" \
    "$(ssh_curl "$host" "$pre; $get $base/update")" \
    '[.[] | select(.installed or .installable)] | map({version, installed, installable, latest})'

  case "$host" in
    sonarr)
      report "$host" "series (count)" \
        "$(ssh_curl "$host" "$pre; $get $base/series")" \
        '{series: length, sample: (.[0] // {} | {id, title, tvdbId, monitored, "episodeFileCount": .statistics.episodeFileCount, "episodeCount": .statistics.episodeCount})}'
      # THE episode-level probe — this is the "exact episodes" capability.
      local sid
      sid="$(ssh_curl "$host" "$pre; $get $base/series" | jq -r '.[0].id // empty' 2>/dev/null)"
      if [[ -n "$sid" ]]; then
        report "$host" "episode?seriesId=$sid (per-episode)" \
          "$(ssh_curl "$host" "$pre; $get \"$base/episode?seriesId=$sid&includeEpisodeFile=true\"")" \
          '{episodes: length, sample: (.[0] // {} | {id, seasonNumber, episodeNumber, title, airDateUtc, monitored, hasFile, "quality": .episodeFile.quality.quality.name})}'
      else
        printf '  %-34s \033[33mSKIP (no series to sample)\033[0m\n' "episode?seriesId=…"; SKIP=$((SKIP + 1))
      fi
      report "$host" "wanted/missing (paged)" \
        "$(ssh_curl "$host" "$pre; $get \"$base/wanted/missing?pageSize=5&monitored=true&includeSeries=true\"")" \
        '{missing: .totalRecords, sample: (.records[0] // {} | {seasonNumber, episodeNumber, title, airDateUtc})}'
      ;;
    radarr)
      report "$host" "movie (count)" \
        "$(ssh_curl "$host" "$pre; $get $base/movie")" \
        '{movies: length, sample: (.[0] // {} | {id, title, tmdbId, monitored, hasFile, isAvailable})}'
      report "$host" "wanted/missing (paged)" \
        "$(ssh_curl "$host" "$pre; $get \"$base/wanted/missing?pageSize=5&monitored=true\"")" \
        '{missing: .totalRecords, sample: (.records[0] // {} | {title, year, isAvailable})}'
      ;;
    prowlarr)
      report "$host" "indexer (health per indexer)" \
        "$(ssh_curl "$host" "$pre; $get $base/indexer")" \
        '{indexers: length, sample: (.[0] // {} | {id, name, enable, protocol, priority})}'
      ;;
  esac
}

for h in sonarr radarr lidarr prowlarr; do probe_arr "$h"; done

# ------------------------------------------------------------------- seerr --
# Overseerr-lineage API: /api/v1, X-Api-Key. The key lives in settings.json.
hr seerr
SEERR_PRE='K=$(jq -r ".main.apiKey // empty" /opt/seerr/config/settings.json 2>/dev/null \
  || sed -n "s/.*\"apiKey\":\"\([^\"]*\)\".*/\1/p" /opt/seerr/config/settings.json)'
SEERR_GET='curl -sS --max-time 20 -H "X-Api-Key: $K"'
SEERR_BASE='http://127.0.0.1:5055/api/v1'

report seerr "status (version)" \
  "$(ssh_curl seerr "$SEERR_PRE; $SEERR_GET $SEERR_BASE/status")" '.'

# The single most important probe in this file: does a request carry the
# downstream Sonarr/Radarr id and the Plex ratingKey? If yes, the whole
# cross-app trace is a join rather than a fuzzy title match.
report seerr "request (+media.externalServiceId)" \
  "$(ssh_curl seerr "$SEERR_PRE; $SEERR_GET \"$SEERR_BASE/request?take=20&sort=modified\"")" \
  '{total: .pageInfo.results, sample: (.results[0] // {} | {
      id, status, type, createdAt,
      requestedBy: .requestedBy.displayName,
      seasons: [.seasons[]?.seasonNumber],
      media: (.media // {} | {tmdbId, tvdbId, status, status4k, serviceId, externalServiceId, externalServiceSlug, ratingKey, mediaAddedAt})
    })}'

report seerr "request/count (status rollup)" \
  "$(ssh_curl seerr "$SEERR_PRE; $SEERR_GET $SEERR_BASE/request/count")" '.'

report seerr "settings/sonarr (service ids)" \
  "$(ssh_curl seerr "$SEERR_PRE; $SEERR_GET $SEERR_BASE/settings/sonarr")" \
  '[.[] | {id, name, hostname, port, is4k, isDefault}]'

report seerr "settings/radarr (service ids)" \
  "$(ssh_curl seerr "$SEERR_PRE; $SEERR_GET $SEERR_BASE/settings/radarr")" \
  '[.[] | {id, name, hostname, port, is4k, isDefault}]'

# -------------------------------------------------------------------- plex --
# XML, not JSON — ask for JSON explicitly via Accept. Token from Preferences.xml
# and sent as a header, never in the query string (same as media-lifecycle).
hr plex
PLEX_PRE='T=$(sed -n "s/.*PlexOnlineToken=\"\([^\"]*\)\".*/\1/p" \
  "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml")'
PLEX_GET='curl -sS --max-time 20 -H "Accept: application/json" -H "X-Plex-Token: $T"'

report plex "identity+capabilities (/)" \
  "$(ssh_curl plex "$PLEX_PRE; $PLEX_GET http://127.0.0.1:32400/")" \
  '.MediaContainer | {version, platform, machineIdentifier, myPlexUsername, transcoderActiveVideoSessions}'

report plex "library/sections (scan targets)" \
  "$(ssh_curl plex "$PLEX_PRE; $PLEX_GET http://127.0.0.1:32400/library/sections")" \
  '[.MediaContainer.Directory[]? | {key, type, title, refreshing, scannedAt}]'

report plex "status/sessions (who is watching)" \
  "$(ssh_curl plex "$PLEX_PRE; $PLEX_GET http://127.0.0.1:32400/status/sessions")" \
  '{sessions: (.MediaContainer.size // 0)}'

# Does the built-in updater report anything on an apt install? Expected to be
# empty/unsupported — which is the finding, not a failure. See the doc.
report plex "updater/status (expect: unsupported)" \
  "$(ssh_curl plex "$PLEX_PRE; $PLEX_GET http://127.0.0.1:32400/updater/status")" \
  '.MediaContainer | {canInstall, downloadURL, version, size}'
NOTES+=("plex: an empty or error 'updater/status' CONFIRMS the apt path is the only real update route — see docs/DASHBOARD-CAPABILITIES.md § 3.")

# ------------------------------------------------------------- qbittorrent --
# Cookie auth. The login POST is the one non-GET in this script and is required
# to read anything. Password comes from the host's .env, never echoed.
hr qbittorrent-vpn
QB_PRE='P=$(sed -n "s/^QBIT_WEBUI_PASSWORD=//p" /opt/qbittorrent-vpn/.env | tr -d "\r"); \
  C=$(mktemp); curl -sS --max-time 20 -c "$C" -H "Referer: http://localhost:8080" \
    --data-urlencode "username=admin" --data-urlencode "password=$P" \
    http://localhost:8080/api/v2/auth/login >/dev/null'
QB_GET='curl -sS --max-time 20 -b "$C" -H "Referer: http://localhost:8080"'

QB='http://localhost:8080/api/v2'

report qbittorrent-vpn "torrents/info (hash join key)" \
  "$(ssh_curl qbittorrent-vpn "$QB_PRE; $QB_GET '$QB/torrents/info?limit=5'; rm -f \"\$C\"")" \
  '{torrents: length, sample: (.[0] // {} | {hash, name, state, progress, dlspeed, eta, num_seeds, num_complete, category, tags, save_path})}'

report qbittorrent-vpn "transfer/info (tunnel throughput)" \
  "$(ssh_curl qbittorrent-vpn "$QB_PRE; $QB_GET $QB/transfer/info; rm -f \"\$C\"")" \
  '{dl_info_speed, up_info_speed, connection_status}'

# Version decides the action-endpoint naming: qBittorrent 5.0 renamed
# /torrents/pause -> /torrents/stop and /torrents/resume -> /torrents/start.
# Anything written for Phase 2 must branch on this.
report qbittorrent-vpn "app/version (5.x = stop/start API)" \
  "$(ssh_curl qbittorrent-vpn "$QB_PRE; $QB_GET $QB/app/version | jq -R .; rm -f \"\$C\"")" '.'

# listen_port is half of the port-forward comparison; gluetun's /v1/portforward
# is the other half. A mismatch is the signature of a dead port-sync sidecar.
report qbittorrent-vpn "app/preferences (listen_port)" \
  "$(ssh_curl qbittorrent-vpn "$QB_PRE; $QB_GET $QB/app/preferences; rm -f \"\$C\"")" \
  '{listen_port, random_port, upnp, max_connec, queueing_enabled, save_path}'

# Delta-polling endpoint the WebUI itself uses — top-level shape only, it is big.
report qbittorrent-vpn "sync/maindata (delta polling)" \
  "$(ssh_curl qbittorrent-vpn "$QB_PRE; $QB_GET '$QB/sync/maindata?rid=0'; rm -f \"\$C\"")" \
  '{rid, full_update, torrent_count: (.torrents | length), keys: (keys)}'

# Per-torrent diagnostics: tracker msg is the real "why is this dead" field, and
# the file list is episode-level truth inside a season pack.
QB_HASH="$(ssh_curl qbittorrent-vpn "$QB_PRE; $QB_GET '$QB/torrents/info?limit=1'; rm -f \"\$C\"" | jq -r '.[0].hash // empty' 2>/dev/null)"
if [[ -n "$QB_HASH" ]]; then
  report qbittorrent-vpn "torrents/trackers (why it's dead)" \
    "$(ssh_curl qbittorrent-vpn "$QB_PRE; $QB_GET '$QB/torrents/trackers?hash=$QB_HASH'; rm -f \"\$C\"")" \
    '[.[] | {url: (.url | .[0:48]), status, msg, num_seeds, num_peers}]'
  report qbittorrent-vpn "torrents/files (per-episode in pack)" \
    "$(ssh_curl qbittorrent-vpn "$QB_PRE; $QB_GET '$QB/torrents/files?hash=$QB_HASH'; rm -f \"\$C\"")" \
    '{files: length, sample: [limit(4; .[] | {name: (.name | split("/") | last), progress, priority})]}'
else
  printf '  %-34s \033[33mSKIP (no torrents present)\033[0m\n' "torrents/trackers + files"; SKIP=$((SKIP + 2))
fi

# ----------------------------------------------------------------- gluetun --
# Control API is enabled in our compose (HTTP_CONTROL_SERVER_ADDRESS ":8000")
# but published to 127.0.0.1 only, so it is reachable from the host and NOT the
# LAN. It also requires auth — our own compose comment notes a plain healthcheck
# against it 401s. A 401 here is a FINDING (credential must be located before
# any VPN panel can be built), not a script bug.
hr qbittorrent-vpn
printf '  (gluetun control API on 127.0.0.1:8000)\n'
GL='curl -sS --max-time 15 http://127.0.0.1:8000/v1'

for ep in "vpn/status:tunnel up?" "portforward:forwarded port" "publicip/ip:egress IP (leak check)"; do
  path="${ep%%:*}"; label="${ep#*:}"
  body="$(ssh_curl qbittorrent-vpn "$GL/$path")"
  if printf '%s' "$body" | grep -qi 'unauthor\|401'; then
    printf '  %-34s \033[33m401 — auth required (finding)\033[0m\n' "gluetun $label"
    SKIP=$((SKIP + 1))
    NOTES+=("gluetun control API needs a credential we do not have in the repo — find what port-sync.sh uses.")
  else
    report qbittorrent-vpn "gluetun $label" "$body" '.'
  fi
done
NOTES+=("compare gluetun 'portforward' against qBit 'listen_port' — a mismatch means port-sync is dead and everything will stall.")

# ------------------------------------------------------------------ summary --
printf '\n\033[1m── summary\033[0m\n  %d answered · %d did not · %d skipped\n' "$PASS" "$FAIL" "$SKIP"
for n in "${NOTES[@]}"; do printf '  note: %s\n' "$n"; done
printf '\nA "NO" here is a finding, not necessarily a bug: it means that capability\ncannot be assumed by anything built on top. Record it in the doc.\n'
[[ -n "$OUTDIR" ]] && printf 'Raw responses: %s\n' "$OUTDIR"
exit 0
