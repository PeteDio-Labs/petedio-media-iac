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
  on **both nodes** — or better, `pvesh get /cluster/resources --type vm`, which is
  the only view that shows placement — before trusting any inventory. It drifted
  again after PET-334 moved the platform tier, and `vault/Hosts/hosts-inventory.md`
  carried the pre-move tables under a `status: live` header until PET-354.

## Per-host shape (the variances that bite)

- **rootfs datastore varies by node:** `local-lvm` (thin) on pve02 for 110 and 236,
  the plain `local` directory store on pve03 for 101/102/104/105/109 — pve03 has no
  thin pool. The module's `datastore_id` must match per host or plan shows drift.
  (`sdb3-storage` was pve01's and died with it.)
- **~~plex (103) is DUAL-HOMED~~ — GONE.** 103 died with pve01 on 2026-09-03 and
  was not rebuilt. Its replacement, plex-gpu (236) on pve02, is single-homed on
  `192.168.50.236` because pve02 has one NIC on `.50`; the TVs on the `.86` mesh
  reach it over the tailnet (`100.97.96.88`) or the pete-pi-1 proxy, not over a
  second NIC. The module's `net1_*` vars now have no consumer in this repo.
- **seerr (101) is odd:** its only NIC is **eth1** (not eth0), firewall on, and it
  has **no bind-mounts**. Capture exactly that — don't assume eth0.
- **Bind-mount target paths differ per container:** `/mnt/media` vs `/media`,
  `/downloads` vs `/mnt/downloads`. They're host-dir bind-mounts of the shared
  `/mnt/media` + `/mnt/downloads`. Those paths live on **pve02** now, as ZFS pools
  (`media` RAIDZ1, `downloads` single SSD), and pve03 sees them over NFS at the
  SAME paths — which is exactly what let PET-334 move guests between nodes without
  editing a single mount. Encode each host's actual target path.
- **Firewall flag:** on for plex, seerr, qbittorrent-vpn; off for the rest.

## qbittorrent-vpn

- **~~110 is also managed by the OLD homelab-infra TF~~ — RESOLVED 2026-08-11.**
  The dual-state worry (two states managing one container) was verified away rather
  than assumed away: the `tfstate` bucket holds exactly three objects
  (`homelab/terraform.tfstate`, `homelab/vault-config.tfstate`,
  `media/terraform.tfstate`), and `terraform state list` on petedio-iac returns no
  media VMID in 100-110. There was no old side left to `state rm`. This is what
  unblocked `MEDIA_APPLY_ENABLED=true`.
- **VPN secrets go to Vault, not code** — but the secret set is smaller than it
  looks. Only the **Proton WireGuard key + addresses** belong in
  `kv/services/media/qbittorrent`. `QBIT_WEBUI_PASSWORD` from `.env` must **not** be
  seeded: qBittorrent has no WebUI password configured at all (0 hits for both
  `WebUI\Password` and `WebUI\Username` in `qBittorrent.conf`), so it is a phantom
  that matches nothing and only earns hour-long IP bans. Seeding it would give a
  non-credential the appearance of a credential.
  The existing **`ansible`** policy already grants `kv/data/services/* read`, so no
  policy change is needed to consume it — only a privileged **seed** (Vault admin
  token; the AppRoles can only read `services/*`). Never commit them; never widen a
  policy beyond `services/*` to reach them.
- **Two paths existed for this one secret — resolved 2026-08-13 by reading Vault.**
  `kv/services/qbittorrent` (seeded by `iac/scripts/vault-seed.sh`) holds
  `username` + `password` and **nothing else** — i.e. only the phantom credential,
  no Proton key. `kv/services/media/qbittorrent` is **empty**. So the real secret,
  the Proton WireGuard key, has never been in Vault at all: it lives only in
  `/opt/qbittorrent-vpn/.env` on 110, which is its sole copy. Seed the
  Proton key at the `services/media/*` path, delete `kv/services/qbittorrent`, and
  drop its block from `iac`'s seed script or it will keep being recreated. See
  `docs/runbooks/qbittorrent-vault-secret.md`.

## Ansible reach into the legacy media LXCs

- **The community-script media LXCs had NO ssh key for Ansible.** They predate the
  petedio key convention (root `authorized_keys` was empty). The brownfield import
  doesn't add keys (`user_account` is in `ignore_changes`). Bootstrap was done
  **additively** via `pct exec` on the guest's node (append `id_ed25519_ansible.pub`,
  don't remove existing access) — `ansible media:gpu-media -m ping` then succeeds for
  all 6. qbit (110) already had keys (it was in the old TF). Re-verified 2026-09-06:
  all six answer `pong`.
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
  pre-swap config tarball is the only reason the seerr swap was a 4-minute recovery.
- **`media-base` asserted a timezone it never measured.** It set `Etc/UTC`
  claiming it "matches the running media hosts"; in fact lidarr/sonarr/radarr/
  seerr run `America/Chicago`. Because the role had only ever run
  `--limit prowlarr`, the mismatch was invisible until the first stack-wide run
  repointed `/etc/localtime` on four hosts. Per-host reality lives in
  `host_vars/`, and the role default is inert (empty = don't manage). **A
  `--limit`-scoped role hides its wrong assumptions indefinitely.**
- **`changed=N` on a supposedly read-only run is a defect report** — chase it
  before anything else.
- **Servarr apps update themselves.** sonarr/radarr/prowlarr all report
  `packageUpdateMechanism: builtIn`; POST `{"name":"ApplicationUpdate"}` to
  `/api/<v>/command` is the vendor path — do not hand-roll tarball extraction.
  Note the API version split: **sonarr/radarr are v3, prowlarr is v1**. Lidarr was
  the fourth app here and the other v1; it went with LXC 100 in PET-319, so a loop
  over "the four *arrs" now over-counts by one.
- **Docker Hub rate-limits anonymous pulls (100/6h/IP).** For qbittorrent-vpn
  this breaks *both* the digest check and the pull with HTTP 429. Treat an
  unresolvable remote digest as **unknown, never as up-to-date**. compose aborts
  the pull before recreating anything, so the failure is safe — but it must be
  surfaced. A homelab Zot pull-through cache held all three images from 2026-08-11
  until registry-106 died with pve01 on 2026-09-03; its blob store is gone (PET-389).
  The `qbit_registry` prefix stayed in the role defaults for another thirteen days,
  naming a registry that answered nothing. PET-448 repointed each image at its own
  registry, and there is no shared prefix any more.
- **A check that cannot read must not report "nothing outdated".** Through those
  thirteen days the qbittorrent-vpn digest step marked every image `unknown` and
  still set `update_available: false`, because the only thing that set it true was
  the outdated list being non-empty. Nothing separated "checked, all current" from
  "checked nothing". The role now fails when NO row resolved, while still tolerating
  a 429 on a single image (PET-448).
- **Read a registry's auth realm from the manifest request, not from `/v2/`.**
  `lscr.io` is a redirector in front of ghcr.io: `/v2/` answers **405 with no
  `www-authenticate` header**, while the manifest request answers 401 and names
  `realm="https://ghcr.io/token"`. `image-digests.sh` asked `/v2/`, so it took no
  token for qBittorrent, sent the manifest request unauthenticated, got 401 back and
  printed `unknown` — on every run since the script was written, cache or no cache.
  It was read as lscr.io's burst limiter for months. It was not (PET-448). Measured:
  with the realm taken from the manifest's own 401, the same function returns
  `sha256:2be038f3421f…` for `lscr.io/linuxserver/qbittorrent:latest`.
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

## The in-use guards could not say "I could not tell" (found 2026-08-13, fixed in `fdc8c8c`)

> **Fixed.** Both guards carry three states — `in-use`, `idle`, `unknown` — and
> `roles/media-lifecycle/tasks/main.yml` **fails the stop** on `unknown` unless you
> pass `-e media_lifecycle_force=true`. `fdc8c8c` landed that together with the
> qBittorrent reachability fix, in that order deliberately (see the end of this
> section). The diagnosis below is kept because it is how the failure class was
> found, and because the same shape recurs: read it as history, not as live state.
>
> The open lifecycle bug is a **different** one — PET-447, where the guard never ran
> on plex-gpu at all, because the host key that selected it named a host PET-354 had
> deleted.

`roles/media-lifecycle` is what stops `stack-down.yml` killing a live Plex stream
or an active torrent. As found, **neither guard could distinguish "nothing is in
use" from "I could not tell"** — and they failed in two different ways, which is
the part worth keeping.

**qBittorrent failed open, silently.** The `in-use-qbittorrent-vpn.yml` of the day:

```yaml
media_in_use: >-
  {{ ((lifecycle_qbit_active.json | default([]) | length) > 0)
     if (lifecycle_qbit_active.status | default(0)) == 200 else false }}
```

`false` is the else branch, so the `403` that call actually returned (next section)
read as "nothing downloading" and the stop proceeded. Confirmed live at the time.
The replacement asks a narrower question — did the call return a JSON array at all?
— and everything else resolves to `unknown`.

**Plex did not fail open — it crashed.** An earlier draft of this section claimed
it did, reasoning that empty content would fall through to `default('0')`. Testing
it says otherwise. On the ansible-core in use here (2.20.4), `regex_search` with a
capture group returns **`None`** on no match, and `None | first` raises before
`default('0')` can apply:

```
The filter plugin 'ansible.builtin.first' failed: 'NoneType' object is not iterable
```

Verified against both failure shapes — empty content (unreachable) and a body with
no `size` attribute (a 401 page). So a broken Plex guard aborted the play rather than
quietly authorising a stop: loud, but not a working guard, and with no way to say "in
use" when it could not see. `or ['']` between `regex_search` and `first` is the fix,
and the rewrite inherited exactly this crash until a bogus-port test caught it.

**The qBittorrent guard had never worked, and that was not a regression.**
`host_vars/qbittorrent-vpn.yml` set `qbit_api: "http://localhost:8080"`, Ansible's
`uri` module runs on the target host, and a host-origin request to that port is
refused by qBittorrent for the reason in the next section. The guard had been getting
`Forbidden` since the compose stack was built. **Collapsing "cannot tell" into "not
in use" is precisely what kept that invisible** — a guard that said "cannot
determine" out loud would have surfaced it the first time it ran.

The fix was to fail **closed**: an undeterminable state refuses the stop and says
why, leaving `-e media_lifecycle_force=true` as the deliberate override — which is
exactly what that override exists for.

**It shipped with the reachability fix, in one commit, and the order was the reason.**
Failing closed while qBit's guard still could not see anything would have blocked
every qBittorrent stop from the moment it merged. So `fdc8c8c` moved the probe to
`docker exec {{ qbit_container }} curl` inside gluetun's netns *and* made `unknown`
refuse, together.

Same family as the seerr `creates:` incident and the `media-base` timezone
assumption, and the general rule is the one those earned: **a check that
cannot fail loudly is not a check.** When a guard's whole job is to withhold
permission, "unknown" must resolve to *no*, never to *yes*.

PET-447 is the sequel worth reading next to this one. Both guards now answer
correctly, and on plex-gpu neither was being asked.

## A guard is only testable if its decision has no I/O in it (found 2026-09-16)

`ansible/tests/` holds recorded-answer tests for the three guards above, and the
`ansible-tests` workflow runs every `tests/*.yml` on a GitHub-hosted runner for
each pull request and each push to `main`. Every play sets `connection: local`
and `become: false`, so the suite contacts no media host and needs no secret.

To run it yourself:

```sh
cd ansible
ansible-playbook -i inventory/hosts.yml tests/media-lifecycle-plex-probe.yml
```

**The seam is what makes the tests possible.** A guard splits into two files: one
that collects answers and one that decides from them.

| File | Contains | Example |
|---|---|---|
| the probe | every task that talks to a host | `roles/media-lifecycle/tasks/in-use-plex.yml` |
| the classifier | `set_fact` only, no I/O | `roles/media-lifecycle/tasks/classify-plex.yml` |

A test sets the registers the probe would have collected, includes the classifier,
and asserts the verdict. That reaches the answers a live host never produces on
demand: a 403, a refused connection, a 200 carrying the wrong document. **Those
are the answers a guard exists for**, so a guard whose decision sits inline
between two I/O tasks is untested by construction, however carefully it is
written.

Two working rules follow:

- **Write the classification into its own file** when you add a guard. Put every
  task that touches a host before the `include_tasks` that ends the probe, and
  gate each one with an inline `when:` on a register.
- **Set `check_mode: false` on every collecting task.** `ansible.builtin.uri`
  does not support check mode, so without it a `--check` run skips the task, the
  register carries no `status`, and the classifier correctly returns `unknown` —
  which refuses the stop. A rehearsal that cannot rehearse the stop is not a
  rehearsal.

Per-case task lists live in `tests/cases/`, not beside the drivers.
`ansible-playbook` on a task list fails with *playbook must be a list of plays*,
and the CI job globs `tests/*.yml`.

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

**And the allowlist is unreachable from the host.** qBittorrent shares gluetun's
netns; the WebUI is published `8080:8080` on the `qbittorrent-vpn_default` bridge
(gluetun `172.18.0.2`, gateway `172.18.0.1`). A request **originating on LXC 110** to
`localhost:8080` is SNAT'd to `172.18.0.1` before qBittorrent sees a source address —
which matches neither allowlist entry. It is refused every time:

```sh
curl localhost:8080/api/v2/app/version            # -> Forbidden   (always)
docker exec qbittorrent curl localhost:8080/…     # -> v5.2.3      (always)
```

Inside the namespace the source genuinely is `127.0.0.1`. That is why the container's
own healthcheck has read `healthy` throughout — **the healthcheck and anything on the
host were never testing the same path.**

Two traps this sets:

- **`Forbidden` is ambiguous.** It is the answer for a non-allowlisted source *and*
  for a banned IP; only `/auth/login` ever says "banned". So a ban and this DNAT
  problem look identical from the host, and "wait out the ban" (66 minutes of it)
  proves nothing. Diagnose by comparing the in-namespace path, not by retrying.
- **Never "fix" this by adding a password or by retrying the login.** The failure is
  the source address, not the credential. Anything on LXC 110 that needs this API
  should use `docker exec` (what `scripts/api-capability-probe.sh` does). A LAN-origin
  request from another host would be covered by `192.168.50.0/24`, since Docker
  preserves the source IP for non-local traffic — but the host's own loopback is not.
