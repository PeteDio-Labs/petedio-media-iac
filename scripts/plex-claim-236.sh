#!/usr/bin/env bash
# plex-claim-236.sh — claim plex-gpu 236 as a NEW server on the same Plex account
# (MED-11). PEDRO RUNS THIS. It handles a credential, so no agent runs it.
#
# WHEN. After playbooks/migrate-plex-identity.yml moved 236's identity to 244 and
# playbooks/reset-plex-gpu.yml started 236 on a clean data directory. 236 then
# answers unclaimed, with a new machine id.
#
# HOW. 244 holds the moved identity, so its Preferences.xml holds the account's
# token. Inside 244 the script asks plex.tv for a claim token with that token,
# then pipes the claim token straight into 236, where Plex redeems it on
# 127.0.0.1. The account token never leaves 244. The claim token lives about four
# minutes, crosses the Mac only inside the pipe, and is never printed or stored.
#
# FALLBACK. With --manual, or if 244 cannot mint one, it asks for a claim token
# from https://www.plex.tv/claim with a hidden prompt.
#
# SAFE: it refuses unless 236 answers unclaimed with an identity that differs
# from 244's, and changes nothing if 236 already reports claimed.
#
#   244 : through pve03 $PVE03_HOST (default 192.168.50.10)
#   236 : through pve02 $PVE02_HOST (default 192.168.50.11)
#   key : $PVE_SSH_KEY for both nodes
#
# Bash 3.2-compatible: it runs on the Mac.
set -euo pipefail

PVE03_HOST="${PVE03_HOST:-192.168.50.10}"
PVE02_HOST="${PVE02_HOST:-192.168.50.11}"
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"
SRC_VMID="${SRC_VMID:-244}"
DEST_VMID="${DEST_VMID:-236}"
MANUAL=0
[ "${1:-}" = "--manual" ] && MANUAL=1

step() { printf '\n== %s ==\n' "$*"; }
die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

on_244() { ssh -o ConnectTimeout=10 -o BatchMode=yes -i "$PVE_SSH_KEY" "root@${PVE03_HOST}" "pct exec ${SRC_VMID} -- $*"; }
on_236() { ssh -o ConnectTimeout=10 -o BatchMode=yes -i "$PVE_SSH_KEY" "root@${PVE02_HOST}" "pct exec ${DEST_VMID} -- $*"; }

identity() { "$1" curl -fsS http://127.0.0.1:32400/identity 2>/dev/null || true; }
field() { printf '%s' "$2" | grep -o "$1=\"[^\"]*\"" | cut -d\" -f2 || true; }

# Reads a claim token on stdin, redeems it inside 236, and prints the HTTP code.
# The token goes in the query string because that is the endpoint's contract;
# the request never leaves the container. It reaches curl as a config line on stdin, so
# no process argument list holds it.
# shellcheck disable=SC2016  # expands inside 236, not here
REDEEM='read -r t; [ -n "$t" ] || exit 3; printf "url = \"http://127.0.0.1:32400/myplex/claim?token=%s\"\n" "$t" | curl -s -o /dev/null -w "%{http_code}" -X POST -K -'

step "Preflight"
[ -f "$PVE_SSH_KEY" ] || die "Proxmox SSH key not found: $PVE_SSH_KEY"
src="$(identity on_244)"
dest="$(identity on_236)"
[ -n "$dest" ] || die "Plex on ${DEST_VMID} does not answer on 127.0.0.1:32400. Run playbooks/reset-plex-gpu.yml first."
src_id="$(field machineIdentifier "$src")"
dest_id="$(field machineIdentifier "$dest")"
[ -n "$dest_id" ] || die "${DEST_VMID} answered without a machineIdentifier"
if [ -n "$src_id" ] && [ "$src_id" = "$dest_id" ]; then
  die "${DEST_VMID} and ${SRC_VMID} share one identity. Stop ${DEST_VMID} and run playbooks/reset-plex-gpu.yml."
fi
if [ "$(field claimed "$dest")" = "1" ]; then
  step "${DEST_VMID} is already claimed, nothing to do"
  exit 0
fi
printf '  %s answers, unclaimed, with its own identity\n' "$DEST_VMID"

code=""
if [ "$MANUAL" -eq 0 ] && [ "$(field claimed "$src")" = "1" ]; then
  step "Minting a claim token on ${SRC_VMID} and redeeming it on ${DEST_VMID}"
  # Runs inside 244. Prints only the claim token, or nothing.
  # shellcheck disable=SC2016  # expands inside 244, not here
  MINT='P="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"
T="$(grep -o "PlexOnlineToken=\"[^\"]*\"" "$P" | cut -d\" -f2)"
[ -n "$T" ] || exit 4
printf "header = \"X-Plex-Token: %s\"\n" "$T" \
  | curl -fsS -K - -H "Accept: application/json" https://plex.tv/api/claim/token.json \
  | sed -n "s/.*\"token\":\"\(claim-[^\"]*\)\".*/\1/p"'
  code="$(on_244 sh -c "$(printf '%q' "$MINT")" | on_236 sh -c "$(printf '%q' "$REDEEM")")" || code=""
  [ -n "$code" ] || printf '  %s could not mint a claim token; falling back to the manual path\n' "$SRC_VMID"
fi

if [ -z "$code" ]; then
  step "Manual claim"
  printf '  Open https://www.plex.tv/claim signed in as the server owner, copy the token,\n'
  printf '  and paste it here within four minutes. It is not echoed.\n'
  printf '  Claim token: '
  IFS= read -rs claim
  printf '\n'
  case "$claim" in claim-*) ;; *) die "that does not look like a claim token (claim-...)" ;; esac
  code="$(printf '%s\n' "$claim" | on_236 sh -c "$(printf '%q' "$REDEEM")")"
  claim=""
fi

[ "$code" = "200" ] || die "${DEST_VMID} answered HTTP ${code} to the claim. A claim token lasts about four minutes; run it again."

step "Verifying"
tries=0
until [ "$(field claimed "$(identity on_236)")" = "1" ]; do
  tries=$((tries + 1))
  [ "$tries" -lt 10 ] || die "${DEST_VMID} accepted the claim but does not report claimed=\"1\""
  sleep 3
done
printf '  %s reports claimed="1" as a new server\n' "$DEST_VMID"

step "Done"
printf 'Next, from media-iac/ansible:\n'
printf '  ansible-playbook -i inventory/hosts.yml playbooks/configure-plex-settings.yml --limit plex-gpu\n'
