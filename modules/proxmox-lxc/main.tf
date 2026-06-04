# Reusable Debian LXC on Proxmox — the EC2-equivalent building block.
# Copied verbatim from petedio-iac (the proven runner/poker pattern) and extended
# with an OPTIONAL second network interface (var.net1_*) for the dual-homed plex
# host (net0 on the .86 mesh / vmbr0 + net1 on the .50 LAN / vmbr1).
#
# Deliberately NO `features {}` block: Proxmox rejects API tokens for the
# features mutation (root@pam check), so nesting/keyctl are set out-of-band by
# Ansible (`pct set --features nesting=1,keyctl=1`). `features` is in
# ignore_changes so a later apply never strips them. See docs/GOTCHAS.md.

resource "proxmox_virtual_environment_container" "this" {
  description   = var.description
  node_name     = var.target_node
  vm_id         = var.vm_id
  unprivileged  = var.unprivileged
  start_on_boot = var.start_on_boot
  started       = var.start_on_boot

  initialization {
    hostname = var.hostname

    ip_config {
      ipv4 {
        address = var.ipv4_address
        gateway = var.gateway
      }
    }

    # Second interface (only emitted when var.net1_address is set — plex).
    dynamic "ip_config" {
      for_each = var.net1_address != null ? [1] : []
      content {
        ipv4 {
          address = var.net1_address
          gateway = var.net1_gateway
        }
      }
    }

    dns {
      servers = var.dns_servers
      domain  = var.dns_domain
    }

    user_account {
      keys = [trimspace(var.ssh_public_key)]
    }
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = "debian"
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory_dedicated
    swap      = var.memory_swap
  }

  disk {
    datastore_id = var.datastore_id
    size         = var.disk_size
  }

  network_interface {
    name     = "eth0"
    bridge   = var.bridge
    firewall = var.firewall
  }

  # Second NIC for dual-homed hosts (plex: eth1 on vmbr1). Only created when
  # var.net1_bridge is set, so single-homed hosts are unaffected.
  dynamic "network_interface" {
    for_each = var.net1_bridge != null ? [1] : []
    content {
      name     = "eth1"
      bridge   = var.net1_bridge
      firewall = var.net1_firewall
    }
  }

  # Bind-mounts (e.g. /mnt/media, /mnt/downloads) captured per host. bpg models
  # these as mount_point blocks; order matters for a clean import round-trip.
  dynamic "mount_point" {
    for_each = var.mount_points
    content {
      volume = mount_point.value.volume
      path   = mount_point.value.path
    }
  }

  lifecycle {
    ignore_changes = [
      operating_system[0].template_file_id,
      initialization[0].user_account,
      features,
    ]
  }
}
