# plane-reconcile

Source: `.github/workflows/plane-reconcile.yml`

| | |
|---|---|
| **Trigger** | `schedule` (`22 8 * * *` UTC daily), `workflow_dispatch`. |
| **Runner** | Self-hosted, via petedio-iac `plane-reconcile.yml@main`. |
| **Touches** | Re-reads recently merged PRs of this repo and fixes work items a missed webhook left behind. |
| **Vault** | Role `plane-ci`. |
| **Secrets** | `github.token` of this repo. |
| **Gates** | Each repo needs its own caller because the reusable job reads the caller's repository and token (PET-363). The cron minute is staggered per repo. |
| **Run it** | `gh workflow run plane-reconcile.yml`. |
