#!/usr/bin/env bash
# lxc-oob-244.sh — apply the root@pam-gated settings to plex-remote (244)
# out-of-band, on pve03, over SSH-as-root: the read-only media bind mount, the
# Iris Xe render device, and the container features. (MED-11)
#
# WHY THIS ISN'T TERRAFORM: Proxmox allows bind mounts and device passthrough
# only for `root@pam`, and the provider holds an API token. lxc-oob-236.sh has
# the full account. Terraform creates 244 bare; this script adds the rest, and
# modules/proxmox-lxc keeps both fields in ignore_changes.
#
# WHAT IT SETS:
#
#     mp0:      /mnt/media -> /mnt/media   read-only, shared=1
#     dev0:     /dev/dri/renderD129, gid=44, mode=0660
#     features: nesting=1
#
# The bind is READ-ONLY: this server only serves the library. Sonarr and Radarr
# write it, and plex-gpu 236 owns any edit Plex makes. shared=1 matches bazarr
# 222, because /mnt/media exists on both nodes.
#
# ⚠ renderD129, NOT renderD128. On pve03 renderD128 is the RTX 3050 on nouveau,
# which has no usable hardware encode. The script resolves the Iris Xe node from
# its PCI path and refuses to run if that is not renderD129.
#
# gid 44 is `video` inside the container, the group the Plex package puts its
# service user in, as on 236.
#
# SAFE: touches ONLY container 244. Idempotent: when every setting is present it
# changes nothing and does not restart. A mount point can only be added while the
# container is stopped, so it stops and restarts 244 when a change is needed.
#
# ORDER: run it after the apply-on-merge creates 244 and before
# `ansible-playbook playbooks/bootstrap-plex-remote.yml`. The play asserts the
# library and the render node inside the guest.
#
#   pve host: $PVE_HOST      (default 192.168.50.10 = pve03, where 244 lives)
#   pve key : $PVE_SSH_KEY   (default ~/.ssh/id_ed25519_proxmox_pedro)
#
# Bash 3.2-compatible: it runs on the Mac.
set -euo pipefail

PVE_HOST="${PVE_HOST:-192.168.50.10}"
PVE_SSH_USER="${PVE_SSH_USER:-root}"
VMID="${VMID:-244}"
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_pedro}"

IGPU_PCI_PATH="pci-0000:00:02.0-render"
RENDER_NODE="/dev/dri/renderD129"
MP0="/mnt/media,mp=/mnt/media,ro=1,shared=1"
DEV0="${RENDER_NODE},gid=44,mode=0660"
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

# An unmounted host path ships an empty library into the guest, and every check
# downstream still passes.
pve "mountpoint -q /mnt/media" || die "/mnt/media is not mounted on ${PVE_HOST}. Fix the NFS mount before adding the bind."
printf '  /mnt/media is mounted on %s\n' "$PVE_HOST"

# Prove the node is the Iris Xe before passing it in. Passing the wrong GPU
# yields a server that transcodes in software and reports no error.
resolved="$(pve "readlink -f /dev/dri/by-path/${IGPU_PCI_PATH}" || true)"
[ "$resolved" = "$RENDER_NODE" ] || die "/dev/dri/by-path/${IGPU_PCI_PATH} resolves to '${resolved}', not ${RENDER_NODE}. Update RENDER_NODE after checking lspci."
printf '  Iris Xe render node is %s\n' "$RENDER_NODE"

CURRENT="$(pve "pct config ${VMID} | grep -E '^((mp|dev)[0-9]|features):' || true")"
FEATURE_LINE="$(printf '%s\n' "$CURRENT" | sed -n 's/^features: //p')"
if printf '%s\n' "$CURRENT" | grep -qxF "mp0: ${MP0}" \
  && printf '%s\n' "$CURRENT" | grep -qxF "dev0: ${DEV0}" \
  && case ",${FEATURE_LINE}," in *,"${FEATURES}",*) true ;; *) false ;; esac; then
  step "Already set, nothing to do"
  printf '%s\n' "$CURRENT"
  exit 0
fi

step "Stopping ${VMID} (a mount point can only be added while stopped)"
pve "pct status ${VMID} | grep -q running && pct stop ${VMID} || true"

step "Adding the bind mount, the render device and the features"
pve "pct set ${VMID} -mp0 '${MP0}' -dev0 '${DEV0}' -features '${FEATURES}'"

step "Starting ${VMID}"
pve "pct start ${VMID}"

step "Verifying from inside the container"
pve "pct config ${VMID} | grep -E '^((mp|dev)[0-9]|features):'"
tries=0
until pve "pct exec ${VMID} -- mountpoint -q /mnt/media"; do
  tries=$((tries + 1))
  [ "$tries" -lt 10 ] || die "/mnt/media is not a mount point inside ${VMID}"
  sleep 3
done
entries="$(pve "pct exec ${VMID} -- sh -c 'ls /mnt/media | wc -l'" | tr -d '[:space:]')"
[ "${entries:-0}" -gt 0 ] || die "/mnt/media is mounted in ${VMID} but empty"
printf '  /mnt/media OK in the guest: %s entries\n' "$entries"
# The read-only flag is the point of this mount, so prove it.
if pve "pct exec ${VMID} -- sh -c 'touch /mnt/media/.ro-probe 2>/dev/null'"; then
  pve "pct exec ${VMID} -- rm -f /mnt/media/.ro-probe" || true
  die "/mnt/media is WRITABLE inside ${VMID}; expected read-only"
fi
printf '  /mnt/media is read-only in the guest\n'
pve "pct exec ${VMID} -- test -e ${RENDER_NODE}" || die "${RENDER_NODE} is not present inside ${VMID}"
printf '  %s present in the guest\n' "$RENDER_NODE"

step "Done"
