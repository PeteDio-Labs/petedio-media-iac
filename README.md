# petedio-media-iac

Terraform + Ansible for the homelab **media stack** — brought under IaC by
**brownfield capture** (import the running LXCs as-is; no rebuild, no data loss,
no downtime). Split out from [`petedio-iac`](https://github.com/PeteDio-Labs/petedio-iac)
so the media stack gets its own state object and its own Vault secret scope.

Part of the PeteDio homelab→AWS platform. Tracker: Linear project **Media Stack**
(milestone *Brownfield Capture*).

**The capture is complete** — PET-46 (import), PET-47 (Ansible), PET-53 (topology),
PET-114 and PET-163 (CI) are all Done, the media LXCs are in the cluster resource
pool (PET-56), and apply-on-merge has been enabled since 2026-08-11. PET-48
(data-volume documentation) is the one issue still open; PET-49 (renumber to 21x)
was **canceled**, so the legacy VMIDs are permanent.

## What's here

```
modules/proxmox-lxc/        # reusable Debian LXC (copied from petedio-iac;
                            #   extended: optional 2nd NIC, bind-mounts, per-host firewall)
environments/media/         # the media environment
  backend.tf                #   MinIO S3 state, key = media/terraform.tfstate
  providers.tf              #   bpg/proxmox only
  variables.tf              #   proxmox endpoint/token, ssh_public_key
  media.tf                  #   one module block per running LXC (ground-truthed)
  terraform.tfvars.example  #   template (real tfvars is gitignored)
ansible/                    # host config + update management (idempotent)
  inventory/hosts.yml       #   `media` (all) + `servarr` (the four *arr apps)
  inventory/host_vars/      #   per-host captured reality (timezone, API version)
  roles/media-base/         #   baseline shared by every media LXC
  roles/servarr/            #   ONE role for sonarr/radarr/lidarr/prowlarr
  roles/plex/               #   apt-managed Plex
  roles/seerr/              #   build-from-source seerr
  roles/qbittorrent-vpn/    #   the gluetun/qbittorrent compose stack (templated)
  roles/media-lifecycle/    #   in-use guards + ordered stop/start
  playbooks/media-roles.yml #   shared play body (both entry points import it)
scripts/                    # api-capability-probe.sh — read-only API ground-truthing
docs/GOTCHAS.md             # media-specific gotchas (+ pointer to petedio-iac's)
docs/ARCHITECTURE.md        # live mapping, with a Mermaid diagram
docs/DASHBOARD-*.md         # design review for a media triage tool (no code yet)
docs/runbooks/              # CI Vault-OIDC, qBittorrent Vault secret
.github/workflows/          # Workflow B — validate-on-PR (hosted), apply-on-merge (self-hosted)
```

## Update management

Every service reports its version and updates through its own vendor-supported
path. One shared play body backs both entry points, so what you dry-run is
exactly what applies.

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml playbooks/check-updates.yml   # read-only report
ansible-playbook -i inventory/hosts.yml playbooks/update-media.yml    # apply
ansible-playbook -i inventory/hosts.yml playbooks/update-media.yml --limit radarr
```

| Service | Mechanism | Notes |
|---|---|---|
| sonarr / radarr / lidarr / prowlarr | the app's own `builtIn` updater, over its REST API | one `servarr` role; verifies it returns on the target version |
| plex | apt (`repo.plex.tv`) | skips while anyone is watching |
| seerr | GitHub source tag + `pnpm build` | opt-in; atomic tree swap with rollback |
| qbittorrent-vpn | `docker compose pull` | skips while torrents are downloading; verifies VPN egress after |

Guards are skip-not-fail, each with an override: `-e plex_update_force=true`,
`-e qbit_update_force=true`, `-e seerr_update_enabled=true`.

## Bringing the stack up and down

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml playbooks/stack-down.yml          # stop services
ansible-playbook -i inventory/hosts.yml playbooks/stack-up.yml            # start + verify
ansible-playbook -i inventory/hosts.yml playbooks/stack-power.yml -e power=off   # LXCs off too
ansible-playbook -i inventory/hosts.yml playbooks/stack-power.yml -e power=on
```

Ordering is dependency-aware, consumers before producers on the way down and
the exact reverse coming up:

```
down:  plex, seerr  →  sonarr, radarr, lidarr  →  prowlarr  →  qbittorrent-vpn
up:    qbittorrent-vpn  →  prowlarr  →  sonarr, radarr, lidarr  →  seerr, plex
```

Each tier waits for its port to actually accept connections before the next
starts — "systemd says active" is not "serving", and Lidarr runs a DB migration
before it binds (hence its longer `media_health_timeout`).

Plex and qBittorrent **refuse to stop while in use** (someone watching, something
downloading) and say why; override with `-e media_lifecycle_force=true`.

`stack-up.yml` ends by asserting the qBittorrent tunnel egress **differs from the
host's** — a leak check that runs every single time the stack comes up, rather
than something you have to remember to do.

`stack-power.yml -e power=off` runs the graceful service shutdown *first*: pulling
an LXC out from under a live Plex transcode or an active torrent is how library
databases get corrupted. Run-state is deliberately **not** in Terraform — the
module keeps `started` in `lifecycle.ignore_changes`, because CI applies on merge
and an unrelated merge should never boot the stack back up.

**Registry rate limits — fixed 2026-08-11.** Two of the three qbittorrent-vpn
images come from `docker.io`, which caps anonymous pulls (100/6h per IP); `lscr.io`
throttles bursts too. All three now resolve through the homelab Nexus pull-through
cache (`docker.pdlab.dev`, see `qbit_registry` in the role defaults), which removes
the cap from the normal path. The cache is on-demand, so the first pull of a new tag
still fetches upstream and can still be throttled — the handling for that stays:
the digest check reports an unresolvable image as `NOT CHECKED` rather than
pretending it is current, and pulls are done **per service**, so one
throttled-but-current image can't block updating a different one that is genuinely
stale.

**Two things the qbittorrent-vpn role gets right that are easy to get wrong:**

- *Digest comparison.* `docker image inspect .RepoDigests` records the
  **manifest-list** digest, while `docker manifest inspect -v` returns one entry
  **per platform**. Those are structurally different values, so comparing them —
  the obvious thing to reach for — marks every multi-arch image permanently
  "behind". The remote side is therefore read from the registry's own
  `Docker-Content-Digest` for the tag, which is exactly what `RepoDigests` holds.
- *gluetun's dependents.* qbittorrent and port-sync run with
  `network_mode: service:gluetun`. Recreating gluetun makes a new network
  namespace, stranding anything still attached to the old one — so a gluetun
  update deliberately recreates the whole stack, while any other service is
  recreated with `--no-deps` so the VPN tunnel isn't dropped needlessly.

**Templated 2026-08-11.** `qbittorrent-vpn`'s `docker-compose.yml` is now rendered
from `roles/qbittorrent-vpn/templates/docker-compose.yml.j2`, replacing the
runtime-only file whose header still credited the retired `homelab-infra` repo (and
called the container "LXC 120" — it is 110).

**Still unmanaged: `/opt/qbittorrent-vpn/.env`** (Proton WireGuard key, qBit WebUI
password) and `port-sync/port-sync.sh`, which the compose file mounts from the host.
Bringing the `.env` in means first seeding those secrets into this repo's Vault scope
— see `docs/runbooks/qbittorrent-vault-secret.md`.

> ⚠ **`QBIT_WEBUI_PASSWORD` in that `.env` is a phantom** (found 2026-08-13):
> qBittorrent has no WebUI password configured at all, so nothing matches it and a
> login with it can only ever fail — five failures ban the source IP for an hour.
> Access control is the subnet whitelist, and that whitelist **cannot be reached from
> LXC 110's own host**: the WebUI is published through Docker, so a host-origin
> request is SNAT'd to the bridge gateway (`172.18.0.1`) and falls outside it. Use
> `docker exec qbittorrent curl …` instead. This is why `media-lifecycle`'s
> qBittorrent in-use guard has never worked — see `docs/GOTCHAS.md`.

## Captured hosts (live VMID/IP — permanent; the 21x renumber was canceled, PET-49)

| Host | VMID | IP | Notes |
|---|---|---|---|
| lidarr | 100 | .14 | |
| seerr | 101 | .33 | sdb3-storage; eth1-only; no bind-mounts |
| plex | 103 | 86.140 (vmbr0) + .140 (vmbr1) | dual-homed; downloads mount ro |
| sonarr | 104 | .15 | sdb3-storage |
| radarr | 105 | .16 | sdb3-storage |
| prowlarr | 109 | .20 | |
| qbittorrent-vpn | 110 | .21 | Gluetun/Proton |

The old "110 is also in the retired `homelab-infra` TF — reconcile before applying"
caveat is **resolved** (2026-08-11), and it was verified rather than assumed: the
`tfstate` bucket holds exactly three objects, and `terraform state list` on
petedio-iac returns no VMID in 100–110. There was no old side left to `state rm`.
That is what unblocked `MEDIA_APPLY_ENABLED`.

**filebrowser (102)** was the old file/image store and is **decommissioned** —
`PET-82` is Done. It is not in this repo and no longer exists on the cluster.

## How to run (local, Mac on the LAN)

```bash
cd environments/media
# secrets via env (same Proxmox token + MinIO creds + ssh key as petedio-iac):
export TF_VAR_proxmox_api_token='petedio@pam!petedio=...'
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519_ansible.pub)"
export AWS_ACCESS_KEY_ID=...   AWS_SECRET_ACCESS_KEY=...   # MinIO

terraform init
# import the running LXCs (state-only — does NOT touch the containers):
terraform import 'module.sonarr.proxmox_virtual_environment_container.this' pve01/104
# ... repeat per host ...
terraform plan          # GOAL: clean no-op (zero drift) → capture proven
```

> **Never** run a `terraform apply` against a freshly imported host until `plan`
> is a clean no-op — an apply on drift would mutate (or recreate) a live, data-
> heavy container.

## Conventions

Workflow **B** (GitOps/IaC), **split by trust** — this repo is public and the apply
runner is self-hosted inside the homelab (PET-163):

| Job | Trigger | Where | Gets |
|---|---|---|---|
| `validate` | PR **and** push | GitHub-hosted, ephemeral | `fmt` + `init -backend=false` + `validate`. No Vault, no LAN, no state. |
| `apply` | push to `main` only | self-hosted, in the homelab | Vault OIDC creds, MinIO state, `plan` → `apply` |

**PRs deliberately do not get a `terraform plan` comment.** A real plan needs the LAN
backend and the provider credentials that are withheld from PR runs on purpose, so
the authoritative plan is the operator's local one or the apply-on-merge log. If you
came here expecting the PR plan to be the review surface: that changed with PET-163.

`apply` is live (`MEDIA_APPLY_ENABLED=true`), so **a squash-merge really does apply**.
Pushes are filtered with `paths-ignore` so a docs-only merge doesn't mint credentials
on the homelab runner. Vault (`.223`) comes up **sealed after any reboot** and must be
unsealed by hand — the apply job preflights that and says so.

Branch `pet-<n>-<slug>`, squash-merge, mention `PET-<n>` in the PR. Secrets live in
**Vault**, never in code. See `docs/GOTCHAS.md` and the petedio-iac repo for the
carry-forward Terraform/bpg/Ansible gotchas.
