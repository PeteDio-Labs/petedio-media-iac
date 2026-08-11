#!/usr/bin/env bash
# Emit "<service> <image> <local-digest> <remote-digest>" for every service in
# the compose stack, so Ansible can decide which are behind AND pull only those.
#
# These services all track floating tags (:latest, alpine:3.20), so a version
# string tells you nothing — the only honest "is there an update" signal is
# comparing the digest we have against the digest the registry serves today.
#
# WHICH digest matters. `docker image inspect .RepoDigests` records the digest
# of what was pulled, which for a multi-arch tag is the **manifest LIST**
# digest. `docker manifest inspect -v` returns one entry PER PLATFORM, so its
# Descriptor.digest is a per-platform manifest digest — a structurally different
# value that can never equal RepoDigests. Comparing those two (the obvious
# thing to reach for) reports every multi-arch image as permanently "behind".
# So the remote side is fetched as the registry's own Docker-Content-Digest for
# the tag, which is exactly what RepoDigests holds.
#
# The service name matters as much as the image: `docker compose pull` with no
# arguments pulls the WHOLE stack, so one rate-limited image (docker.io caps
# anonymous pulls) aborts the update even when the image that actually needs
# updating lives on an unthrottled registry. Pulling per-service avoids that.
#
# Prints "none"/"unknown" rather than failing when a digest can't be resolved
# (image built locally, registry unreachable, HTTP 429); the caller treats those
# as "don't touch it" instead of "up to date".
set -uo pipefail

cd "${1:-/opt/qbittorrent-vpn}" || exit 1

# Ask the registry for the digest it currently serves for <repo>:<tag>, via the
# standard anonymous token flow. Accept BOTH index media types so the registry
# returns the manifest list rather than resolving to a single platform.
remote_digest() {
  local ref="$1" registry repo tag hostpart path token realm service www

  # Split "[registry/]repo[:tag]" the way Docker does.
  tag="latest"
  hostpart="${ref%%/*}"
  if [[ "$ref" == *"/"* && ( "$hostpart" == *"."* || "$hostpart" == *":"* || "$hostpart" == "localhost" ) ]]; then
    registry="$hostpart"; path="${ref#*/}"
  else
    registry="registry-1.docker.io"; path="$ref"
    [[ "$path" == *"/"* ]] || path="library/$path"
  fi
  [[ "$path" == *":"* ]] && { tag="${path##*:}"; repo="${path%:*}"; } || repo="$path"

  # Discover the auth realm, then take an anonymous pull token for this repo.
  www=$(curl -sI -m 15 "https://${registry}/v2/" 2>/dev/null \
        | tr -d '\r' | grep -i '^www-authenticate:' || true)
  realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<< "$www")
  service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<< "$www")

  token=""
  if [ -n "$realm" ]; then
    token=$(curl -s -m 20 --get "$realm" \
              --data-urlencode "service=${service}" \
              --data-urlencode "scope=repository:${repo}:pull" 2>/dev/null \
            | python3 -c 'import json,sys
d = json.load(sys.stdin)
print(d.get("token") or d.get("access_token") or "")' 2>/dev/null) || token=""
  fi

  curl -sI -m 20 \
    ${token:+-H "Authorization: Bearer ${token}"} \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "https://${registry}/v2/${repo}/manifests/${tag}" 2>/dev/null \
  | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest:[[:space:]]*//p' | tail -1
}

mapping=$(docker compose config --format json 2>/dev/null |
  python3 -c 'import json,sys
d = json.load(sys.stdin)
for name, svc in (d.get("services") or {}).items():
    img = svc.get("image")
    if img:
        print(f"{name}\t{img}")') || exit 1

while IFS=$'\t' read -r svc img; do
  [ -n "${svc:-}" ] || continue

  local_d=$(docker image inspect "$img" 2>/dev/null |
    python3 -c 'import json,sys
d = json.load(sys.stdin)
rd = d[0].get("RepoDigests") or []
print(rd[0].split("@")[1] if rd else "none")' 2>/dev/null) || local_d=""

  remote_d=$(remote_digest "$img") || remote_d=""

  printf "%s %s %s %s\n" "$svc" "$img" "${local_d:-none}" "${remote_d:-unknown}"
done <<< "$mapping"
