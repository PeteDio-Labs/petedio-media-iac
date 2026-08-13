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
        VAULT[("Vault .223 — re-seals on every reboot<br/>kv/iac/* — proxmox token, minio creds, lxc-ssh key<br/>kv/services/media/qbittorrent — Proton WG key (SEED PENDING;<br/>currently only in .env on 110)")]
    end

    TF -- "backend.tf" --> MINIO
    TF -- "terraform-local AppRole<br/>reads kv/iac/*" --> VAULT
    ANS -- "ansible AppRole<br/>reads kv/services/media/* (nothing to read yet)" --> VAULT
    CI --> TF

    TF -- "bpg/proxmox API token<br/>https://192.168.50.10:8006" --> PVE
    ANS -- "ssh root@LXC<br/>id_ed25519_ansible" --> PVE

    subgraph PVE["Proxmox pve01 (.10)"]
        direction TB
        MOD["module proxmox-lxc<br/>(per-host: cores/mem/disk/datastore,<br/>mounts, 2nd NIC, firewall, ipv6)"]

        subgraph media["media LXCs — live VMID/IP (permanent; 21x renumber canceled, PET-49)"]
            direction TB
            LIDARR["lidarr · 100 · .14<br/>local-lvm"]
            SEERR["seerr · 101 · .33<br/>sdb3 · eth1-only · no mounts"]
            PLEX["plex · 103 · 86.140 + .140<br/>dual-homed (vmbr0 mesh + vmbr1)<br/>downloads ro"]
            SONARR["sonarr · 104 · .15<br/>sdb3 · ipv6 auto"]
            RADARR["radarr · 105 · .16<br/>sdb3 · ipv6 auto"]
            PROWLARR["prowlarr · 109 · .20<br/>local-lvm"]
            QBIT["qbittorrent-vpn · 110 · .21<br/>Gluetun/Proton · compose templated"]
        end

        subgraph stores["shared host stores (bind-mounted, data lives here)"]
            MNT["/mnt/media<br/>/mnt/downloads"]
        end

        POOL["Proxmox resource pool<br/>(pool.tf — PET-56)"]
    end

    MOD --> LIDARR & SEERR & PLEX & SONARR & RADARR & PROWLARR & QBIT
    LIDARR & PLEX & SONARR & RADARR & PROWLARR & QBIT -. "bind-mount" .-> MNT
    LIDARR & SEERR & PLEX & SONARR & RADARR & PROWLARR & QBIT -. "pool member" .-> POOL

    classDef store fill:#eef,stroke:#88a;
    classDef pool fill:#efe,stroke:#8a8;
    class MNT store;
    class POOL pool;
```

## Legend / notes

- **Terraform** (`environments/media`) declares each LXC via the reusable
  `modules/proxmox-lxc`; the 7 hosts were `terraform import`ed to a **zero-drift**
  plan (PET-46). State key is isolated from `petedio-iac` (`media/terraform.tfstate`).
- **Ansible** configures the running services idempotently (PET-47, **complete**).
  Roles: `media-base`, `servarr` (one parametrised role covering
  sonarr/radarr/lidarr/prowlarr), `plex`, `seerr`, `qbittorrent-vpn`,
  `media-lifecycle`. Reaches the LXCs over `id_ed25519_ansible` (bootstrapped
  additively via pve01 `pct exec`).
- **Secrets:** the Proxmox token / MinIO creds / LXC ssh key are the same
  `kv/iac/*` values `petedio-iac` uses (read via the `terraform-local` AppRole).
  The media-only VPN secret (`kv/services/media/qbittorrent`) is read by the
  `ansible` AppRole; **its seed is still pending** a privileged token — see
  [runbooks/qbittorrent-vault-secret.md](runbooks/qbittorrent-vault-secret.md).
- **Data safety:** the *arr/Plex media + downloads live on the shared host stores
  `/mnt/media` + `/mnt/downloads` (bind-mounts), so destroying/recreating a
  *container* never touches the data.
- **Pool membership** (`pool.tf`, PET-56) puts all seven LXCs in a Terraform-managed
  Proxmox resource pool. Add-only — it was the one change in the first real apply.
- **filebrowser (102)** is **decommissioned** — PET-82 is Done. It no longer exists
  on the cluster and is not modelled here.
- **The 21x renumber is canceled** (PET-49) — these legacy VMIDs/IPs are permanent,
  not an interim state waiting on a migration.
