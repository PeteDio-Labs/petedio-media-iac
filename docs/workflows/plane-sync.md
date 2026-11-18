# plane-sync

Source: `.github/workflows/plane-sync.yml`

| | |
|---|---|
| **Trigger** | `pull_request_target`, `workflow_dispatch`. |
| **Runner** | Self-hosted, via petedio-iac `plane-sync.yml@main`. |
| **Touches** | Moves the matching Plane work item on PR events. Never fails a build. |
| **Vault** | Role `plane-ci` (reads `kv/services/plane` `api_key` only). |
| **Secrets** | None in Actions. |
| **Gates** | `pull_request_target` runs main's copy and never checks out the PR head. Inert until `PLANE_BASE_URL`, `PLANE_WORKSPACE` and `PLANE_PROJECT_ID` are set. Threads do not call Plane; they queue changes in `petedio-pm`. |
| **Run it** | Runs on PR events. |
