#!/usr/bin/env bash
# lxc-oob-236.sh — apply every root@pam-gated setting to plex-gpu (236)
# out-of-band, on pve02, over SSH-as-root: the two media bind mounts, the Quick
# Sync render device, and the container features. (PET-311)
#
# WHY THIS ISN'T TERRAFORM:
#   Proxmox enforces a hardcoded `user == root@pam` check for BOTH bind mount
#   points and device passthrough. An API token's username is `root@pam!tokenid`,
#   not `root@pam`, so a Terraform create carrying either block fails:
#
#     Permission check failed (mount point type bind is only allowed for root@pam)
#     Permission check failed (configuring device passthrough is only allowed for root@pam)
#
#   Proxmox reports these ONE AT A TIME, so fixing only the block that errored
#   just moves the failure. Everything gated belongs here, in one run.
#
#   The other seven media LXCs declare mount_points and apply fine because they
#   were IMPORTED — Terraform adopted mounts that already existed and never had to
#   create one. 236 is the first container this repo creates from scratch, so it is
#   the first to hit the restriction. Terraform creates it bare; this adds the
#   mounts. modules/proxmox-lxc keeps mount_point in ignore_changes so no later
#   apply strips them. Same split as features/nesting — see petedio-iac
#   docs/GOTCHAS.md and its scripts/lxc-features-*.sh.
#
# WHAT IT SETS (mounts use identical paths to plex 103, which is what makes the
# library node-independent — /mnt/media is NFS from pve01 on this node):
#
#     mp0:      /mnt/media      -> /mnt/media       read-write
#     mp1:      /mnt/downloads  -> /mnt/downloads   read-only
#     dev0:     /dev/dri/renderD128, gid=44, mode=0660   (Quick Sync)
#     features: nesting=1
#
# nesting=1 matches plex 103, the server this one is modelled on. `pct start`
# warns for it directly on Debian 13 ("Systemd 257 detected. You may need to
# enable nesting"). NB: it does not clear the three mount units that fail in any
# unprivileged LXC (dev-mqueue, run-lock, tmp) — 103 runs `degraded` too, with
# nesting on. Degraded is the normal steady state here, not a fault to chase.
#
# gid 44 is `video` INSIDE the container, the group the Plex package already puts
# its service user in. On the pve02 host the node is root:render(993); the
# passthrough re-groups it on the way in.
#
# SAFE: touches ONLY container 236. Idempotent — if all three are already set it
# makes no change and does not restart. A mount point can only be added while the
# container is stopped, so it stops and restarts 236 if a change is needed. 236 is
# an unclaimed, freshly built Plex, so that costs nothing.
#
#   pve host: $PVE_HOST      (default 192.168.50.11 = pve02, where 236 lives)
#   pve key : $PVE_SSH_KEY   (default ~/.ssh/id_ed25519_proxmox_pedro — bare-metal root)
# NB: the Proxmox NODE and the LXC use DIFFERENT keys. The node is bare metal (the
# proxmox key); 236 is a TF-created LXC reached with id_ed25519_ansible. Don't conflate.
set -euo pipefail

PVE_HOST="${PVE_HOST:-192.168.50.11}"
PVE_SSH_USER="${PVE_SSH_USER:-root}"
VMID="${VMID:-236}"
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"

MP0="/mnt/media,mp=/mnt/media"
MP1="/mnt/downloads,mp=/mnt/downloads,ro=1"
DEV0="/dev/dri/renderD128,gid=44,mode=0660"
FEATURES="nesting=1"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

command -v ssh >/dev/null || die "ssh not in PATH"
[ -f "$PVE_SSH_KEY" ] || die "Proxmox SSH key not found: $PVE_SSH_KEY"

SSH=(ssh -o ConnectTimeout=10 -o BatchMode=yes -i "$PVE_SSH_KEY" "${PVE_SSH_USER}@${PVE_HOST}")

step "Preflight on ${PVE_HOST}"
"${SSH[@]}" "pct config ${VMID} >/dev/null 2>&1" || die "container ${VMID} not found on ${PVE_HOST}"

# The host paths must be real mounts, not empty directories. Bind-mounting an
# unmounted mount point ships an empty library into the guest, and every check
# downstream still passes — the same failure the media-share role guards against.
for p in /mnt/media /mnt/downloads; do
  "${SSH[@]}" "mountpoint -q $p" || die "$p is not mounted on ${PVE_HOST} — fix the NFS mount before adding the bind"
done
printf '  /mnt/media and /mnt/downloads are mounted on %s\n' "$PVE_HOST"

# The render node must exist on the host, or the passthrough silently yields a
# container that falls back to software transcoding.
"${SSH[@]}" "test -e /dev/dri/renderD128" || die "/dev/dri/renderD128 missing on ${PVE_HOST} — no Quick Sync to pass through"
printf '  /dev/dri/renderD128 present on %s\n' "$PVE_HOST"

CURRENT="$("${SSH[@]}" "pct config ${VMID} | grep -E '^((mp|dev)[0-9]|features):' || true")"
if printf '%s' "$CURRENT" | grep -q "mp0: ${MP0}" \
  && printf '%s' "$CURRENT" | grep -q "mp1: ${MP1}" \
  && printf '%s' "$CURRENT" | grep -q "dev0: ${DEV0}" \
  && printf '%s' "$CURRENT" | grep -q "features: ${FEATURES}"; then
  step "Already set — nothing to do"
  printf '%s\n' "$CURRENT"
  exit 0
fi

step "Stopping ${VMID} (a mount point can only be added while stopped)"
"${SSH[@]}" "pct status ${VMID} | grep -q running && pct stop ${VMID} || true"

step "Adding the bind mounts, the render device and the features"
"${SSH[@]}" "pct set ${VMID} -mp0 '${MP0}' -mp1 '${MP1}' -dev0 '${DEV0}' -features '${FEATURES}'"

step "Starting ${VMID}"
"${SSH[@]}" "pct start ${VMID}"

step "Verifying from inside the container"
"${SSH[@]}" "pct config ${VMID} | grep -E '^((mp|dev)[0-9]|features):'"
"${SSH[@]}" "pct exec ${VMID} -- sh -c 'mountpoint -q /mnt/media && echo \"  /mnt/media OK: \$(ls /mnt/media | wc -l) entries\" || { echo \"  /mnt/media NOT mounted in guest\"; exit 1; }'"
"${SSH[@]}" "pct exec ${VMID} -- sh -c 'test -e /dev/dri/renderD128 && echo \"  renderD128 OK: \$(ls -l /dev/dri/renderD128)\" || { echo \"  renderD128 NOT present in guest\"; exit 1; }'"

step "Done"
