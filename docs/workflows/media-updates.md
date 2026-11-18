# media-updates

Source: `.github/workflows/media-updates.yml`

| | |
|---|---|
| **Trigger** | `workflow_dispatch` only, with inputs `mode` (`check`, `apply`, `indexers-check`), `target`, `request_id`. |
| **Runner** | Self-hosted runner on the LAN (`[self-hosted, linux, x64, homelab]`) |
| **Touches** | Runs `check-updates.yml` or `update-media.yml` through Ansible in Docker against the media LXCs. `indexers-check` is a read-only Prowlarr drift check. |
| **Vault** | Role `media-updates`, bound to this file, `main` and `workflow_dispatch`. Reads `kv/iac/lxc-ssh` `private_key` only. |
| **Secrets** | None in Actions. |
| **Gates** | No push, pull request or schedule trigger. Inputs are choices; `target` maps to a fixed `--limit`, and `request_id` must be a short token. A Vault preflight runs first. Runs with `--skip-tags baseline,bazarr_config`. The job fails unless the report and the play recap are both in the log. One run at a time. pete-bot's `/update` starts it and reads the report between markers in the log. |
| **Run it** | `gh workflow run media-updates.yml -f mode=check -f target=plex-and-arr`. |

Keep the report markers in step with pete-bot `src/clients/githubActions.ts`.
