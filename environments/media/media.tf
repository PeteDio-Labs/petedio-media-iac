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

# plex 103 — DUAL-HOMED: net0 vmbr0/86.140 (mesh, gw .86.1) + net1 vmbr1/.140.
# local-lvm 16G, firewall on both NICs. downloads bind-mount is read-only.
#
# Memory is 4096, raised from 2048: the old cap peaked at 2035 MiB (99%) and
# reached into swap. Plex's WAN upload ceilings now sit at the real 3 Mbps
# uplink, so remote streams transcode instead of direct playing, and a
# transcode costs more memory than a pass-through. Those ceilings live in the
# Plex app, not here — see the vault note before assuming this file explains
# the whole change.
module "plex" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 103
  hostname         = "plex"
  ipv4_address     = "192.168.86.140/24"
  gateway          = "192.168.86.1"
  bridge           = "vmbr0"
  firewall         = true
  net1_address     = "192.168.50.140/24"
  net1_gateway     = "192.168.50.1" # plex's LAN NIC carries the .50 gateway
  net1_bridge      = "vmbr1"
  net1_firewall    = true
  cores            = 4
  memory_dedicated = 4096
  memory_swap      = 2048
  disk_size        = 16
  datastore_id     = "local-lvm"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  description      = "Plex (also mesh shares on .86). Media stack — managed by petedio-media-iac."

  # downloads is mounted read-only on plex.
  mount_points = [
    { volume = local.media_volume, path = "/mnt/media" },
    { volume = local.downloads_volume, path = "/mnt/downloads", read_only = true },
  ]
}

# plex-gpu 236/.236 — the SECOND Plex, on pve02, for hardware transcoding.
#
# WHY A SECOND SERVER AND NOT A MOVE. plex (103) stays exactly as it is on
# pve01. Two Plex servers each need their own identity: copying 103's database
# would hand both the same machine identifier and they would fight over the same
# entry on plex.tv. So this is a fresh install that scans the same library, and
# 103 is untouched and always rollback-ready.
#
# WHY pve02. pve01's two Xeon E5-2690 v2 have no integrated GPU, so every
# transcode there is software. pve02's i5-6500T has Quick Sync at
# /dev/dri/renderD128, passed through below. The media stays on pve01 and is
# read over NFS (petedio-iac: ansible/playbooks/configure-media-share.yml),
# because a 4K remux needs well under a gigabit while transcoding is what
# actually saturates a CPU.
#
# ⚠ THE BRIDGE NUMBERS ARE INVERTED BETWEEN THE NODES. Do NOT copy 103's values.
#     pve01:  vmbr0 = .86 mesh    vmbr1 = .50 LAN
#     pve02:  vmbr0 = .50 LAN     (no second bridge yet)
# So this container's LAN bridge is vmbr0 — the OPPOSITE of plex 103, which uses
# vmbr1 for its .50 leg. A container placed on the wrong bridge cannot reach its
# gateway. petedio-iac's runner.tf carries the same warning for runner-233.
#
# THE .86 LEG RIDES A TUNNEL, NOT A CABLE. Plex clients live on the .86 Google
# mesh, and .86 -> .50 does not route (the .50 network is NATed behind .86).
# pve02 has ONE physical NIC, on .50, so it has no physical path to the mesh and
# no second NIC was available.
#
# Instead, a VXLAN carries mesh layer-2 across the existing .50 cable to pve01,
# which IS cabled to the mesh, and pve01 bridges the tunnel into its own mesh
# bridge. pve02 gets vmbr1 backed by that tunnel, and this container holds a real
# 192.168.86.236 with native client discovery — no NAT and no proxy. Set up in
# /etc/network/interfaces on both nodes; see the PET-311 runbook.
#
# NO net1_gateway ON PURPOSE. The default route stays on the .50 leg so the NFS
# media path from pve01 is unchanged; .86 is reached as a directly-connected
# route. Giving this leg a gateway too would install a second default route.
#
# net1_mtu = 1450 is load-bearing: VXLAN spends 50 of the underlay's 1500 bytes.
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

  # The mesh leg. vmbr1 on pve02 is the VXLAN-backed bridge, NOT a physical NIC —
  # and note this is the opposite of plex 103, where vmbr1 is the .50 LAN.
  net1_bridge   = "vmbr1"
  net1_address  = "192.168.86.236/24"
  net1_firewall = true
  net1_mtu      = 1450

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
    plex            = module.plex.vm_id
    plex_gpu        = module.plex_gpu.vm_id
    sonarr          = module.sonarr.vm_id
    radarr          = module.radarr.vm_id
    prowlarr        = module.prowlarr.vm_id
    qbittorrent_vpn = module.qbittorrent_vpn.vm_id
  }
}
