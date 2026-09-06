# Media data volumes & the no-data-loss guarantee (PET-48)

Where every stateful bit of the media stack lives, and why capture / renumber /
destroy-recreate is safe for the **library + downloads** but **not** for the
per-app config on each container's rootfs. Originally ground-truthed on pve01 + the
LXCs 2026-07-14. **The host-store half was invalidated by the 2026-09-03 rack loss and
re-ground-truthed on pve02/pve03 2026-09-06** (PET-354).

> This document is PET-48's deliverable. It sat unmerged in PR #3 for a month —
> the PR's *code* was superseded by the `servarr` role consolidation, and the docs
> went down with it. Salvaged and corrected rather than lost.

## The one guarantee

The **media library and downloads live on host LVs, bind-mounted into the
containers** — so destroying or recreating a *container* never touches them. What
*is* tied to a container is its **app config/db on the LXC rootfs**; that is the
only data a destroy+recreate would lose, so it is the thing to back up.

(The renumber that originally motivated this — PET-49 — was **canceled** on
2026-07-21, so the legacy VMIDs are permanent and no planned destroy+recreate is
pending. The guarantee still matters: it is what makes any *future* rebuild safe,
and the per-app config is still the unbacked-up part either way.)

## Host stores (pve02, ZFS — **rebuilt; the LVM layout below is gone**)

⚠ Everything this section used to describe was destroyed on 2026-09-03. The stores
were LVM logical volumes on pve01's `sdb` (`media-vg/media-lv`, `media-vg/downloads-lv`,
both ext4) behind a PERC H710 that failed and took 2.6 TB of library with it. They no
longer exist in any form. Re-measured on pve02 2026-09-06 (PET-354):

| ZFS pool | Layout | Size (used) | Host mountpoint | Holds |
|---|---|---|---|---|
| `media` | RAIDZ1, 4 × 953.9G USB SSD | 2.7T (**173G, 7%**) | `/mnt/media` | Plex/\*arr media library |
| `downloads` | single 894.3G USB SSD | 861G (**5.4G, 1%**) | `/mnt/downloads` | qBittorrent downloads |

> That 7% is not headroom won, it is the hole the outage left: the library was 2.5T
> at 81% before the failure. The `downloads-lv` growth warning that used to sit here
> (23G → 115G in a month) is moot — the volume it described is gone.
>
> **No hardware RAID anywhere, deliberately.** Both pools are built on
> `/dev/disk/by-id/` paths with `failmode=continue`, which is the direct lesson of
> the controller that killed the last set. See `vault/Incidents/2026-09-03-rack-loss.md`.

**The stores live on pve02 and pve03 reaches them over NFS at identical paths.** That
identity is load-bearing: it is what let PET-334 move seerr/sonarr/radarr/prowlarr to
pve03 without editing a single mount point. Guests on pve03 carry `shared=1` on their
mount points; guests on pve02 do not.

Both are **bind-mounted** into the LXCs (Terraform `mount_points` in
`environments/media/media.tf`). Container rootfs disks are separate from the pools:
`local-lvm` (thin) on pve02, and the plain `local` directory store on pve03, which
**has no LVM thin pool at all** — a guest declared there with `local-lvm` fails at
migration after copying the disk.

## Bind-mounts per container (target path inside the LXC)

Read live from `pct config` on both nodes, 2026-09-06.

| LXC (VMID) | Node | `/mnt/media` → | `/mnt/downloads` → | Notes |
|---|---|---|---|---|
| seerr (101) | pve03 | — | — | no bind-mounts (requests only) |
| sonarr (104) | pve03 | `/mnt/media` | `/downloads` | `shared=1` (NFS) |
| radarr (105) | pve03 | `/mnt/media` | `/downloads` | `shared=1` (NFS) |
| prowlarr (109) | pve03 | `/media` | `/downloads` | `shared=1` (NFS) |
| qbittorrent-vpn (110) | pve02 | `/media` | `/downloads` | writes completed → `/downloads/completed/` |
| plex-gpu (236) | pve02 | `/mnt/media` | `/mnt/downloads` (**ro**) | downloads read-only; the only Plex |

Gone from this table: **lidarr (100)**, removed in PET-319, and **plex (103)**, which
died with pve01 and was not rebuilt.

Inside qbit these bind-mounts surface as the ZFS datasets on `/media` and `/downloads`
(then re-mounted 1:1 into the Docker containers) — not the `media-vg-*` device names
this document used to list.

## Per-app config/state (on each LXC's rootfs — **back this up**)

| App (VMID) | Config path (in LXC) | Size | rootfs datastore |
|---|---|---|---|
| lidarr (100) | `/var/lib/lidarr` | 58M | local-lvm |
| seerr (101) | `/opt/seerr/config` (+ `/etc/seerr/seerr.conf`) | 5.5M | sdb3-storage |
| plex (103) | `/var/lib/plexmediaserver/Library/Application Support/Plex Media Server` | 5.6G | local-lvm |
| sonarr (104) | `/var/lib/sonarr` | 275M | sdb3-storage |
| radarr (105) | `/var/lib/radarr` | 679M | sdb3-storage |
| prowlarr (109) | `/var/lib/prowlarr` | 115M | local-lvm |
| qbittorrent-vpn (110) | `/opt/qbittorrent-vpn/qbittorrent/config` | 8.3M | local-lvm |

## Captured-state ↔ reality

- **Terraform** (`environments/media/media.tf`) already encodes each LXC's rootfs
  `datastore_id` (incl. the `sdb3-storage` outliers) and both bind-`mount_points` —
  verified against live `pct config` (PET-46). No HCL change was needed for this pass.
- **Ansible** (`playbooks/configure-media.yml`) asserts each service running +
  per-host timezone; `--check` is a clean no-op.

## Backup status — open gap

There is **no automated off-box backup** of the per-app config dirs above today.
Options to close it (follow-up): a Proxmox `vzdump` job for the media VMIDs to a PBS
or MinIO target, or file-level sync of the `/var/lib/*arr` + `/opt/seerr/config` +
qbit config dirs.

> ⚠ **`pct snapshot` is NOT a universal fallback here.** The three `sdb3-storage`
> hosts — **seerr (101), sonarr (104), radarr (105)** — are on thick LVM, where
> Proxmox refuses with `snapshot feature is not available`. That is exactly the set
> holding the \*arr databases. For those, take a **tarball** of the config dir
> instead:
>
> ```bash
> ssh root@<host> 'tar czf /root/<app>-config-$(date +%F).tgz -C /var/lib <app>'
> ```
>
> This is not theoretical. A ~500KB config tarball taken immediately before the
> seerr 3.4.1 swap is the only reason that incident was a 4-minute recovery instead
> of a rebuild — see `docs/GOTCHAS.md` and `docs/runbooks/seerr-upgrade.md`.

`local-lvm` hosts (lidarr 100, plex 103, prowlarr 109, qbittorrent-vpn 110) are thin
LVM and **can** be snapshotted.

Tracked under PET-48.
