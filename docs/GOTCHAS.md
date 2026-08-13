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

## The in-use guards cannot say "I could not tell" (found 2026-08-13)

`roles/media-lifecycle` is what stops `stack-down.yml` killing a live Plex stream
or an active torrent. **Neither guard can distinguish "nothing is in use" from "I
could not tell"** — but they fail in two different ways, and the difference is
worth knowing before you go looking.

**qBittorrent fails open, silently.** `in-use-qbittorrent-vpn.yml`:

```yaml
media_in_use: >-
  {{ ((lifecycle_qbit_active.json | default([]) | length) > 0)
     if (lifecycle_qbit_active.status | default(0)) == 200 else false }}
```

`false` is the else branch, so the `403` this call actually returns (next section)
reads as "nothing downloading" and the stop proceeds. Confirmed live.

**Plex does not fail open — it crashes.** An earlier draft of this section claimed
it did, reasoning that empty content would fall through to `default('0')`. Testing
it says otherwise. On the ansible-core in use here (2.20.4), `regex_search` with a
capture group returns **`None`** on no match, and `None | first` raises before
`default('0')` can apply:

```
The filter plugin 'ansible.builtin.first' failed: 'NoneType' object is not iterable
```

Verified against both failure shapes — empty content (unreachable) and a body with
no `size` attribute (a 401 page). So a broken Plex guard aborts the play rather than
quietly authorising a stop. Loud, but still not a working guard, and still no way to
say "in use" when it cannot see. (The rewrite inherited exactly this crash until a
bogus-port test caught it — `or ['']` between `regex_search` and `first` is the fix.)

**This is live today, and it is not a regression — the qBittorrent guard has never
worked.** `host_vars/qbittorrent-vpn.yml` sets `qbit_api: "http://localhost:8080"`,
Ansible's `uri` module runs on the target host, and a host-origin request to that port
is refused by qBittorrent for the reason in the next section. The guard has been
getting `Forbidden` since the compose stack was built. **Collapsing "cannot tell"
into "not in use" is precisely what kept that invisible** — a guard that said
"cannot determine" out loud would have surfaced this the first time it ran.

The fix is to fail **closed**: an undeterminable state should refuse the stop and
say why, leaving `-e media_lifecycle_force=true` as the deliberate override — which
is exactly what that override exists for.

That fix is **not in this PR**; it is in the follow-up that also repairs the
qBittorrent reachability, and the order matters. Failing closed while qBit's guard
still cannot see anything would block every qBittorrent stop from the moment it
merged — so the reachability fix has to land with it, not after it.

Same family as the seerr `creates:` incident and the `media-base` timezone
assumption above, and the general rule is the one those earned: **a check that
cannot fail loudly is not a check.** When a guard's whole job is to withhold
permission, "unknown" must resolve to *no*, never to *yes*.

## qBittorrent's WebUI cannot be reached from LXC 110's own host (found 2026-08-13)

There is **no `WebUI\Password_PBKDF2` and no `WebUI\Username`** in `qBittorrent.conf`.
qBittorrent has no WebUI password; access control is entirely:

```
WebUI\AuthSubnetWhitelist=127.0.0.1/32, 192.168.50.0/24
WebUI\AuthSubnetWhitelistEnabled=true
```

So `QBIT_WEBUI_PASSWORD` in `/opt/qbittorrent-vpn/.env` is a **phantom credential** —
nothing matches it, a login with it can never succeed, and five attempts ban the
source IP for an hour (`WebUI\MaxAuthenticationFailCount`, default 5).

**And the whitelist is unreachable from the host.** qBittorrent shares gluetun's
netns; the WebUI is published `8080:8080` on the `qbittorrent-vpn_default` bridge
(gluetun `172.18.0.2`, gateway `172.18.0.1`). A request **originating on LXC 110** to
`localhost:8080` is SNAT'd to `172.18.0.1` before qBittorrent sees a source address —
which matches neither whitelist entry. It is refused every time:

```sh
curl localhost:8080/api/v2/app/version            # -> Forbidden   (always)
docker exec qbittorrent curl localhost:8080/…     # -> v5.2.3      (always)
```

Inside the namespace the source genuinely is `127.0.0.1`. That is why the container's
own healthcheck has read `healthy` throughout — **the healthcheck and anything on the
host were never testing the same path.**

Two traps this sets:

- **`Forbidden` is ambiguous.** It is the answer for a non-whitelisted source *and*
  for a banned IP; only `/auth/login` ever says "banned". So a ban and this DNAT
  problem look identical from the host, and "wait out the ban" (66 minutes of it)
  proves nothing. Diagnose by comparing the in-namespace path, not by retrying.
- **Never "fix" this by adding a password or by retrying the login.** The failure is
  the source address, not the credential. Anything on LXC 110 that needs this API
  should use `docker exec` (what `scripts/api-capability-probe.sh` does). A LAN-origin
  request from another host would be covered by `192.168.50.0/24`, since Docker
  preserves the source IP for non-local traffic — but the host's own loopback is not.
