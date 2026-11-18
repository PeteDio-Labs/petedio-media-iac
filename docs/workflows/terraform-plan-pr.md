# terraform-plan-pr

Source: `.github/workflows/terraform-plan-pr.yml`

| | |
|---|---|
| **Trigger** | `workflow_run` after `terraform`. |
| **Runner** | `inspect`: GitHub-hosted (`ubuntu-latest`), no credentials. `plan`: Self-hosted runner on the LAN (`[self-hosted, linux, x64, homelab]`). |
| **Touches** | Plans `environments/media` and `modules/proxmox-lxc` for a same-repo PR and comments counts and addresses. Writes no state; no apply step. |
| **Vault** | Role `deploy-media-plan`, bound to this file, `main` and `workflow_run`. |
| **Secrets** | None in Actions. |
| **Gates** | Main's copy runs, never the PR's. A text guard and a parsed-HCL guard run in `inspect`; `plan` checks out the exact examined commit. Providers install from a mirror of main's tree. `-lock=false`. Resource addresses have `[instance key]` redacted. A refused PR gets a comment that says to plan locally. |
| **Run it** | Open a same-repo PR. |

The guards are an allowlist of what a PR may change, not proof it is safe.
