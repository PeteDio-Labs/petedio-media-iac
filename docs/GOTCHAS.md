# GOTCHAS — media stack (petedio-media-iac)

Media-specific hard-won patterns. The general Terraform / bpg-proxmox / Ansible
gotchas live in **`petedio-iac`'s `docs/GOTCHAS.md`** and apply here too — they're
summarized in `CLAUDE.md`. This file adds what's special about the media capture.

## Brownfield import

- **Import is state-only — it never touches the live container.** The whole job is
  to make HCL describe reality so `plan` is a clean no-op. Prove zero-drift on
  `plan` BEFORE any `apply`. An apply against drift could mutate or recreate a
  data-heavy media LXC (Plex library, *arr configs) — unacceptable.
- **Keep the live legacy VMIDs — permanently.** A Proxmox VMID is fixed at creation;
  "renumbering" to the 21x scheme means destroy+recreate. PET-49 is **Canceled**
  (2026-07-21), not deferred: 100/101/103/104/105/109/110 are the permanent numbers,
  and there is no future renumber for a new host to align itself with.
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

## qbittorrent-vpn

- **~~110 is also managed by the OLD homelab-infra TF~~ — RESOLVED 2026-08-11.**
  The dual-state worry (two states managing one container) was verified away rather
  than assumed away: the `tfstate` bucket holds exactly three objects
  (`homelab/terraform.tfstate`, `homelab/vault-config.tfstate`,
  `media/terraform.tfstate`), and `terraform state list` on petedio-iac returns no
  media VMID in 100-110. There was no old side left to `state rm`. This is what
  unblocked `MEDIA_APPLY_ENABLED=true`.
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

## Ansible: update management (added PET-47)

- **`creates:` must guard a path that only exists when the work is done.** The
  seerr upgrade moves the live `config/` (sqlite db) into a freshly-extracted
  source tree. Guarding that move with `creates: <newtree>/config` was wrong:
  **the GitHub source tarball ships its own committed `config/` directory**, so
  the guard was satisfied on arrival, the move silently no-op'd (`ok`, not
  `changed`), the live database was left in the old tree — and the old tree was
  then deleted. Guard a move on its **source** (`removes: <src>`) and explicitly
  delete archive-shipped paths you intend to replace with live state.
- **HTTP 200 is not proof an upgrade worked.** seerr returns 200, reports the new
  version, and logs no errors while serving a brand-new empty database. Any
  upgrade that touches persistent state must assert **the state** (row counts,
  file size above sqlite's 4096-byte empty page) and gate destructive cleanup on
  that assertion — not on a liveness probe.
- **Take the cheap backup even when the design "can't lose data."** The ~500KB
  pre-swap config tarball is the only reason the above was a 4-minute recovery.
- **`media-base` asserted a timezone it never measured.** It set `Etc/UTC`
  claiming it "matches the running media hosts"; in fact lidarr/sonarr/radarr/
  seerr run `America/Chicago`. Because the role had only ever run
  `--limit prowlarr`, the mismatch was invisible until the first stack-wide run
  repointed `/etc/localtime` on four hosts. Per-host reality now lives in
  `host_vars/`, and the role default is inert (empty = don't manage). **A
  `--limit`-scoped role hides its wrong assumptions indefinitely.**
- **`changed=N` on a supposedly read-only run is a defect report** — chase it
  before anything else.
- **Servarr apps update themselves.** sonarr/radarr/lidarr/prowlarr all report
  `packageUpdateMechanism: builtIn`; POST `{"name":"ApplicationUpdate"}` to
  `/api/<v>/command` is the vendor path — do not hand-roll tarball extraction.
  Note the API version split: **sonarr/radarr are v3, lidarr/prowlarr are v1**.
- **Docker Hub rate-limits anonymous pulls (100/6h/IP).** For qbittorrent-vpn
  this breaks *both* the digest check and the pull with HTTP 429. Treat an
  unresolvable remote digest as **unknown, never as up-to-date**. compose aborts
  the pull before recreating anything, so the failure is safe — but it must be
  surfaced. **Fixed 2026-08-11:** all three images now resolve through the homelab
  Nexus pull-through cache (`docker.pdlab.dev`, `qbit_registry` in the role
  defaults), including the `lscr.io` one, which is not Hub-capped but benefits from
  the same locality. The cache is on-demand — the first pull of a tag still fetches
  from upstream.
- **Plex has no in-app updater on Linux server builds** — apt is the mechanism.
  The host also carried a stale second Plex repo (`plex.list` →
  `downloads.plex.tv`, pinned to the 1.42.2 line) alongside the current
  `plexmediaserver.sources` (`repo.plex.tv`). Harmless while apt picks the
  highest version, but a downgrade footgun. Removed via
  `media_base_stale_apt_sources`.
- **Comparing the wrong two digests marks every multi-arch image "behind".**
  `docker image inspect .RepoDigests` holds the **manifest-LIST** digest (what
  `docker pull` resolved for a floating tag). `docker manifest inspect -v`
  returns one entry **per platform** — its `Descriptor.digest` is a per-platform
  manifest digest, plus (on modern builds) two `unknown/unknown` attestation
  entries. The two values can never be equal, so the naive comparison reports a
  permanent false "update available" — verified: `alpine:3.20`, untouched for
  months, read as behind until this was fixed. Read the remote side from the
  registry's `Docker-Content-Digest` header (anonymous token → `HEAD
  /v2/<repo>/manifests/<tag>` with the index media types in `Accept`); that is
  exactly what `RepoDigests` stores.
- **`--no-deps` is wrong for gluetun.** qbittorrent and port-sync use
  `network_mode: service:gluetun`, so they live *inside* gluetun's network
  namespace. Recreating gluetun creates a NEW namespace and strands anything
  still pointed at the old one (running, but with no network). A gluetun update
  must recreate its dependents too; `--no-deps` is only correct for the other
  services, where it avoids dropping the tunnel just to restart qBittorrent.
  Always verify after: host egress and in-tunnel egress must be **different**
  IPs (leak check), and both tunnel containers must report the same one.
- **Pull per service, not per stack.** `docker compose pull` with no arguments
  pulls everything, so a rate-limited image that is already current aborts the
  update of an image that genuinely needs it — on a different, unthrottled
  registry. Pull only the services the digest check flagged.

## The in-use guards fail open (found 2026-08-13 — OPEN, not fixed)

`roles/media-lifecycle` is what stops `stack-down.yml` killing a live Plex stream
or an active torrent. **Both guards treat "I could not determine the state" as
"not in use"** — so a broken credential does not block a stop, it authorizes one.

`in-use-plex.yml` is the sharper of the two, because it never checks the status
code at all:

```yaml
media_in_use: >-
  {{ ((lifecycle_plex_sessions.content | default('')
       | regex_search('size="(\d+)"', '\1') | first | default('0')) | int) > 0 }}
```

With `failed_when: false` on the request, *any* failure — rotated token, 401,
connection refused, Plex mid-restart — yields empty content → `default('0')` →
`media_in_use: false`. The role's own comment says stopping Plex mid-stream "kills
the playback and any in-flight transcode", so the consequence is understood; it is
the detection that is unsound. `in-use-qbittorrent-vpn.yml` has the same shape,
guarded slightly better by `if status == 200 else false` — but `false` is still the
else branch, so a `403` reads as "nothing downloading".

**This is live today.** qBittorrent's WebUI auth is broken (the `.env` password no
longer authenticates — see [DASHBOARD-CAPABILITIES.md](DASHBOARD-CAPABILITIES.md)
§ qBittorrent WebUI API), so that guard is currently blind and silently permissive.

The fix is to fail **closed**: an undeterminable state should refuse the stop and
say why, leaving `-e media_lifecycle_force=true` as the deliberate override — which
is exactly what that override exists for. It is deliberately **not** applied yet:
flipping it while qBit auth is broken would immediately start blocking qBittorrent
stops, and that is an operator's call to make knowingly.

Same family as the seerr `creates:` incident and the `media-base` timezone
assumption above, and the general rule is the one those earned: **a check that
cannot fail loudly is not a check.** When a guard's whole job is to withhold
permission, "unknown" must resolve to *no*, never to *yes*.
