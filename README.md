# petedio-media-iac

Terraform + Ansible for the homelab **media stack** — brought under IaC by
**brownfield capture** (import the running LXCs as-is; no rebuild, no data loss,
no downtime). Split out from [`petedio-iac`](https://github.com/PeteDio-Labs/petedio-iac)
so the media stack gets its own state object and its own Vault secret scope.

Part of the PeteDio homelab→AWS platform. Tracker: Linear project **Platform**,
**Media Stack** milestone (issues `PET-46/47/48/49/53`).

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
  roles/qbittorrent-vpn/    #   the gluetun/qbittorrent compose stack
  playbooks/media-roles.yml #   shared play body (both entry points import it)
docs/GOTCHAS.md             # media-specific gotchas (+ pointer to petedio-iac's)
.github/workflows/          # Workflow B — plan-on-PR, apply-on-merge (self-hosted runner)
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

**Known limitation — registry rate limits.** Two of the three qbittorrent-vpn
images come from `docker.io`, which caps anonymous pulls (100/6h per IP);
`lscr.io` throttles bursts too. When that trips, the digest check reports those
images as `NOT CHECKED` rather than pretending they are current. Pulls are done
**per service**, so one throttled-but-current image can't block updating a
different one that is genuinely stale. The durable fix is pointing `docker.io`
at the homelab Nexus pull-through cache — not yet wired up.

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

**Not yet templated:** `qbittorrent-vpn`'s `docker-compose.yml` is captured at
runtime only, not rendered from this repo. Its header still claims it comes from
`infrastructure/ansible/templates/…` in the retired `homelab-infra` repo (and
calls the container "LXC 120" — it is 110), so in practice it is unmanaged.
Templating it means first bringing the Proton WireGuard key and qBit WebUI
password into this repo's Vault scope; the `.env` holding them is deliberately
not committed.

## Captured hosts (live VMID/IP — renumber to 21x deferred, PET-49)

| Host | VMID | IP | Notes |
|---|---|---|---|
| lidarr | 100 | .14 | |
| seerr | 101 | .33 | sdb3-storage; eth1-only; no bind-mounts |
| plex | 103 | 86.140 (vmbr0) + .140 (vmbr1) | dual-homed; downloads mount ro |
| sonarr | 104 | .15 | sdb3-storage |
| radarr | 105 | .16 | sdb3-storage |
| prowlarr | 109 | .20 | |
| qbittorrent-vpn | 110 | .21 | Gluetun/Proton; also in OLD TF — reconcile |

**filebrowser (102)** is intentionally excluded — old file/image store, flagged
for decommission (`PET-82`).

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

Workflow **B** (GitOps/IaC): `terraform plan` on PR (the review surface),
`terraform apply` on merge — via the self-hosted runner inside the homelab.
Branch `pet-<n>-<slug>`, squash-merge, mention `PET-<n>` in the PR. Secrets live
in **Vault**, never in code. See `docs/GOTCHAS.md` and the petedio-iac repo for
the carry-forward Terraform/bpg/Ansible gotchas.
