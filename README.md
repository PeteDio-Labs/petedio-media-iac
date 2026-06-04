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
ansible/                    # host config to match the running services (idempotent)
docs/GOTCHAS.md             # media-specific gotchas (+ pointer to petedio-iac's)
.github/workflows/          # Workflow B — plan-on-PR, apply-on-merge (self-hosted runner)
```

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
