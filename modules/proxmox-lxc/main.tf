# Reusable Debian LXC on Proxmox — the EC2-equivalent building block.
# Copied verbatim from petedio-iac (the proven runner/poker pattern) and extended
# with an OPTIONAL second network interface (var.net1_*) for a dual-homed host.
#
# ⚠ THE MAPPING IS INVERTED FROM WHAT THIS COMMENT USED TO SAY. It described plex
# 103 on pve01: net0 on the .86 mesh via vmbr0, net1 on the .50 LAN via vmbr1.
# That host died with pve01 on 2026-09-03. The one dual-homed host is plex-gpu 236
# on pve02: net0 = vmbr0, 192.168.50.236/24, the LAN and the default route; net1 =
# vmbr2, 192.168.86.236/24, the mesh (PET-444). pve02's vmbr1 is the dead VXLAN leg
# to pve01 and carries nothing — putting a NIC there gives it no route.
#
# Deliberately NO `features {}` block: Proxmox rejects API tokens for the
# features mutation (root@pam check), so nesting/keyctl are set out-of-band by
# Ansible. `features` is in ignore_changes so a later apply never strips them.
# See docs/GOTCHAS.md.
#
# ⚠ THAT ANSIBLE LIVES IN petedio-iac, NOT HERE: `configure-lxc-features.yml`
# plus `roles/lxc-features` (PET-378). It runs against the Proxmox NODES, which
# hold guests from both repos, so it declares and converges every container in
# the lab — media LXCs included. RUN IT AFTER CREATING A CONTAINER.
#
# Until PET-378 this comment named a mechanism that did not exist. The only thing
# setting features was three one-off scripts for three named containers in
# petedio-iac, so anything created through this module got none: CT 109 prowlarr
# has never had them, and its `systemd-logind` has been dead at 226/NAMESPACE
# ever since, costing 25 s on every SSH login (PET-377). Nothing reports it —
# `features` is in ignore_changes, so the plan is clean either way.

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

  # Second NIC for dual-homed hosts — today only plex-gpu 236, eth1 on vmbr2 (the
  # .86 mesh). Only created when var.net1_bridge is set, so single-homed hosts are
  # unaffected. The bridge is the caller's to name; do not assume vmbr1, which on
  # pve02 is the dead VXLAN leg.
  dynamic "network_interface" {
    for_each = var.net1_bridge != null ? [1] : []
    content {
      name     = "eth1"
      bridge   = var.net1_bridge
      firewall = var.net1_firewall
      mtu      = var.net1_mtu
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

  # Host device passthrough (plex-gpu 236: /dev/dri/renderD128 for Quick Sync).
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
      # device_passthrough: adding a host device to an unprivileged LXC is gated
      # behind the same hardcoded `root@pam` check. The create fails with
      # `Permission check failed (configuring device passthrough is only allowed
      # for root@pam)`. Set it out-of-band with `pct set <id> -dev0 ...`
      # (scripts/lxc-oob-236.sh), exactly as petedio-iac does for the tun device
      # on tailscale 244 and openfaas 241.
      device_passthrough,
      # idmap: root@pam-only for the same reason, and load-bearing where it
      # exists. Declared here so an apply can never strip one. No media LXC sets
      # it today, so this is a no-op for them.
      idmap,
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
      # startup: a guest's boot order and up/down delays. This module declares no
      # startup block, so without this entry an apply would strip the ordering.
      # The loss would show only at the next cold boot. petedio-iac's copy of
      # this module carries the same entry for the same reason. PET-305 missed
      # this copy because it never applied media-iac.
      #
      # petedio-iac declares the media guests' values instead, in
      # ansible/roles/lxc-startup/defaults/main.yml. Its
      # playbooks/configure-lxc-startup.yml runs `pct set <id> --startup` for
      # each declared guest whose line differs, and fails under --check while
      # one does. To change an order, change it in that role.
      #
      #   101  seerr            pve03  order=7,up=0,down=15
      #   104  sonarr           pve03  order=7,up=0,down=15
      #   105  radarr           pve03  order=7,up=0,down=15
      #   109  prowlarr         pve03  order=7,up=0,down=15
      #   110  qbittorrent-vpn  pve02  order=6,up=20,down=30
      #   236  plex-gpu         pve02  order=7,up=0,down=15
      #
      # PET-305 also set lidarr 100 and plex 103, and both guests are gone
      # (PET-319, and the loss of pve01). The PET-440 audit found 236 with no
      # startup line, and PET-451 set it by hand on 2026-09-17.
      startup,
    ]
  }
}
