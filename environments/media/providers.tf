# Proxmox only — the media stack is pure LXC capture. No postgres/vault providers
# here (unlike petedio-iac). Vault is used for SECRETS DELIVERY to Ansible (the
# qbittorrent VPN creds), not by Terraform, so there's no `vault` provider block.

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true # self-signed cert on the homelab Proxmox UI

  ssh {
    agent    = true
    username = "root"
  }
}
