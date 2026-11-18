# blast-radius

Source: `.github/workflows/blast-radius.yml`

| | |
|---|---|
| **Trigger** | `pull_request`. |
| **Runner** | Hosted, via petedio-iac `blast-radius.yml@main`. |
| **Touches** | Labels the PR tier-0, tier-1 or tier-2 against this repo's own workflows. |
| **Vault** | None. |
| **Secrets** | None. |
| **Gates** | Classifies only; it merges nothing. Edit tiers in petedio-iac `scripts/pr-blast-radius.py`. |
| **Run it** | Open a PR. |
