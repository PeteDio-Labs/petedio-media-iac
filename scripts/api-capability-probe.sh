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
#   ./scripts/api-capability-probe.sh -l           # ALSO log in to qBittorrent
#
# -l is opt-in on purpose. qBittorrent bans the source IP for an hour after 5 failed
# logins, and a banned IP is refused even on the paths that need no login at all — so
# a probe that logs in speculatively can lock you out of the thing it is measuring.
# Reads go over qBittorrent's subnet whitelist by default; use -l only to test the
# credential itself.
#
# Requires: ssh, jq (locally — the LXCs are not assumed to have it).
#
# Kept compatible with bash 3.2, which is what /usr/bin/env bash resolves to on a
# stock macOS — so no associative arrays, no `${var,,}`, no `mapfile`. The Mac in
# the usage line above is exactly where this runs, so "it works under bash 5"
# is not the bar.
set -uo pipefail

VERBOSE=0
OUTDIR=""
QB_LOGIN=0
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_ansible}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)

while getopts "vlo:k:h" opt; do
  case "$opt" in
    v) VERBOSE=1 ;;
    l) QB_LOGIN=1 ;;
    o) OUTDIR="$OPTARG" ;;
    k) SSH_KEY="$OPTARG" ;;
    h) sed -n '2,36p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }
[[ -n "$OUTDIR" ]] && mkdir -p "$OUTDIR"

# host -> ip. Mirrors ansible/inventory/hosts.yml. These legacy IPs are permanent,
# not interim: the renumber to the 21x block (PET-49) was CANCELED, not deferred.
#
# `case` rather than the obvious `declare -A` because associative arrays are bash 4+
# and macOS ships 3.2. Under `set -u` the failed declare doesn't even error usefully —
# bash 3.2 reads `[sonarr]=8989` as an arithmetic subscript and dies with
# "sonarr: unbound variable", on the machine the usage block tells you to run this from.
ip_for() {
  case "$1" in
    lidarr)          echo 192.168.50.14  ;;
    seerr)           echo 192.168.50.33  ;;
    plex)            echo 192.168.50.140 ;;
    sonarr)          echo 192.168.50.15  ;;
    radarr)          echo 192.168.50.16  ;;
    prowlarr)        echo 192.168.50.20  ;;
    qbittorrent-vpn) echo 192.168.50.21  ;;
    *)               return 1 ;;
  esac
}
# *arr: port + API version. Lidarr/Prowlarr never moved off v1.
arr_port() { case "$1" in sonarr) echo 8989 ;; radarr) echo 7878 ;; lidarr) echo 8686 ;; prowlarr) echo 9696 ;; esac; }
arr_ver()  { case "$1" in sonarr|radarr) echo v3 ;; lidarr|prowlarr) echo v1 ;; esac; }

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
  ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "root@$(ip_for "$host")" "$snippet" 2>/dev/null
}

hr() { printf '\n\033[1m── %s\033[0m (%s)\n' "$1" "$(ip_for "$1" || echo '?')"; }

# ---------------------------------------------------------------- the *arrs --
# config.xml holds the key and the port; read both on the host, same as the
# Ansible role does, rather than pinning them here.
probe_arr() {
  local host="$1" port ver
  port="$(arr_port "$1")"
  ver="$(arr_ver "$1")"
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
# Prefer jq if the host happens to have it, else fall back to sed — but branch on the
# VALUE, not jq's exit code. `jq ... || sed ...` only falls back when jq fails to run;
# a jq that exists but finds nothing at .main.apiKey exits 0 with empty output, and the
# fallback never fires, leaving every seerr probe silently unauthenticated.
SEERR_PRE='K=$(jq -r ".main.apiKey // empty" /opt/seerr/config/settings.json 2>/dev/null); \
  [ -n "$K" ] || K=$(sed -n "s/.*\"apiKey\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    /opt/seerr/config/settings.json | head -1)'
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
# Auth here is NOT simply "cookie auth", and getting that wrong is expensive.
#
# LXC 110 runs with WebUI\AuthSubnetWhitelistEnabled=true covering 127.0.0.1/32 and
# 192.168.50.0/24, so a loopback GET is already authenticated and needs no session at
# all. Logging in anyway is not free: qBittorrent bans the SOURCE IP for an hour after
# WebUI\MaxAuthenticationFailCount (default 5) failed attempts, and a banned IP is
# refused even on the whitelist path. The first version of this script logged in once
# PER PROBE with the password from .env; when that password did not match, six probes
# burned through the counter and banned 127.0.0.1 — locking out the very access the
# whitelist grants. A "strictly read-only" probe that can lock you out of a live
# service is not read-only.
#
# So this probe does NOT log in by default. It reads over the whitelist and, if that is
# refused, says so and stops — rather than reaching for a credential that might be wrong.
# `-l` opts back in when you actually want to test the login path.
#
# Auto-retrying was tried and is a trap: a banned host answers "Forbidden", not "banned"
# (the ban wording only comes back from /auth/login), so "fall back to a login unless
# already banned" cannot tell a first failure from a hundredth, and every run quietly
# refreshes the ban it is trying to avoid. There is no safe way to probe your way out of
# this; the only safe move is not to knock.
hr qbittorrent-vpn
if [[ "$QB_LOGIN" == 1 ]]; then
  QB_PRE='C=$(mktemp); \
    P=$(sed -n "s/^QBIT_WEBUI_PASSWORD=//p" /opt/qbittorrent-vpn/.env | tr -d "\r"); \
    curl -sS --max-time 20 -c "$C" -H "Referer: http://localhost:8080" \
      --data-urlencode "username=admin" --data-urlencode "password=$P" \
      http://localhost:8080/api/v2/auth/login >/dev/null 2>&1'
else
  QB_PRE='C=$(mktemp)'
fi
QB_GET='curl -sS --max-time 20 -b "$C" -H "Referer: http://localhost:8080"'

QB='http://localhost:8080/api/v2'

# Auth canary, before anything else. If this host is banned or the whitelist is off,
# EVERY probe below returns "Forbidden" and the report reads as five unrelated missing
# capabilities. Diagnose it once, here, so the rest of the section is interpretable.
# (Doubles as the app/version probe further down — one call, not two.)
QB_AUTH="$(ssh_curl qbittorrent-vpn "$QB_PRE; $QB_GET $QB/app/version; rm -f \"\$C\"")"
case "$QB_AUTH" in
  v[0-9]*) : ;;
  *banned*)
    printf '  %-34s \033[31mIP BANNED\033[0m — %s\n' "qbittorrent auth" "$QB_AUTH"
    NOTES+=("qBittorrent has banned this source IP (WebUI\\MaxAuthenticationFailCount, ~1h). Every qBit probe below reads Forbidden because of that, not because the capability is missing. Check QBIT_WEBUI_PASSWORD in /opt/qbittorrent-vpn/.env still matches the WebUI password.")
    ;;
  *)
    printf '  %-34s \033[31mFORBIDDEN / no answer\033[0m\n' "qbittorrent auth"
    NOTES+=("qBittorrent refused an unauthenticated loopback GET, so every qBit probe below is blocked by AUTH, not by a missing capability. Either the subnet whitelist is off or this IP is still banned — and the two are indistinguishable from here, because a banned host answers 'Forbidden' too. Wait out the ban (1h from the last failed login) before concluding the whitelist does not work. Re-run with -l to test the .env credential itself, knowing that a wrong one re-arms the ban.")
    ;;
esac

report qbittorrent-vpn "torrents/info (hash join key)" \
  "$(ssh_curl qbittorrent-vpn "$QB_PRE; $QB_GET '$QB/torrents/info?limit=5'; rm -f \"\$C\"")" \
  '{torrents: length, sample: (.[0] // {} | {hash, name, state, progress, dlspeed, eta, num_seeds, num_complete, category, tags, save_path})}'

report qbittorrent-vpn "transfer/info (tunnel throughput)" \
  "$(ssh_curl qbittorrent-vpn "$QB_PRE; $QB_GET $QB/transfer/info; rm -f \"\$C\"")" \
  '{dl_info_speed, up_info_speed, connection_status}'

# Version decides the action-endpoint naming: qBittorrent 5.0 renamed
# /torrents/pause -> /torrents/stop and /torrents/resume -> /torrents/start.
# Anything written for Phase 2 must branch on this.
#   /app/version answers a bare string ("v5.0.4"), not JSON, so it has to be wrapped to get
#   past report()'s json check — but check the SHAPE before wrapping. `jq -R .` turns any
#   input into valid JSON, so piping an error body straight into it makes report() print a
#   green YES for the string "Forbidden". That is exactly what happened on the first live
#   run: the auth was broken, four sibling probes correctly said NO, and this one claimed
#   success. Wrapping must never be able to manufacture a pass.
#   (Wrapped here on the Mac, too — the header does not assume the LXCs have jq.)
case "$QB_AUTH" in
  v[0-9]*)
    report qbittorrent-vpn "app/version (5.x = stop/start API)" \
      "$(printf '%s' "$QB_AUTH" | jq -R .)" '.'
    ;;
  *)
    printf '  %-34s \033[31mNO / NOT A VERSION\033[0m\n' "app/version (5.x = stop/start API)"
    FAIL=$((FAIL + 1))
    ;;
esac

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
# Its own header — gluetun shares LXC 110 with qBittorrent, but printing `hr
# qbittorrent-vpn` twice reads as if the first block ended and restarted.
printf '\n\033[1m── gluetun\033[0m (%s · control API on 127.0.0.1:8000)\n' "$(ip_for qbittorrent-vpn)"
GL='curl -sS --max-time 15 http://127.0.0.1:8000/v1'

for ep in "vpn/status:tunnel up?" "portforward:forwarded port" "publicip/ip:egress IP (leak check)"; do
  path="${ep%%:*}"; label="${ep#*:}"
  body="$(ssh_curl qbittorrent-vpn "$GL/$path")"
  if printf '%s' "$body" | grep -qi 'unauthor\|401'; then
    printf '  %-34s \033[33m401 — auth required (finding)\033[0m\n' "gluetun $label"
    SKIP=$((SKIP + 1))
    NOTES+=("gluetun /v1/$path needs a credential the repo does not hold — find what port-sync.sh uses. NB: gluetun auth is PER-ROUTE, not global: /v1/portforward and /v1/publicip/ip answer unauthenticated on 110, so the port-vs-listen_port comparison does NOT depend on solving this.")
  else
    report qbittorrent-vpn "gluetun $label" "$body" '.'
  fi
done
NOTES+=("compare gluetun 'portforward' against qBit 'listen_port' — a mismatch means port-sync is dead and everything will stall.")

# ------------------------------------------------------------------ summary --
printf '\n\033[1m── summary\033[0m\n  %d answered · %d did not · %d skipped\n' "$PASS" "$FAIL" "$SKIP"
# ${NOTES[@]+"${NOTES[@]}"} — under `set -u`, bash 3.2 treats an empty array's "${a[@]}"
# as unbound and aborts the summary. NOTES is always populated today; this keeps the
# summary from being the thing that breaks if that stops being true.
for n in ${NOTES[@]+"${NOTES[@]}"}; do printf '  note: %s\n' "$n"; done
printf '\nA "NO" here is a finding, not necessarily a bug: it means that capability\ncannot be assumed by anything built on top. Record it in the doc.\n'
[[ -n "$OUTDIR" ]] && printf 'Raw responses: %s\n' "$OUTDIR"
exit 0
