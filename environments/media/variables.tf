variable "proxmox_endpoint" {
  description = <<-EOT
    Proxmox API endpoint (https://<node>:8006/). bpg/proxmox reads the PVE
    version from this endpoint and conditionally sends version-gated fields, so
    target a node running the version you are building against. Both nodes run
    9.2.11, so either answers correctly.

    ⚠ The old reason for choosing pve02 — "it carries four of the six remaining
    media guests" — INVERTED in PET-334. pve02 now holds two (qbittorrent-vpn 110
    and plex-gpu 236); pve03 holds the other four (seerr 101, sonarr 104,
    radarr 105, prowlarr 109) plus the whole platform tier. The default is left on
    pve02 because the endpoint only decides which API you talk to, not where a
    guest lands — every guest sets its own target_node explicitly in media.tf.

    ⚠ This was https://192.168.50.10:8006/ until 2026-09-04, and the text above
    it still said "pve01 — all media LXCs live there". That address was pve01's
    and now belongs to pve03, so the old default aimed the provider at a
    different machine than the one holding most of the state. petedio-iac
    corrected its copy on 2026-09-04; this one was missed (PET-332).

    Both nodes run 9.2.11 today, so nothing version-gated diverged. That is
    luck, not design — an address is not a name.
  EOT
  type        = string
  default     = "https://192.168.50.11:8006/"
}

variable "proxmox_api_token" {
  description = "Full token: 'user@realm!tokenid=secret'. Minted via pveum (petedio@pam!petedio)."
  type        = string
  sensitive   = true
}

variable "target_node" {
  description = "Proxmox node where these resources live."
  type        = string
  # ⚠ This is a FALLBACK, not the stack's node. Its only consumer is
  # qbittorrent-vpn (110), which genuinely is on pve02 — every other guest in
  # media.tf sets target_node explicitly, because the stack spans both nodes
  # since PET-334. Verified against /cluster/resources 2026-09-06 (PET-354).
  #
  # pve01 was removed from the cluster after its RAID controller failed on
  # 2026-09-03. Leaving this pointed at a node that does not resolve makes every
  # plan die at refresh with a hostname lookup error.
  default = "pve02"
}

variable "ssh_public_key" {
  description = "SSH public key installed for root inside each LXC (matches the key Ansible logs in with)."
  type        = string
}

# Pool membership (PET-56). Gated for the same reason petedio-iac gates it:
# creating/modifying a pool needs `Pool.Allocate` on the API token, and a 403
# there would otherwise block every unrelated apply in this workspace. Default
# true because the pool already exists and the privilege is already granted —
# flip false if that ever stops being true.
variable "manage_resource_pool" {
  description = "Add the media LXCs to the cluster resource pool."
  type        = bool
  default     = true
}

variable "resource_pool_id" {
  description = "Proxmox resource pool to join. Created/owned by petedio-iac."
  type        = string
  default     = "homelab"
}
