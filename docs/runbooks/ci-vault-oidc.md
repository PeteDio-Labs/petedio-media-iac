# Runbook — enable media CI (Vault-OIDC)

The `terraform` workflow fails at **Init** (`No valid credential sources found`)
until Vault has a `media-ci` JWT role for this repo. The role is **code** in
`petedio-iac` but applying it needs the **Vault root/bootstrap token** (operator,
out-of-band — never in CI). This is the one manual step.

## 1. Apply the Vault role (operator, with the root token)

The role + policy are on branch `pedelgadillo/pet-47-media-ci-vault-oidc` in
**petedio-iac** (`environments/homelab/vault-config/`). Merge it, then apply the
vault-config workspace manually:

```bash
cd petedio-iac/environments/homelab/vault-config

export VAULT_ADDR=https://192.168.50.223:8200
export VAULT_CACERT=$(pwd)/../vault-ca.crt
export VAULT_TOKEN=<root/bootstrap token from the password manager>   # NOT an AppRole

# MinIO state backend creds (same as the main workspace)
export AWS_ACCESS_KEY_ID=...      # vault kv get -field=access_key kv/iac/minio
export AWS_SECRET_ACCESS_KEY=...  # vault kv get -field=secret_key kv/iac/minio

terraform init
terraform apply      # creates: vault_policy.media_ci + vault_jwt_auth_backend_role.media_ci
```

Verify:

```bash
vault read auth/jwt-github/role/media-ci          # bound_claims.sub = the media repo's main+PR subs
vault policy read media-ci                         # reads kv/iac/{minio,proxmox,lxc-ssh} + services/media/*
```

## 2. Land the media-iac CI change

The workflow wiring is on `pedelgadillo/pet-47-media-ci-vault-oidc` in **this**
repo (vault-action step + committed `environments/media/vault-ca.crt`). Once the
role exists (step 1), merge it to `main`. The next push/PR run will:

- `Encode Vault CA` → base64 the committed CA
- `Vault — mint creds via OIDC` → JWT login (role `media-ci`) → export
  AWS_*/TF_VAR_* for init/plan/apply
- `Init` succeeds against the MinIO backend → `plan` runs (no-op, zero drift)

## 3. Apply-on-merge is OPT-IN

The `Apply` step is gated behind the repo variable **`MEDIA_APPLY_ENABLED`**.
Leave it unset/false until the **qbittorrent-vpn (110) dual-state** is resolved
(old homelab-infra TF still manages it — `terraform state rm` it there first).
Then enable:

```bash
gh variable set MEDIA_APPLY_ENABLED --body true --repo PeteDio-Labs/petedio-media-iac
```

## Why no static GitHub secrets

This repo has **no** Actions secrets — creds come only from Vault via OIDC, so a
leaked repo never leaks creds. The `media-ci` role is scoped to the media repo's
`main` + `pull_request` OIDC subs only (exact match), and reads only the media
creds (no poker/* or cloudflare/*). Mirrors petedio-iac's `github-actions` setup.

> Fork-PR exposure (public repo + self-hosted runner) is a known follow-up — gate
> fork PRs (require-approval) before relying on this in anger. Same caveat as
> petedio-iac.
