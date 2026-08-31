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

      # Some community-script LXCs (sonarr/radarr) were created with ip6=auto.
      dynamic "ipv6" {
        for_each = var.ipv6_auto ? [1] : []
        content {
          address = "auto"
        }
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
    name     = var.interface_name
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
      volume    = mount_point.value.volume
      path      = mount_point.value.path
      read_only = mount_point.value.read_only
    }
  }

  # Host device passthrough (plex-gpu 107: /dev/dri/renderD128 for Quick Sync).
  # Only emitted when var.device_passthrough is non-empty, so every existing
  # media LXC plans unchanged. Proxmox writes these as `dev0:` entries and sets
  # the unprivileged container's cgroup device rules itself, which is why this
  # does NOT need the container to be privileged.
  dynamic "device_passthrough" {
    for_each = var.device_passthrough
    content {
      path = device_passthrough.value.path
      uid  = device_passthrough.value.uid
      gid  = device_passthrough.value.gid
      mode = device_passthrough.value.mode
    }
  }

  # Brownfield-capture ignore set. Beyond the bpg round-trip trio
  # (template_file_id / user_account / features), media LXCs were created by the
  # community-scripts installer, which left per-host cosmetic state that we must
  # NOT overwrite (capture-in-place): the HTML `description` banner, the `console`
  # block, and heterogeneous per-host `dns` (some 8.8.8.8, some 1.1.1.1, some
  # none). `started` is ignored so a plan never proposes a stop/start. Ignoring
  # these preserves live config and lets `plan` reach a clean no-op.
  # timeout_* are bpg operation timeouts (not container state) that import never
  # populates, so they always show as cosmetic "+ adds"; cpu.architecture/limit
  # are likewise computed defaults import doesn't round-trip. Ignoring them lets
  # `plan` reach a true no-op without proposing any change to the live LXC.
  lifecycle {
    ignore_changes = [
      operating_system[0].template_file_id,
      initialization[0].user_account,
      initialization[0].dns,
      features,
      console,
      description,
      started,
      timeout_clone,
      timeout_create,
      timeout_delete,
      timeout_start,
      timeout_update,
      cpu,
      # mount_point: a BIND mount (a host path into the guest) is gated behind
      # Proxmox's hardcoded `user == root@pam` check, exactly like features. An
      # API token's username is `root@pam!tokenid`, so the create fails with
      # `Permission check failed (mount point type bind is only allowed for
      # root@pam)`. The seven existing media LXCs never hit this because they
      # were IMPORTED — Terraform adopted mounts it never had to create. A NEW
      # container must therefore be created with NO mount_point block, and the
      # mounts added out-of-band with `pct set` as root@pam on the node
      # (scripts/lxc-mounts-236.sh). Ignoring it here keeps the imported hosts
      # clean and stops a later apply stripping a mount the token cannot
      # recreate. petedio-iac's copy of this module carries the same entry.
      mount_point,
      # startup: boot order and up/down delays are set on the node with
      # `pct set <id> --startup order=N,up=S,down=S`, not declared here. Nothing
      # in this repo sets them, so an apply would otherwise STRIP the ordering
      # that PET-305 put on every media LXC before the lab move — a regression
      # that only shows up at the next cold boot. petedio-iac's copy of this
      # module carries the same entry for the same reason; this one was missed
      # because PET-305 never applied media-iac. Verified on the cluster:
      # 100/101/103/104/105/109 are order=7,up=0,down=15 and 110 is
      # order=6,up=20,down=30. Recorded in petedio-iac docs/runbooks/lab-move.md.
      startup,
    ]
  }
}
