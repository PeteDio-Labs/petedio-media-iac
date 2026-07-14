# GOTCHAS — media stack (petedio-media-iac)

Media-specific hard-won patterns. The general Terraform / bpg-proxmox / Ansible
gotchas live in **`petedio-iac`'s `docs/GOTCHAS.md`** and apply here too — they're
summarized in `CLAUDE.md`. This file adds what's special about the media capture.

## Brownfield import

- **Import is state-only — it never touches the live container.** The whole job is
  to make HCL describe reality so `plan` is a clean no-op. Prove zero-drift on
  `plan` BEFORE any `apply`. An apply against drift could mutate or recreate a
  data-heavy media LXC (Plex library, *arr configs) — unacceptable.
- **Keep the live legacy VMIDs.** A Proxmox VMID is fixed at creation; "renumbering"
  to the 21x scheme means destroy+recreate. Deferred (PET-49). Import at 100/101/
  103/104/105/109/110.
- **The inventory doc drifted from reality** (corrected 2026-06-04): it mislabeled
  VMID→role→IP and omitted lidarr/seerr/filebrowser. Always `pct list`/`pct config`
  on pve01 before trusting any inventory.

## Per-host shape (the variances that bite)

- **rootfs datastore varies:** most media LXCs are on `local-lvm`, but **seerr
  (101), sonarr (104), radarr (105) are on `sdb3-storage`**. The module's
  `datastore_id` must match per host or plan shows drift.
- **plex (103) is DUAL-HOMED:** net0 = vmbr0 `192.168.86.140` (mesh, gw .86.1),
  net1 = vmbr1 `192.168.50.140` (LAN). The module's `net1_*` vars add the second
  NIC. Its `/downloads` bind-mount is **read-only** (`ro=1`).
- **seerr (101) is odd:** its only NIC is **eth1** (not eth0), firewall on, and it
  has **no bind-mounts**. Capture exactly that — don't assume eth0.
- **Bind-mount target paths differ per container:** `/mnt/media` vs `/media`,
  `/downloads` vs `/mnt/downloads`. They're host-dir bind-mounts of the shared
  `/mnt/media` + `/mnt/downloads` on pve01. Encode each host's actual target path.
- **Firewall flag:** on for plex, seerr, qbittorrent-vpn; off for the rest.
- **Container timezone is NOT uniform:** `America/Chicago` on lidarr/seerr/sonarr/
  radarr, but `Etc/UTC` on plex/prowlarr/qbittorrent-vpn. The `media-base` role
  defaults to `Etc/UTC` and the four Chicago hosts override via
  `inventory/host_vars/*.yml` — otherwise `--check` proposes a timezone change on
  those four. Ground-truth `cat /etc/timezone` per host before assuming.

## qbittorrent-vpn — two states + raw config + save-path

- **110 is also managed by the OLD homelab-infra TF.** Capturing it here means two
  states could manage one container. Before applying anything: `terraform state rm`
  it from the OLD side (or retire the old stack). Don't touch old state casually —
  flag and coordinate.
- **Raw `lxc.*` lines don't round-trip.** 110's config carries
  `lxc.cgroup2.devices.allow: c 10:200 rwm` + `lxc.mount.entry: /dev/net dev/net …`
  (the TUN device Gluetun/WireGuard needs). bpg does **not** model raw `lxc.*`
  lines, so they can't live in HCL — they're out-of-band like `features{}`. Import
  ignores them; a plan never proposes them. Leave them on the host.
- **The docker-compose + VPN env are still OLD-repo-owned.** This repo's
  `qbittorrent-vpn` role captures-in-place only: it asserts the three containers
  (gluetun/qbittorrent/qbit-port-sync) are running and that the completed-download
  path is correct — it does **not** template the compose or the Vault-sourced env.
  Full ownership migration is deferred (declined in the PET-47 follow-up).
- **qBittorrent rewrites `qBittorrent.conf` on shutdown.** So you cannot edit the
  conf while qbit is running and expect it to stick — the next stop clobbers it.
  Any config change (e.g. the completed-download path) is **stop → edit → start**,
  never edit-then-restart. The role's correction block follows this and only fires
  on drift, so a captured host `--check`s as a no-op.
- **Completed downloads must save to `/downloads/completed/`, not `/downloads/`.**
  With `Session\DefaultSavePath=/downloads/` (the old value) and empty *arr category
  save_paths, finished torrents landed loose in the `/downloads` root beside the
  `completed/` folder. Fix = `DefaultSavePath`/`Downloads\SavePath` →
  `/downloads/completed/` (TempPath stays `/downloads/incomplete/`); categories
  inherit the default. Applied live 2026-07-14 + captured by the role.
- **VPN secrets go to Vault, not code.** Proton WireGuard key + qBit password →
  `kv/services/media/qbittorrent`. The existing **`ansible`** policy already grants
  `kv/data/services/* read`, so no policy change is needed to consume it — only a
  privileged **seed** (Vault admin token; the AppRoles can only read `services/*`).
  See `docs/runbooks/qbittorrent-vault-secret.md`. Never commit them; never widen a
  policy beyond `services/*` to reach them.

## Ansible reach into the legacy media LXCs

- **The community-script media LXCs had NO ssh key for Ansible.** They predate the
  petedio key convention (root `authorized_keys` was empty). The brownfield import
  doesn't add keys (`user_account` is in `ignore_changes`). Bootstrap was done
  **additively** via pve01 `pct exec` (append `id_ed25519_ansible.pub`, don't
  remove existing access) — `ansible media -m ping` then succeeds for all 7. qbit
  (110) already had keys (it was in the old TF).
- **Capture-in-place Ansible = assert what's already there.** Roles assert the
  running state (timezone UTC, service enabled+running, base pkgs present) so
  `--check` is a clean no-op. They are documentation-as-code of the baseline, NOT
  a reconfiguration. Always `--check` first.

## State / secrets isolation

- This repo uses the **same MinIO** (`.221`) but a **separate state key**
  (`media/terraform.tfstate`) — isolated from petedio-iac's `homelab/...` state.
- Proxmox token + MinIO creds + the LXC ssh key are the **same** Vault values
  petedio-iac uses (`kv/iac/proxmox`, `kv/iac/minio`, `kv/iac/lxc-ssh`). Media-
  SPECIFIC secrets (the VPN creds) are the only net-new Vault material.
