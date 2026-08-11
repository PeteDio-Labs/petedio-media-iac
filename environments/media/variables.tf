variable "proxmox_endpoint" {
  description = <<-EOT
    Proxmox API endpoint (https://<node>:8006/). bpg/proxmox reads the PVE
    version from this endpoint and conditionally sends version-gated fields, so
    target the node where the resources actually live (pve01 9.1.x — all media
    LXCs live there).
  EOT
  type        = string
  default     = "https://192.168.50.10:8006/"
}

variable "proxmox_api_token" {
  description = "Full token: 'user@realm!tokenid=secret'. Minted via pveum (petedio@pam!petedio)."
  type        = string
  sensitive   = true
}

variable "target_node" {
  description = "Proxmox node where these resources live."
  type        = string
  default     = "pve01"
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
