# Runbook — media CI ↔ Vault (OIDC)

**Status: DONE and live.** This was written as a migration checklist while the wiring
was still pending; every step in it has since landed. It is a **reference for how
CI gets credentials, and what to do when it stops working** — verified against live
Vault 2026-08-13.

## What exists today

| | |
|---|---|
| JWT role | `auth/jwt-github/role/media-ci` on `.223` |
| Bound sub | `repo:PeteDio-Labs/petedio-media-iac:ref:refs/heads/main` — **main only** |
| Policy | `media-ci` — reads `kv/iac/{minio,proxmox,lxc-ssh}` + `services/media/*` |
| Token TTL | 900s |
| Apply gate | `MEDIA_APPLY_ENABLED=true` (repo variable) since 2026-08-11 |

> **Correction (2026-08-13).** Earlier versions of this runbook said the role was
> bound to the repo's "`main` + `pull_request` OIDC subs". **It is not, and must not
> be.** PET-163 dropped the `pull_request` sub precisely so a fork PR cannot mint
> `media-ci` credentials on the self-hosted runner. Confirmed live: `bound_claims.sub`
> is the single `refs/heads/main` entry above. If you ever see a `pull_request` sub on
> this role, that is a regression, not a convenience.

## How a run gets credentials

1. `validate` (PR **and** push) — GitHub-hosted, ephemeral. **No Vault, no LAN, no
   state.** `fmt` + `init -backend=false` + `validate`. This is the only job a PR runs.
2. `apply` (push to `main` only) — self-hosted inside the homelab:
   - **Vault preflight** — is `.223` reachable and unsealed? Fails early with a message
     naming the fix, because `vault-action` renders a sealed Vault as an opaque
     `503`/`ERR_NON_2XX_3XX_RESPONSE` that reads like a network fault.
   - `Encode Vault CA` → base64 the committed `environments/media/vault-ca.crt`
   - `Vault — mint creds via OIDC` → JWT login (role `media-ci`) → exports
     `AWS_*` / `TF_VAR_*`
   - `Init` → `Plan` → `Apply` (gated on `MEDIA_APPLY_ENABLED`)

`push` is filtered with `paths-ignore` (`**/*.md`, `docs/**`, `scripts/**`,
`ansible/**`), so a docs-only merge never mints credentials at all.

## When CI goes red

**`Vault is sealed`** — by far the most common, and it is not a fault. `.223` re-seals
on **every reboot**. Unseal, then re-run the job:

```bash
~/petedio/scripts/pet-secrets unseal      # Keychain -> API; value never rendered
```

`pet-secrets watch install` auto-unseals within ~5 min of a reboot, which removes this
failure mode. See the workspace `CLAUDE.md`.

**`No valid credential sources found` at Init** — the original symptom this runbook was
written for. Means the OIDC exchange did not happen or produced nothing: check the
preflight passed, then that the `media-ci` role still exists and its bound sub matches
the branch being pushed.

```bash
vault read auth/jwt-github/role/media-ci   # bound_claims.sub -> refs/heads/main
vault policy read media-ci
```

**A PR expecting a plan** — there isn't one, by design. PRs get `validate` only; the
authoritative plan is the operator's local one or the apply-on-merge log (PET-104/163).

## Re-establishing the role from scratch

The role + policy are **code** in `petedio-iac`
(`environments/homelab/vault-config/auth.tf`), but applying that workspace needs the
Vault **root token** — operator-only, out-of-band, never in CI. That is the one step
that cannot be GitOps.

```bash
cd petedio-iac/environments/homelab/vault-config
export VAULT_ADDR=https://192.168.50.223:8200
export VAULT_CACERT=$(pwd)/../vault-ca.crt
export VAULT_TOKEN=<root token>            # pet-secrets get vault-root-token
export AWS_ACCESS_KEY_ID=...               # pet-secrets get minio access_key
export AWS_SECRET_ACCESS_KEY=...
terraform init && terraform apply
```

## Why no static GitHub secrets

This repo has **no** Actions secrets — credentials come only from Vault via OIDC, so a
leaked repo leaks nothing. The `media-ci` policy reads only the media creds (no
`poker/*`, no `cloudflare/*`), and the role is bound to `main` alone.

> Fork-PR exposure (public repo + self-hosted runner) remains a known follow-up: gate
> fork PRs with require-approval before relying on this in anger. Note the trust split
> already blunts it — a PR runs only the hosted `validate` job, with no Vault, no LAN
> and no state — so a fork PR has nothing to steal even before that gate exists.
