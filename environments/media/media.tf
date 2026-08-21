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

# lidarr 100/.14 — local-lvm 4G, vmbr1
module "lidarr" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 100
  hostname         = "lidarr"
  ipv4_address     = "192.168.50.14/24"
  cores            = 2
  memory_dedicated = 1024
  disk_size        = 4
  datastore_id     = "local-lvm"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
  description      = "Lidarr (music). Media stack — managed by petedio-media-iac."

  mount_points = [
    { volume = local.media_volume, path = "/mnt/media" },
    { volume = local.downloads_volume, path = "/downloads" },
  ]
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
  datastore_id     = "sdb3-storage"
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

# sonarr 104/.15 — sdb3-storage 4G, vmbr1
module "sonarr" {
  source = "../../modules/proxmox-lxc"

  vm_id            = 104
  hostname         = "sonarr"
  ipv4_address     = "192.168.50.15/24"
  cores            = 2
  memory_dedicated = 1024
  disk_size        = 4
  datastore_id     = "sdb3-storage"
  ipv6_auto        = true # created with ip6=auto
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
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
  datastore_id     = "sdb3-storage"
  ipv6_auto        = true # created with ip6=auto
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
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
  datastore_id     = "local-lvm"
  ssh_public_key   = var.ssh_public_key
  target_node      = var.target_node
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
    lidarr          = module.lidarr.vm_id
    seerr           = module.seerr.vm_id
    plex            = module.plex.vm_id
    sonarr          = module.sonarr.vm_id
    radarr          = module.radarr.vm_id
    prowlarr        = module.prowlarr.vm_id
    qbittorrent_vpn = module.qbittorrent_vpn.vm_id
  }
}
