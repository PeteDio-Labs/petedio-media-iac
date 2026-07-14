# Media data volumes & the no-data-loss guarantee (PET-48)

Where every stateful bit of the media stack lives, and why capture / renumber /
destroy-recreate is safe for the **library + downloads** but **not** for the
per-app config on each container's rootfs. Ground-truthed on pve01 + the LXCs,
2026-07-14.

## The one guarantee

The **media library and downloads live on host LVs, bind-mounted into the
containers** — so destroying or recreating a *container* never touches them. What
*is* tied to a container is its **app config/db on the LXC rootfs**; that is the
only data a destroy+recreate (e.g. the deferred renumber, PET-49) would lose, so
it is the thing to back up.

## Host stores (pve01, physical disk `sdb` 4.4T → VG `media-vg`)

| LV | Size (used) | FS | Host mountpoint | Holds |
|---|---|---|---|---|
| `media-vg/media-lv` | 3.22T (2.5T, 82%) | ext4 | `/mnt/media` | Plex/\*arr media library |
| `media-vg/downloads-lv` | 200G (23G, 13%) | ext4 | `/mnt/downloads` | qBittorrent downloads |

Both are **bind-mounted** into the LXCs (Terraform `mount_points` in
`environments/media/media.tf`). Container rootfs disks live on the Proxmox
datastores `local-lvm` (thin) or `sdb3-storage` (the `sdb3` partition) — separate
from `media-vg`.

## Bind-mounts per container (target path inside the LXC)

| LXC (VMID) | `/mnt/media` → | `/mnt/downloads` → | Notes |
|---|---|---|---|
| lidarr (100) | `/mnt/media` | `/downloads` | |
| seerr (101) | — | — | no bind-mounts (requests only) |
| plex (103) | `/mnt/media` | `/mnt/downloads` (**ro**) | downloads read-only |
| sonarr (104) | `/mnt/media` | `/downloads` | |
| radarr (105) | `/mnt/media` | `/downloads` | |
| prowlarr (109) | `/media` | `/downloads` | |
| qbittorrent-vpn (110) | `/media` | `/downloads` | writes completed → `/downloads/completed/` |

Inside qbit these bind-mounts surface as `media-vg-media-lv` on `/media` and
`media-vg-downloads-lv` on `/downloads` (then re-mounted 1:1 into the Docker
containers).

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
qbit config dirs. Until then, take a `pct snapshot` before any destructive change
(renumber, upgrade). Tracked under PET-48.
