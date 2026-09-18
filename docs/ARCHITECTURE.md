# Architecture — petedio-media-iac

How this repo's Terraform + Ansible map onto the live homelab media stack.
Brownfield **capture-in-place**: Terraform owns each LXC's existence/shape (imported
zero-drift), Ansible configures the running services idempotently. State lives in
MinIO; secrets in Vault. See [GOTCHAS.md](GOTCHAS.md) and [../CLAUDE.md](../CLAUDE.md).

```mermaid
flowchart TB
    subgraph operator["Control plane (Mac on the LAN / CI runner)"]
        TF["Terraform<br/>environments/media"]
        ANS["Ansible<br/>playbooks/configure-media.yml"]
        CI[".github/workflows/terraform.yml<br/>Workflow B split by trust (PET-163):<br/>validate-on-PR (GitHub-hosted, no creds)<br/>apply-on-merge (self-hosted runner 232)"]
    end

    subgraph backing["State & secrets"]
        MINIO[("MinIO S3 .221<br/>bucket tfstate<br/>key media/terraform.tfstate")]
        VAULT[("Vault .223 — re-seals on every reboot<br/>kv/iac/* — proxmox token, minio creds, lxc-ssh key<br/>kv/services/media/qbittorrent — Proton WG key + addresses<br/>(seeded, PET-452)")]
    end

    TF -- "backend.tf" --> MINIO
    TF -- "terraform-local AppRole<br/>reads kv/iac/*" --> VAULT
    ANS -- "ansible AppRole<br/>reads kv/services/media/qbittorrent<br/>for .env on 110 (PET-453)" --> VAULT
    CI --> TF

    TF -- "bpg/proxmox API token<br/>https://192.168.50.11:8006" --> PVE02
    ANS -- "ssh root@LXC<br/>id_ed25519_ansible" --> PVE02
    ANS --> PVE03

    MOD["module proxmox-lxc<br/>(per-host: cores/mem/disk/datastore,<br/>mounts, firewall, ipv6)"]

    subgraph PVE03["Proxmox pve03 (.10) — the platform node"]
        direction TB
        subgraph arr["media LXCs on pve03 (PET-334)"]
            direction TB
            SEERR["seerr · 101 · .33<br/>eth1-only · no mounts"]
            SONARR["sonarr · 104 · .15<br/>ipv6 auto"]
            RADARR["radarr · 105 · .16<br/>ipv6 auto"]
            PROWLARR["prowlarr · 109 · .20"]
            FLARE["flaresolverr · 102 · .150<br/>DHCP · unmanaged"]
        end
        NFS["/mnt/media + /mnt/downloads<br/>NFS from pve02, identical paths"]
    end

    subgraph PVE02["Proxmox pve02 (.11) — the media node, holds the disks"]
        direction TB
        subgraph dl["media LXCs on pve02"]
            direction TB
            QBIT["qbittorrent-vpn · 110 · .21<br/>Gluetun/Proton · compose templated"]
            PLEXGPU["plex-gpu · 236 · .236<br/>Quick Sync · tailnet 100.97.96.88<br/>the ONLY Plex"]
        end

        subgraph stores["ZFS pools (bind-mounted, data lives here)"]
            MNT["media · RAIDZ1 4x 953.9G SSD<br/>downloads · 1x 894.3G SSD<br/>usage: zfs list on pve02"]
        end

        POOL["Proxmox resource pool<br/>(pool.tf — PET-56)"]
    end

    MOD --> SEERR & SONARR & RADARR & PROWLARR & QBIT & PLEXGPU
    QBIT & PLEXGPU -. "bind-mount" .-> MNT
    MNT -. "NFS export" .-> NFS
    SONARR & RADARR -. "bind-mount" .-> NFS
    SEERR & SONARR & RADARR & PROWLARR & QBIT & PLEXGPU -. "pool member" .-> POOL

    classDef store fill:#eef,stroke:#88a;
    classDef pool fill:#efe,stroke:#8a8;
    class MNT,NFS store;
    class POOL pool;
```

## Legend / notes

- **Terraform** (`environments/media`) declares each LXC via the reusable
  `modules/proxmox-lxc`; the hosts were `terraform import`ed to a **zero-drift**
  plan (PET-46). State key is isolated from `petedio-iac` (`media/terraform.tfstate`).
  The import captured seven; `media.tf` declares **six** module blocks today — lidarr
  100 left in PET-319 and plex 103 died with pve01, and plex-gpu 236 was added.
- **Ansible** configures the running services idempotently (PET-47, **complete**).
  Roles: `media-base`, `servarr` (one parametrised role covering
  sonarr/radarr/prowlarr — lidarr left in PET-319), `plex`, `seerr`,
  `qbittorrent-vpn`, `media-lifecycle`. Reaches the LXCs over
  `id_ed25519_ansible` (bootstrapped additively via `pct exec` on the guest's
  node). The `plex` role updates **plex-gpu 236** since PET-394 — the play in
  `playbooks/media-roles.yml` names `hosts: plex-gpu`. It was hostless between
  103 dying and that change.
- **Secrets:** the Proxmox token / MinIO creds / LXC ssh key are the same
  `kv/iac/*` values `petedio-iac` uses (read via the `terraform-local` AppRole).
  The media-only VPN secret (`kv/services/media/qbittorrent`) is read by the
  `ansible` AppRole; **its seed is still pending** a privileged token — see
  [runbooks/qbittorrent-vault-secret.md](runbooks/qbittorrent-vault-secret.md).
- **Data safety:** the *arr/Plex media + downloads live on the shared host stores
  `/mnt/media` + `/mnt/downloads` (bind-mounts), so destroying/recreating a
  *container* never touches the data.
- **Pool membership** (`pool.tf`, PET-56) puts the six declared LXCs — 101, 104, 105,
  109, 110, 236 — in a Terraform-managed Proxmox resource pool. Add-only; it was the
  one change in the first real apply.
- **filebrowser (102)** is **decommissioned** — PET-82 is Done — but **VMID 102 is
  live**. The number was reused and 102 is flaresolverr on pve03 (`.150`, DHCP,
  deliberately unmanaged), which is what the diagram above shows. The app is gone;
  the number is not free. Neither is modelled in Terraform here.
- **The 21x renumber is canceled** (PET-49) — these legacy VMIDs/IPs are permanent,
  not an interim state waiting on a migration.
