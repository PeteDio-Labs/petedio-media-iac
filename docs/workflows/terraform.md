# terraform

Source: `.github/workflows/terraform.yml`

| | |
|---|---|
| **Trigger** | `pull_request`, `push` to `main` (path-ignored for docs, scripts and ansible), `workflow_dispatch`. |
| **Runner** | `validate`: GitHub-hosted (`ubuntu-latest`). `apply`: Self-hosted runner on the LAN (`[self-hosted, linux, x64, homelab]`). |
| **Touches** | `environments/media`: the media LXCs on pve02 and pve03, state in MinIO key `media/terraform.tfstate`. |
| **Vault** | Role `media-ci` (push on `main` only). Reads MinIO and Proxmox records (see `environments/media`). |
| **Secrets** | None in Actions. |
| **Gates** | `validate` has no Vault, no LAN and no state. `apply` runs on a push to `main` only, and only when repo variable `MEDIA_APPLY_ENABLED == 'true'`. A preflight checks Vault is reachable and unsealed. The plan is refused if it destroys or replaces anything; `ALLOW_DESTROY=true` overrides. No `lab-write` wait here. Group `tf-media` never cancels, because the state has no lock. |
| **Run it** | Merge to `main`. Never apply against drift. |

The push filter is a deny-list on purpose: it fails open, so the worst case is one extra no-op plan.
