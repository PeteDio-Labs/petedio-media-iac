#!/usr/bin/env bash
# Emit "<image> <local-digest> <remote-digest>" for every image in the compose
# stack, so Ansible can decide which are behind.
#
# These services all track floating tags (:latest, alpine:3.20), so a version
# string tells you nothing — the only honest "is there an update" signal is
# comparing the local RepoDigest against the registry's current manifest digest.
#
# Prints "none"/"unknown" rather than failing when a digest can't be resolved
# (image built locally, registry unreachable); the caller treats those as
# "don't touch it" instead of "update it".
set -uo pipefail

cd "${1:-/opt/qbittorrent-vpn}" || exit 1

for img in $(docker compose config --images); do
  local_d=$(docker image inspect "$img" 2>/dev/null |
    python3 -c 'import json,sys
d = json.load(sys.stdin)
rd = d[0].get("RepoDigests") or []
print(rd[0].split("@")[1] if rd else "none")' 2>/dev/null) || local_d=""

  remote_d=$(docker manifest inspect -v "$img" 2>/dev/null |
    python3 -c 'import json,sys
d = json.load(sys.stdin)
d = d[0] if isinstance(d, list) else d
print(d["Descriptor"]["digest"])' 2>/dev/null) || remote_d=""

  printf "%s %s %s\n" "$img" "${local_d:-none}" "${remote_d:-unknown}"
done
