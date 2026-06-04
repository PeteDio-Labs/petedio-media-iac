# Inputs for the reusable proxmox-lxc module. Copied from petedio-iac and extended
# for the media stack: per-host `firewall`, bind-`mount_points`, and an optional
# second NIC (`net1_*`) for the dual-homed plex host. `features` stays Ansible's
# job (the root@pam/API-token gotcha — see docs/GOTCHAS.md).

variable "vm_id" {
  description = "Proxmox VMID. Convention: VMID = last octet of the IPv4 address (media stack keeps its live legacy VMIDs)."
  type        = number
}

variable "hostname" {
  description = "Container hostname (e.g. \"sonarr\")."
  type        = string
}

variable "ipv4_address" {
  description = "Static IPv4 address in CIDR form (e.g. \"192.168.50.15/24\")."
  type        = string
}

variable "gateway" {
  description = "Default gateway for the primary interface."
  type        = string
  default     = "192.168.50.1"
}

variable "target_node" {
  description = "Proxmox node where the container lives."
  type        = string
  default     = "pve01"
}

variable "cores" {
  description = "Number of CPU cores."
  type        = number
  default     = 2
}

variable "memory_dedicated" {
  description = "Dedicated memory in MiB."
  type        = number
  default     = 1024
}

variable "memory_swap" {
  description = "Swap in MiB."
  type        = number
  default     = 512
}

variable "disk_size" {
  description = "Root disk size in GiB."
  type        = number
  default     = 4
}

variable "datastore_id" {
  description = "Proxmox datastore for the root disk. Media hosts vary: local-lvm (most) vs sdb3-storage (sonarr/radarr)."
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "Primary network bridge. vmbr1 = LAN/uplink on pve01 (vmbr0 has no gateway, except the .86 mesh segment used by plex)."
  type        = string
  default     = "vmbr1"
}

variable "firewall" {
  description = "Enable the Proxmox firewall on the primary interface (qbittorrent-vpn and plex have it on)."
  type        = bool
  default     = false
}

# --- Optional second interface (dual-homed hosts: plex) ----------------------
variable "net1_address" {
  description = "CIDR IPv4 for the second interface (eth1). null = single-homed (default)."
  type        = string
  default     = null
}

variable "net1_gateway" {
  description = "Gateway for the second interface. Usually null (the primary holds the default route)."
  type        = string
  default     = null
}

variable "net1_bridge" {
  description = "Bridge for the second interface (eth1). null = no second NIC (default)."
  type        = string
  default     = null
}

variable "net1_firewall" {
  description = "Enable the Proxmox firewall on the second interface."
  type        = bool
  default     = false
}

# --- Bind-mounts -------------------------------------------------------------
variable "mount_points" {
  description = "Bind-mounts to attach (e.g. /mnt/media, /mnt/downloads). List of {volume, path}."
  type = list(object({
    volume = string
    path   = string
  }))
  default = []
}

variable "template_file_id" {
  description = "OS template volume ID for the container."
  type        = string
  default     = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
}

variable "ssh_public_key" {
  description = "SSH public key installed for root inside the LXC (matches the key Ansible logs in with)."
  type        = string
}

variable "unprivileged" {
  description = "Whether the container is unprivileged."
  type        = bool
  default     = true
}

variable "start_on_boot" {
  description = "Start the container automatically on node boot (also used as the desired running state)."
  type        = bool
  default     = true
}

variable "dns_servers" {
  description = "DNS resolvers for the container."
  type        = list(string)
  default     = ["192.168.50.1"]
}

variable "dns_domain" {
  description = "DNS search domain for the container."
  type        = string
  default     = "local"
}

variable "description" {
  description = "Container description shown in the Proxmox UI."
  type        = string
  default     = "Managed by Terraform (petedio-media-iac)."
}
