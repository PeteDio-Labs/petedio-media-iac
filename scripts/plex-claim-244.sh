#!/usr/bin/env bash
# plex-claim-244.sh — claim plex-remote 244 to the same Plex account as plex-gpu
# 236 (MED-11). PEDRO RUNS THIS. It handles a credential, so no agent runs it.
#
# HOW. 236 is claimed, so its Preferences.xml holds the account's token. On 236,
# the script asks plex.tv for a claim token with that token, then pipes the claim
# token straight into 244, where Plex redeems it on 127.0.0.1. The account token
# never leaves 236. The claim token lives about four minutes, crosses the Mac only
# inside the pipe, and is never printed or stored.
#
# FALLBACK. With --manual, or if 236 cannot mint one, it asks for a claim token
# from https://www.plex.tv/claim with a hidden prompt.
#
# SAFE: if 244 already reports claimed, it changes nothing.
#
#   236  : $PLEX_GPU_HOST (default 192.168.86.236), key $ANSIBLE_SSH_KEY
#   244  : through pve03 $PVE_HOST (default 192.168.50.10), key $PVE_SSH_KEY
#
# Bash 3.2-compatible: it runs on the Mac.
set -euo pipefail

PLEX_GPU_HOST="${PLEX_GPU_HOST:-192.168.86.236}"
ANSIBLE_SSH_KEY="${ANSIBLE_SSH_KEY:-$HOME/.ssh/id_ed25519_ansible}"
PVE_HOST="${PVE_HOST:-192.168.50.10}"
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"
VMID="${VMID:-244}"
MANUAL=0
[ "${1:-}" = "--manual" ] && MANUAL=1

step() { printf '\n== %s ==\n' "$*"; }
die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

on_236() { ssh -o ConnectTimeout=10 -o BatchMode=yes -i "$ANSIBLE_SSH_KEY" "root@${PLEX_GPU_HOST}" "$@"; }
on_pve() { ssh -o ConnectTimeout=10 -o BatchMode=yes -i "$PVE_SSH_KEY" "root@${PVE_HOST}" "$@"; }

claimed_244() {
  on_pve "pct exec ${VMID} -- curl -fsS http://127.0.0.1:32400/identity" | grep -o 'claimed="[01]"' || true
}

# Reads a claim token on stdin, redeems it inside 244, and prints the HTTP code.
# The token goes in the query string because that is the endpoint's contract;
# the request never leaves the container.
# shellcheck disable=SC2016  # expands inside 244, not here
REDEEM='read -r t; [ -n "$t" ] || exit 3; curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:32400/myplex/claim?token=$t"'

step "Preflight"
[ -f "$PVE_SSH_KEY" ] || die "Proxmox SSH key not found: $PVE_SSH_KEY"
state="$(claimed_244)"
[ -n "$state" ] || die "Plex on ${VMID} does not answer on 127.0.0.1:32400. Run playbooks/bootstrap-plex-remote.yml first."
if [ "$state" = 'claimed="1"' ]; then
  step "244 is already claimed, nothing to do"
  exit 0
fi
printf '  244 answers and is unclaimed\n'

code=""
if [ "$MANUAL" -eq 0 ]; then
  step "Minting a claim token on 236 and redeeming it on 244"
  [ -f "$ANSIBLE_SSH_KEY" ] || die "Ansible SSH key not found: $ANSIBLE_SSH_KEY"
  # Runs on 236. Prints only the claim token, or nothing.
  # shellcheck disable=SC2016  # expands on 236, not here
  MINT='P="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"
T="$(grep -o "PlexOnlineToken=\"[^\"]*\"" "$P" | cut -d\" -f2)"
[ -n "$T" ] || exit 4
curl -fsS -H "X-Plex-Token: $T" -H "Accept: application/json" https://plex.tv/api/claim/token.json \
  | sed -n "s/.*\"token\":\"\(claim-[^\"]*\)\".*/\1/p"'
  code="$(on_236 "$MINT" | on_pve "pct exec ${VMID} -- sh -c '$REDEEM'")" || code=""
  [ -n "$code" ] || printf '  236 could not mint a claim token; falling back to the manual path\n'
fi

if [ -z "$code" ]; then
  step "Manual claim"
  printf '  Open https://www.plex.tv/claim signed in as the server owner, copy the token,\n'
  printf '  and paste it here within four minutes. It is not echoed.\n'
  printf '  Claim token: '
  IFS= read -rs claim
  printf '\n'
  case "$claim" in claim-*) ;; *) die "that does not look like a claim token (claim-...)" ;; esac
  code="$(printf '%s\n' "$claim" | on_pve "pct exec ${VMID} -- sh -c '$REDEEM'")"
  claim=""
fi

[ "$code" = "200" ] || die "244 answered HTTP ${code} to the claim. A claim token lasts about four minutes; run it again."

step "Verifying"
tries=0
until [ "$(claimed_244)" = 'claimed="1"' ]; do
  tries=$((tries + 1))
  [ "$tries" -lt 10 ] || die "244 accepted the claim but does not report claimed=\"1\""
  sleep 3
done
printf '  244 reports claimed="1"\n'

step "Done"
printf 'Next, from media-iac/ansible:\n'
printf '  ansible-playbook playbooks/bootstrap-plex-remote.yml\n'
printf '  ansible-playbook playbooks/configure-plex-remote.yml\n'
