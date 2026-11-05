#!/usr/bin/env bash
# lxc-mounts-222.sh — add the media bind mount and the container features to
# bazarr (222) out-of-band, on pve03, over SSH-as-root. (PET-852)
#
# WHY THIS ISN'T TERRAFORM:
#   Proxmox enforces a hardcoded `user == root@pam` check for bind mount points. An
#   API token's username is `root@pam!tokenid`, so a Terraform create that carries a
#   mount_point block fails with:
#
#     Permission check failed (mount point type bind is only allowed for root@pam)
#
#   Terraform creates 222 bare. This script adds the mount. modules/proxmox-lxc keeps
#   mount_point in ignore_changes, so no later apply strips it. lxc-oob-236.sh
#   explains the same split for plex-gpu.
#
# WHAT IT SETS:
#
#     mp0:      /mnt/media -> /mnt/media   read-write, shared=1
#     features: nesting=1
#
#   shared=1 tells Proxmox the path exists on every node, which lets the guest
#   migrate. That is true: both nodes have /mnt/media (pve02 holds the ZFS pool and
#   pve03 mounts it over NFS). The target path matches sonarr and radarr, so Bazarr
#   sees the same file paths they report and needs no path mapping.
#
#   There is no /downloads mount. Bazarr never reads a download.
#
#   nesting=1 matches the other Debian 13 guests. Without it the generated AppArmor
#   profile denies mounts and a sandboxed unit cannot start. petedio-iac's
#   roles/lxc-features declares the same value for 222 and converges it; this script
#   sets it first so the first start is already correct.
#
# SAFE: touches ONLY container 222. Idempotent: when both settings are present it
# changes nothing and does not restart. A mount point can only be added while the
# container is stopped, so it stops and restarts 222 when a change is needed.
#
# ORDER: run it after the apply-on-merge creates 222 and before
# `ansible-playbook playbooks/media-roles.yml --limit bazarr`. The role asserts that
# /mnt/media is mounted and non-empty in the guest.
#
#   pve host: $PVE_HOST      (default 192.168.50.10 = pve03, where 222 lives)
#   pve key : $PVE_SSH_KEY   (default ~/.ssh/id_ed25519_proxmox_pedro, the bare-metal root key)
# The node and the LXC use different keys. This script talks to the node.
#
# Bash 3.2-compatible: it runs on the Mac.
set -euo pipefail

PVE_HOST="${PVE_HOST:-192.168.50.10}"
PVE_SSH_USER="${PVE_SSH_USER:-root}"
VMID="${VMID:-222}"
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"

MP0="/mnt/media,mp=/mnt/media,shared=1"
FEATURES="nesting=1"

step() { printf '\n== %s ==\n' "$*"; }
die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

command -v ssh >/dev/null 2>&1 || die "ssh not in PATH"
[ -f "$PVE_SSH_KEY" ] || die "Proxmox SSH key not found: $PVE_SSH_KEY"

pve() {
  ssh -o ConnectTimeout=10 -o BatchMode=yes -i "$PVE_SSH_KEY" "${PVE_SSH_USER}@${PVE_HOST}" "$@"
}

step "Preflight on ${PVE_HOST}"
pve "pct config ${VMID} >/dev/null 2>&1" || die "container ${VMID} not found on ${PVE_HOST}. Did the apply-on-merge run?"

# The host path must be a real mount, not an empty directory. Bind-mounting an
# unmounted path ships an empty library into the guest, and every check downstream
# still passes.
pve "mountpoint -q /mnt/media" || die "/mnt/media is not mounted on ${PVE_HOST}. Fix the NFS mount before adding the bind."
printf '  /mnt/media is mounted on %s\n' "$PVE_HOST"

CURRENT="$(pve "pct config ${VMID} | grep -E '^(mp[0-9]|features):' || true")"
if printf '%s\n' "$CURRENT" | grep -qxF "mp0: ${MP0}" \
  && printf '%s\n' "$CURRENT" | grep -qxF "features: ${FEATURES}"; then
  step "Already set, nothing to do"
  printf '%s\n' "$CURRENT"
  exit 0
fi

step "Stopping ${VMID} (a mount point can only be added while stopped)"
pve "pct status ${VMID} | grep -q running && pct stop ${VMID} || true"

step "Adding the bind mount and the features"
pve "pct set ${VMID} -mp0 '${MP0}' -features '${FEATURES}'"

step "Starting ${VMID}"
pve "pct start ${VMID}"

step "Verifying"
pve "pct config ${VMID} | grep -E '^(mp[0-9]|features):'"
# `pct exec` can answer before the guest finishes booting. Retry for up to 30 s.
tries=0
until pve "pct exec ${VMID} -- mountpoint -q /mnt/media"; do
  tries=$((tries + 1))
  [ "$tries" -lt 10 ] || die "/mnt/media is not a mount point inside ${VMID}"
  sleep 3
done
entries="$(pve "pct exec ${VMID} -- sh -c 'ls /mnt/media | wc -l'" | tr -d '[:space:]')"
[ "${entries:-0}" -gt 0 ] || die "/mnt/media is mounted in ${VMID} but empty"
printf '  /mnt/media OK in the guest: %s entries\n' "$entries"

step "Done"
