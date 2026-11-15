terraform {
  required_version = ">= 1.7.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.122.0" # exact: .terraform.lock.hcl is gitignored, so this pin keeps CI and the Mac on one provider (MED-11)
    }
  }
}
