# Media LXC membership in the cluster-wide `homelab` Proxmox resource pool
# (PET-56). Org hygiene only — a pool is a metadata grouping in the Proxmox
# UI/API and changes NOTHING about the containers.
#
# WHY MEMBERSHIP HERE AND NOT IN petedio-iac. The pool RESOURCE is created and
# owned by petedio-iac (environments/homelab/pool.tf). The seven media LXCs are
# Terraform-managed too, just from this repo and this state — so this is where
# their vm_ids exist as module outputs. Declaring the membership here keeps the
# implicit module dependency (a membership can't be created before its
# container) and avoids duplicating VMIDs across two states, which is exactly
# the kind of hardcoding that rots. A Proxmox pool is cluster-wide and
# membership is additive, so two states contributing distinct members to one
# pool is fine — neither owns the other's rows.
#
# ORDERING: petedio-iac must have applied the pool at least once, otherwise
# these 403/404 on a pool that does not exist yet. It has.
#
# NON-DESTRUCTIVE: proxmox_pool_membership is the by-id form — it adds the LXC
# to the pool without touching the container resource, so this is add-only and
# no data-heavy media container is ever recreated. That matters here more than
# in petedio-iac: these are the containers holding the Plex library and the
# *arr databases.

locals {
  media_pool_members = var.manage_resource_pool ? {
    lidarr          = module.lidarr.vm_id
    seerr           = module.seerr.vm_id
    plex            = module.plex.vm_id
    sonarr          = module.sonarr.vm_id
    radarr          = module.radarr.vm_id
    prowlarr        = module.prowlarr.vm_id
    qbittorrent_vpn = module.qbittorrent_vpn.vm_id
  } : {}
}

resource "proxmox_pool_membership" "media" {
  for_each = local.media_pool_members

  pool_id = var.resource_pool_id
  vm_id   = each.value
}
