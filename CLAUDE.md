# petedio-media-iac (Agent Context)

Terraform + Ansible for the homelab **media stack**, brought under IaC by
**brownfield capture** — import the running LXCs as-is, **no rebuild, no data
loss, no downtime**. Split out from `petedio-iac` so media has its own MinIO
state object (`media/terraform.tfstate`) and its own Vault secret scope.

> Part of the PeteDio homelab→AWS platform. The parent workspace
> (`petedio-workspace`) holds the cross-repo context; the canonical infra
> reference is **`vault/Hosts/hosts-inventory.md`**.
> Tracker: **Plane** (workspace `petedio`, project `PET`). ⚠ **Linear was retired
> 2026-08-13** — read-only history, do not write to it, and its inventory doc is
> stranded and drifting. Prefer the vault for anything it used to answer.

## The vault is the knowledge base — read it before planning

Operational substance for this stack lives in the **`petedio-vault`** repo
(private, `PeteDio-Labs/petedio-vault`, cloned at `~/petedio/vault`), an
Obsidian-readable markdown vault. **This repo holds the code; the vault holds why
it is that way and what broke.** Order of authority is
**live infra > the vault > Plane** — `pct list` wins over any document, this
file included.

Start here for media work:

| Note | What it saves you |
|---|---|
| `Systems/media-stack.md` | The stack overview, and the corrected VMID→role→IP truth |
| `Hosts/hosts-inventory.md` | Ground-truthed host table; per-host notes are `Hosts/<vmid>-<name>.md` |
| `Practices/downloads-and-torrents.md` | The 196 GiB staging volume, why a full `/downloads` deadlocks rather than drains, share limits, replacing a bad library copy |
| `Practices/indexers-and-fake-releases.md` | Fake `.exe` releases, why title filtering cannot catch them, and the indexer-coverage failure that followed |
| `Practices/ssh-keys-two-hops.md` | Which key gets you where |

⚠ **A large amount of live media behaviour is configured through app APIs and
exists nowhere in git** — Prowlarr's indexer set (enable/disable, priority,
minimum seeders), qBittorrent's share limits and `preallocate_all`, Sonarr's
quality profiles, the VPN exit country. Ansible does **not** manage any of it.
This is a real drift class: a rebuild silently restores old behaviour, and the
only record that a setting was ever chosen deliberately is the vault note. When
you change one of these live, write it down there — nothing else will.

Vault conventions (its own `CLAUDE.md` governs): globally-unique note names,
filename-only `[[wikilinks]]`, frontmatter with a `verified:` date, and
`./scripts/audit.sh` must pass before you finish. Obsidian Git auto-commits and
**pushes every 10 minutes**, so never leave it half-edited.

## Where the work stands (Linear-era record, verified 2026-08-13)

The capture is **done**. Terraform and Ansible both describe live reality, and
apply-on-merge is on.

| Issue | | Status |
|---|---|---|
| PET-46 | Import the running media LXCs (zero-drift) | **Done** |
| PET-47 | Ansible to match running host config | **Done** |
| PET-53 | Decide media LXC topology | **Done** |
| PET-114 | CI: vault-action v3→v4 | **Done** |
| PET-163 | Keep PR code off the self-hosted runner | **Done** |
| PET-48 | Document media data volumes / prove no-data-loss | **In Review** — the only live one |
| PET-49 | Renumber media → 21x | **Canceled** |
| PET-81 | Anime add-on | **Canceled** |

Also landed from the Platform project: **PET-56** (media LXCs into the cluster
resource pool, `pool.tf`) and **PET-82** (filebrowser 102 decommissioned).

⚠ **PET-48 is the loose thread.** It is In Review against **PR #3**, open since
2026-07-14 and long superseded by the merged #4–#7. Read it before trusting it;
it wants closing or rebasing, not merging.

The `PET-<n>` numbers above are **Linear-era** and resolve only in that retired,
read-only workspace. Tracking moved to **Plane** on 2026-08-13; the four issues
open at cutover were deliberately not migrated. The old free-plan cap that forced
new work into PR descriptions no longer applies — file it in Plane instead.

## Golden rules (this repo)

1. **Capture in place.** The job is reproducibility-as-code, not migration. Import
   each LXC, iterate HCL until `terraform plan` is a **clean no-op (zero drift)**.
   **Never `apply` against drift** — it could mutate/recreate a data-heavy container.
   This matters more now: `MEDIA_APPLY_ENABLED=true` since 2026-08-11, so a merge
   really does apply.
2. **VMIDs are the live legacy numbers** (100/101/103/104/105/109/110) and they are
   **permanent**. PET-49 is Canceled, not deferred — there is no future renumber, so
   don't design anything (new hosts included) around a 21x scheme arriving later.
3. **Ground-truth before you trust docs.** The old Linear inventory doc was wrong
   about media VMID→role→IP (corrected 2026-06-04); it is now stranded in the
   retired workspace and drifting further, so prefer `vault/Hosts/hosts-inventory.md`.
   Always `ssh root@192.168.50.10 'pct list && pct config <id>'` to confirm before
   editing HCL. Same rule applies to this file.
4. **Secrets in Vault, never in code.** qBittorrent's **Proton WireGuard key +
   addresses** go to `kv/services/media/qbittorrent`, read by a media-scoped policy —
   not committed, not in the shared `ansible` policy. Seed still pending;
   `/opt/qbittorrent-vpn/.env` remains unmanaged.
   Two traps here: `QBIT_WEBUI_PASSWORD` is a **phantom** and must not be seeded
   (qBittorrent has no WebUI password at all — the subnet whitelist is the auth), and
   the same secret is documented at **two paths** — `iac`'s seed script already
   populated `kv/services/qbittorrent`. Resolve before seeding; see
   `docs/runbooks/qbittorrent-vault-secret.md`.

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
qbittorrent-vpn 110/.21 (Gluetun/Proton). **filebrowser 102 is gone** — decommissioned
under PET-82.

The old "110 is also in the retired homelab-infra TF — reconcile" caveat is
**resolved** (2026-08-11): the `tfstate` bucket holds exactly three objects and
petedio-iac's state lists no media VMID. There was no old side left to `state rm`.

## Ansible layer (PET-47, landed)

Roles: `media-base` (baseline) · `servarr` (one parametrised role for
sonarr/radarr/lidarr/prowlarr) · `plex` (apt) · `seerr` (build from source) ·
`qbittorrent-vpn` (gluetun/qbit compose, **now templated in-repo**, all images
pulled through the `docker.pdlab.dev` Nexus cache) · `media-lifecycle` (in-use
guards + ordered stop/start).

Playbooks: `check-updates.yml` (read-only report) · `update-media.yml` ·
`stack-up.yml` / `stack-down.yml` / `stack-power.yml` · `configure-media.yml`.
`media-roles.yml` is the shared play body both update entry points import, so a
dry-run and an apply exercise the same code.

**Read `docs/GOTCHAS.md` before touching a role.** Three live traps:

- Every role that asserts a baseline must **measure** it first — the `media-base`
  timezone incident silently converted four hosts.
- The `media-lifecycle` in-use guards cannot express **"I could not tell"**. qBit's
  fails open (a `403` reads as "nothing downloading"); Plex's crashes on the same
  class of failure. Open bug, not a design.
- **qBittorrent's API is unreachable from LXC 110's own host.** It has no WebUI
  password (the `.env` one is a phantom that only earns hour-long IP bans), and its
  subnet whitelist can't match a host-origin request because Docker SNATs it to the
  bridge gateway. Use `docker exec qbittorrent curl …`. This is why the qBittorrent
  in-use guard has never worked.

## Runtime / tooling

- **Terraform** for the LXCs; **Ansible** for host/service config. SSH: Proxmox
  host hop = `id_ed25519_proxmox_pedro`; into the LXCs = `id_ed25519_ansible`.
- State in MinIO (`.221`, bucket `tfstate`, key `media/terraform.tfstate`).
  **No locking** — single operator, never concurrent applies. CI serializes on a
  `tf-media` concurrency group.
- Scripts are kept **bash 3.2-compatible** — `/usr/bin/env bash` on the Mac these
  run from is 3.2.57, so no `declare -A`, no `mapfile`, no `${var,,}`.

## CI — Workflow B, split by trust (PET-163)

Two jobs, and the split is the security boundary. This repo is **public** and the
apply runner is **self-hosted inside the homelab**:

- **`validate`** — runs on PR *and* push. GitHub-hosted, ephemeral, **no Vault, no
  LAN, no state**: `fmt` + `init -backend=false` + `validate`.
- **`apply`** — push to `main` only. Self-hosted; the only job that mints `media-ci`
  creds via Vault OIDC and touches state. Gated behind `MEDIA_APPLY_ENABLED`
  (**`true` since 2026-08-11**).

**PRs do NOT get a `terraform plan` comment.** A real plan needs the LAN backend and
provider creds that are deliberately withheld from PR runs. The authoritative plan is
the operator's local one, or the apply-on-merge log — do not describe the PR plan as
the review surface.

`push` is filtered with `paths-ignore` (docs, scripts, ansible, `**/*.md`) so a
docs-only merge can't mint credentials on the homelab runner. `pull_request` is
deliberately **unfiltered** so `validate` always reports.

**Vault seals on every reboot of `.223`** and is unsealed by hand from the password
manager. A sealed Vault fails the apply job at the preflight step with a message
saying so; CI cannot fix it.

## Workflow

Branch `pet-<n>-<slug>` → PR → **squash-merge** (which applies). Mention `PET-<n>`
in the PR. Keep the **Plane** work item updated as work proceeds — Linear is
retired and must not be written to. Pedro is the only merger.
