# petedio-media-iac (Agent Context)

Terraform + Ansible for the homelab **media stack**, brought under IaC by
**brownfield capture** — import the running LXCs as-is, **no rebuild, no data
loss, no downtime**. Split out from `petedio-iac` so media has its own MinIO
state object (`media/terraform.tfstate`) and its own Vault secret scope.

> Part of the PeteDio homelab→AWS platform. The parent workspace
> (`petedio-workspace`) holds the cross-repo context; the canonical infra
> reference is the Linear **"Homelab Inventory & IP/VMID Scheme"** doc. Tracker:
> Linear project **Platform**, **Media Stack** milestone (`PET-46/47/48/49/53`).

## Golden rules (this repo)

1. **Capture in place.** The job is reproducibility-as-code, not migration. Import
   each LXC, iterate HCL until `terraform plan` is a **clean no-op (zero drift)**.
   **Never `apply` against drift** — it could mutate/recreate a data-heavy container.
2. **VMIDs are the live legacy numbers** (100/101/103/104/105/109/110), NOT the
   target 21x scheme. Renumber is **deferred** (PET-49) — it's a destroy+recreate,
   too disruptive for cosmetic gain.
3. **Ground-truth before you trust docs.** The Linear inventory doc was wrong about
   media VMID→role→IP (corrected 2026-06-04). Always `ssh root@192.168.50.10
   'pct list && pct config <id>'` to confirm before editing HCL.
4. **Secrets in Vault, never in code.** qBittorrent's Proton WireGuard key + qBit
   password go to a media Vault path (e.g. `kv/services/media/qbittorrent`) read by
   a media-scoped policy — not committed, not in the shared `ansible` policy.

## bpg / Proxmox gotchas (carried from petedio-iac — honor verbatim)

- **No `features {}` in TF.** API tokens can't set LXC features (root@pam check).
  Ansible sets nesting/keyctl out-of-band (`pct set <id> --features ...`). Keep
  `features` in `lifecycle.ignore_changes`.
- **Import never round-trips** `template_file_id`, `features`, `user_account` —
  all three are in `ignore_changes` or every plan shows phantom drift.
- **`vmbr1` is the LAN bridge on pve01; `vmbr0` has no gateway** — EXCEPT plex,
  which is genuinely on the `.86` mesh segment via vmbr0 (a different NIC). Capture
  plex as dual-homed (net0 vmbr0/.86 + net1 vmbr1/.50).
- **Target the pve01 endpoint** (`https://192.168.50.10:8006/`) — all media LXCs live there.
- See `docs/GOTCHAS.md` for the full list + media-specific notes.

## Hosts

lidarr 100/.14 · seerr 101/.33 (sdb3, eth1-only, no mounts) · plex 103 (dual-homed,
downloads ro) · sonarr 104/.15 (sdb3) · radarr 105/.16 (sdb3) · prowlarr 109/.20 ·
qbittorrent-vpn 110/.21 (Gluetun/Proton; **also in old TF — reconcile**).
**filebrowser 102 EXCLUDED** (decommission → PET-82).

## Runtime / tooling

- **Terraform** for the LXCs; **Ansible** for host/service config. SSH: Proxmox
  host hop = `id_ed25519_proxmox_pedro`; into the LXCs = `id_ed25519_ansible`.
- State in MinIO (`.221`, bucket `tfstate`, key `media/terraform.tfstate`).
  **No locking** — single operator, never concurrent applies.
- CI = Workflow B on the self-hosted runner (`[self-hosted, linux, x64, homelab]`):
  plan-on-PR, apply-on-merge. Creds from Vault via OIDC.

## Workflow

Branch `pet-<n>-<slug>` → PR (plan is the review surface) → squash-merge (apply).
Mention `PET-<n>` in the PR. Keep Linear tickets updated as work proceeds.
