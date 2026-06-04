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
        CI[".github/workflows/terraform.yml<br/>Workflow B: plan-on-PR / apply-on-merge<br/>(self-hosted runner 232)"]
    end

    subgraph backing["State & secrets"]
        MINIO[("MinIO S3 .221<br/>bucket tfstate<br/>key media/terraform.tfstate")]
        VAULT[("Vault .223<br/>kv/iac/* — proxmox token, minio creds, lxc-ssh key<br/>kv/services/media/qbittorrent — VPN secret (seed pending)")]
    end

    TF -- "backend.tf" --> MINIO
    TF -- "terraform-local AppRole<br/>reads kv/iac/*" --> VAULT
    ANS -- "ansible AppRole<br/>reads kv/services/media/* (seed pending)" --> VAULT
    CI --> TF

    TF -- "bpg/proxmox API token<br/>https://192.168.50.10:8006" --> PVE
    ANS -- "ssh root@LXC<br/>id_ed25519_ansible" --> PVE

    subgraph PVE["Proxmox pve01 (.10)"]
        direction TB
        MOD["module proxmox-lxc<br/>(per-host: cores/mem/disk/datastore,<br/>mounts, 2nd NIC, firewall, ipv6)"]

        subgraph media["media LXCs — live VMID/IP (renumber to 21x deferred, PET-49)"]
            direction TB
            LIDARR["lidarr · 100 · .14<br/>local-lvm"]
            SEERR["seerr · 101 · .33<br/>sdb3 · eth1-only · no mounts"]
            PLEX["plex · 103 · 86.140 + .140<br/>dual-homed (vmbr0 mesh + vmbr1)<br/>downloads ro"]
            SONARR["sonarr · 104 · .15<br/>sdb3 · ipv6 auto"]
            RADARR["radarr · 105 · .16<br/>sdb3 · ipv6 auto"]
            PROWLARR["prowlarr · 109 · .20<br/>local-lvm · Ansible role ✓"]
            QBIT["qbittorrent-vpn · 110 · .21<br/>Gluetun/Proton · also in OLD TF"]
        end

        subgraph stores["shared host stores (bind-mounted, data lives here)"]
            MNT["/mnt/media<br/>/mnt/downloads"]
        end

        FB["filebrowser · 102<br/>EXCLUDED — decommission (PET-82)"]
    end

    MOD --> LIDARR & SEERR & PLEX & SONARR & RADARR & PROWLARR & QBIT
    LIDARR & PLEX & SONARR & RADARR & PROWLARR & QBIT -. "bind-mount" .-> MNT

    classDef excluded fill:#fdd,stroke:#c33,stroke-dasharray:4 3;
    classDef store fill:#eef,stroke:#88a;
    class FB excluded;
    class MNT store;
```

## Legend / notes

- **Terraform** (`environments/media`) declares each LXC via the reusable
  `modules/proxmox-lxc`; the 7 hosts were `terraform import`ed to a **zero-drift**
  plan (PET-46). State key is isolated from `petedio-iac` (`media/terraform.tfstate`).
- **Ansible** configures the running services idempotently (PET-47). Only
  `prowlarr` has a role so far; the rest are follow-up. Reaches the LXCs over
  `id_ed25519_ansible` (bootstrapped additively via pve01 `pct exec`).
- **Secrets:** the Proxmox token / MinIO creds / LXC ssh key are the same
  `kv/iac/*` values `petedio-iac` uses (read via the `terraform-local` AppRole).
  The media-only VPN secret (`kv/services/media/qbittorrent`) is read by the
  `ansible` AppRole; **its seed is still pending** a privileged token — see
  [runbooks/qbittorrent-vault-secret.md](runbooks/qbittorrent-vault-secret.md).
- **Data safety:** the *arr/Plex media + downloads live on the shared host stores
  `/mnt/media` + `/mnt/downloads` (bind-mounts), so destroying/recreating a
  *container* never touches the data.
- **filebrowser (102)** is intentionally excluded and flagged for decommission (PET-82).
- **Renumber to the 21x block is deferred** (PET-49) — these are the live legacy VMIDs/IPs.
