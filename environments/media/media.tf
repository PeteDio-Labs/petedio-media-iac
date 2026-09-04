# ── Placement after the 2026-09-03 loss of pve01 ──────────────────────────────
#
# The library lives on pve02 as local ZFS: `media` (RAIDZ1, four USB SSDs) and
# `downloads` (one SSD). pve02 exports both to pve03 over NFS.
#
# WHO SITS WHERE, AND WHY
#
#   pve03   sonarr, radarr, prowlarr
#           The arr apps write imports as bulk sequential copies on a schedule,
#           which tolerates the network fine. Moving them means the library and
#           the applications that write to it no longer share a host.
#
#   pve02   plex-gpu, qbittorrent-vpn, seerr
#           Plex STAYS WITH THE DISKS. Playback is latency-sensitive and
#           read-heavy, and inotify does not cross NFS -- putting Plex on the
#           far side would cost filesystem-event scanning, which going local
#           just won back. qBittorrent stays for a different reason: it writes
#           torrent pieces in random order, which is the worst workload to put
#           over NFS.
#
# The tempting version of this split moves PLEX to pve03 for its Iris Xe Quick
# Sync. That puts the streaming path over NFS to gain transcode headroom the
# 1080p library does not need, and rebuilds the cross-node coupling that made
# pve02 collateral damage when pve01 died. Don't.
#
# ⚠ pve03 HAS NO LVM THIN POOL. It was installed as plain Debian on ext4, so its
# container store is the `local` directory, not `local-lvm`. A guest declared
# for pve03 with local-lvm fails at migration with "storage does not support CT
# rootdirs" -- after copying the disk.
#
# ⚠ MOUNT POINTS NEED shared=1 TO MIGRATE. Proxmox refuses to move a container
# with a local bind mount, because it cannot verify the host path exists on the
# target. Both nodes genuinely have /mnt/media and /mnt/downloads now, so the
# flag is true rather than a lie to get past the check.

# Media stack — brownfield capture (PET-46). One module block per RUNNING LXC,
# encoding each host's REAL shape (ground-truthed off pve01 via `pct config`,
# 2026-06-04) so `terraform import` + `plan` is a clean no-op (zero drift).
#
# NOT in this file: filebrowser (102) — old file/image store, excluded and
# flagged for decommission (PET-82).
#
# Per-host variances captured below:
#   - rootfs datastore: local-lvm (most) vs sdb3-storage (seerr/sonarr/radarr)
#   - mount target paths differ per container (/mnt/media vs /media, etc.)
#   - plex (103) is DUAL-HOMED: net0 vmbr0/.86 mesh + net1 vmbr1/.50 LAN
#   - seerr (101) has NO bind-mounts and its only NIC is eth1 (firewall on)
#   - qbittorrent-vpn (110) + plex + seerr have the Proxmox firewall enabled
#
# VMIDs are the LIVE legacy numbers (not the target 21x scheme — renumber is
# deferred, PET-49). Mount-point import behaviour for host-dir bind mounts is
# verified during the import iteration; adjust `mount_points` until plan no-ops.

locals {
  # /mnt/media + /mnt/downloads live on the Proxmox host and are bind-mounted
  # into each container at container-specific target paths.
  media_volume     = "/mnt/media"
  downloads_volume = "/mnt/downloads"
}

# seerr 101/.33 — sdb3-storage 12G, eth1-only (firewall on), NO bind-mounts
module "seerr" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 101
  hostname         = "seerr"
  ipv4_address     = "192.168.50.33/24"
  cores            = 4
  memory_dedicated = 4096
  disk_size        = 12
  datastore_id     = "local-lvm"
  firewall         = true
  interface_name   = "eth1" # seerr's only NIC is eth1 (not eth0)
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  description      = "Overseerr/Jellyseerr (requests). Media stack — managed by petedio-media-iac."
}

# plex 103 — REMOVED. The container died with pve01 on 2026-09-03 and does not
# exist on any node; Proxmox has already dropped 103 from the `homelab` pool.
#
# DO NOT RE-ADD IT BY UNCOMMENTING. Its declaration was written for pve01, where
# vmbr0 was the .86 mesh and vmbr1 was the .50 LAN. Those numbers are INVERTED on
# pve02, so recreating this block anywhere else puts the "mesh" address on the LAN
# bridge and the "LAN" address on a VXLAN. plex-gpu below carries the warning in
# full. The library it served is gone too — 2.6 TB, see the vault incident note.
#
# plex-gpu 236 is the Plex now. 103 leaves state via `state rm`, never a destroy:
# terraform cannot destroy a guest on a node that no longer resolves, and there is
# nothing left to destroy. scripts/tf-state-repoint-media.sh does it.

# plex-gpu 236/.236 — the SECOND Plex, on pve02, for hardware transcoding.
#
# WHY IT EXISTS. It was built as a SECOND Plex alongside 103 on pve01, for Quick
# Sync: pve01's two Xeon E5-2690 v2 have no integrated GPU, so every transcode
# there was software, while pve02's i5-6500T has Quick Sync at
# /dev/dri/renderD128, passed through below. Two Plex servers each need their own
# identity, so this was a fresh install scanning the same library rather than a
# copy of 103's database, which would have made both fight over one plex.tv entry.
#
# It is now the ONLY Plex — 103 died with pve01 on 2026-09-03, and the rollback
# this design preserved no longer exists. The library is local ZFS on pve02
# (`media`, RAIDZ1) rather than NFS from pve01.
#
# ⚠ THE BRIDGE NUMBERS ARE INVERTED BETWEEN THE NODES. Do NOT copy 103's values.
#     pve01:  vmbr0 = .86 mesh    vmbr1 = .50 LAN          (node is gone)
#     pve02:  vmbr0 = .50 LAN     vmbr1 = vxlan86, dead     (see below)
# So this container's LAN bridge is vmbr0 — the OPPOSITE of what plex 103 used,
# where vmbr1 carried the .50 leg. A container placed on the wrong bridge cannot
# reach its gateway. petedio-iac's runner.tf carries the same warning for
# runner-233.
#
# NO .86 MESH LEG — IT WAS REMOVED, AND IT MUST NOT COME BACK (PET-331).
#
# This container used to hold a real 192.168.86.236 on vmbr1 for native Plex
# client discovery. vmbr1 on pve02 is not a NIC: it is backed by `vxlan86`, a
# VXLAN that carried mesh layer-2 across the .50 cable to pve01 — the ONLY node
# cabled to the .86 mesh — which bridged it into its own mesh bridge.
#
# pve01 died on 2026-09-03. pve03 has no mesh bridge and no VXLAN, only vmbr0 on
# .50 and the wlo1 escape hatch, so nothing terminates that tunnel any more. The
# live container has already lost its eth1. Re-declaring it would bring up an
# interface on a tunnel with nothing at the far end, and terraform would report
# success — which is exactly what it did on every merge from 2026-09-03 to
# 2026-09-04: `Plan: 0 to add, 1 to change, 0 to destroy`, forever.
#
# ⚠ pve03 now holds pve01's old address, 192.168.50.10. If vxlan86's remote is
# configured by IP rather than by name, that tunnel now points at pve03 — a
# different machine that is not on the mesh. Check before reviving any of this.
#
# Plex is reached three other ways and needs none of this: the tailnet
# (100.97.96.88, depends on nothing else), the pete-pi-1 proxy
# (192.168.86.46:32400), and 192.168.50.236 on the LAN.
#
# WHY 236 AND NOT A 1xx. The 1xx block is the pve01 media stack. This server runs
# on pve02, so it follows the convention every non-media service uses: a 2xx VMID
# with the IP's last octet matching it — 221 minio, 231 postgres, 233 runner, 235
# plane. 23x is the Apps block, and runner-233 already proves a 23x guest on
# pve02. 234 is skipped on purpose: it was palworld-234, and the vault's host
# notes are keyed on VMID, so reusing a retired number makes its note ambiguous.
module "plex_gpu" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 236
  hostname         = "plex-gpu"
  ipv4_address     = "192.168.50.236/24"
  gateway          = "192.168.50.1"
  bridge           = "vmbr0" # pve02's LAN bridge — NOT vmbr1. See the warning above.
  firewall         = true
  cores            = 4
  memory_dedicated = 4096
  memory_swap      = 2048
  # 32G, double plex 103's 16G: a fresh server re-downloads all artwork and
  # metadata for the whole library rather than inheriting 103's cache.
  disk_size    = 32
  datastore_id = "local-lvm" # pve02's NVMe thinpool, not the USB HDD.
  target_node  = "pve02"

  ssh_public_key = var.ssh_public_key
  description    = "Plex #2 on pve02, Quick Sync hardware transcoding. Media stack — managed by petedio-media-iac."

  # NO device_passthrough HERE, for the same reason there are no mount_points:
  # adding a host device to an unprivileged LXC is root@pam-only, and the
  # provider holds an API token. The create fails with `Permission check failed
  # (configuring device passthrough is only allowed for root@pam)`.
  #
  # scripts/lxc-oob-236.sh sets it: `pct set 236 -dev0
  # /dev/dri/renderD128,gid=44,mode=0660`. gid 44 = video INSIDE the container,
  # the group the Plex package already puts its service user in (verified on 103:
  # uid=999(plex) groups=996(plex),44(video)). On the pve02 host the node is
  # root:render(993); the passthrough re-groups it on the way in.

  # NO mount_points HERE, DELIBERATELY. This container serves the same library
  # 103 does, over NFS, bind-mounted at /mnt/media and /mnt/downloads — but
  # Terraform cannot create those. A bind mount is gated behind Proxmox's
  # hardcoded `user == root@pam` check, and the provider authenticates with an
  # API token, so a create carrying a mount_point block fails with:
  #
  #   Permission check failed (mount point type bind is only allowed for root@pam)
  #
  # The other seven media LXCs declare mount_points and are fine because they
  # were IMPORTED: Terraform adopted mounts that already existed. A new container
  # is the case that breaks, and it broke on the first apply of this module.
  #
  # So Terraform creates the container bare, and scripts/lxc-mounts-236.sh adds
  # both mounts with `pct set` as root@pam on pve02. The module keeps mount_point
  # in ignore_changes, so a later apply never strips them. Same split as
  # features/nesting — see docs/GOTCHAS.md and petedio-iac's scripts/lxc-features-*.sh.
  #
  # Run the script BEFORE bootstrap-plex-gpu.yml; the play asserts /mnt/media is
  # mounted and non-empty inside the container and will fail without it.
}

# sonarr 104/.15 — sdb3-storage 4G, vmbr1
module "sonarr" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 104
  hostname         = "sonarr"
  ipv4_address     = "192.168.50.15/24"
  cores            = 2
  memory_dedicated = 1024
  disk_size        = 4
  datastore_id     = "local"
  ipv6_auto        = true # created with ip6=auto
  ssh_public_key   = var.ssh_public_key
  target_node      = "pve03"
  description      = "Sonarr (TV). Media stack — managed by petedio-media-iac."

  mount_points = [
    { volume = local.media_volume, path = "/mnt/media" },
    { volume = local.downloads_volume, path = "/downloads" },
  ]
}

# radarr 105/.16 — sdb3-storage 4G, vmbr1
module "radarr" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 105
  hostname         = "radarr"
  ipv4_address     = "192.168.50.16/24"
  cores            = 2
  memory_dedicated = 1024
  disk_size        = 4
  datastore_id     = "local"
  ipv6_auto        = true # created with ip6=auto
  ssh_public_key   = var.ssh_public_key
  target_node      = "pve03"
  description      = "Radarr (movies). Media stack — managed by petedio-media-iac."

  mount_points = [
    { volume = local.media_volume, path = "/mnt/media" },
    { volume = local.downloads_volume, path = "/downloads" },
  ]
}

# prowlarr 109/.20 — local-lvm 4G, vmbr1 (the "media-extra" mislabel in the doc)
module "prowlarr" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 109
  hostname         = "prowlarr"
  ipv4_address     = "192.168.50.20/24"
  cores            = 1
  memory_dedicated = 1024
  disk_size        = 4
  datastore_id     = "local"
  ssh_public_key   = var.ssh_public_key
  target_node      = "pve03"
  description      = "Prowlarr (indexers). Media stack — managed by petedio-media-iac."

  mount_points = [
    { volume = local.media_volume, path = "/media" },
    { volume = local.downloads_volume, path = "/downloads" },
  ]
}

# qbittorrent-vpn 110/.21 — local-lvm 20G, vmbr1 (firewall on). Gluetun/Proton.
# Also present in the OLD homelab-infra TF state — reconcile (state rm old side).
module "qbittorrent_vpn" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 110
  hostname         = "qbittorrent-vpn"
  ipv4_address     = "192.168.50.21/24"
  firewall         = true
  cores            = 2
  memory_dedicated = 2048
  disk_size        = 20
  datastore_id     = "local-lvm"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  description      = "qBittorrent behind Gluetun/Proton VPN. Media stack — managed by petedio-media-iac."

  mount_points = [
    { volume = local.media_volume, path = "/media" },
    { volume = local.downloads_volume, path = "/downloads" },
  ]
}

output "media_vm_ids" {
  description = "VMIDs of the captured media containers."
  value = {
    seerr           = module.seerr.vm_id
    plex_gpu        = module.plex_gpu.vm_id
    sonarr          = module.sonarr.vm_id
    radarr          = module.radarr.vm_id
    prowlarr        = module.prowlarr.vm_id
    qbittorrent_vpn = module.qbittorrent_vpn.vm_id
  }
}
