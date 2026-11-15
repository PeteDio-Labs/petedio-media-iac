#!/usr/bin/env bash
# tf-plan-media.sh — run a local, read-only `terraform plan` for environments/media.
#
# A PR in this repo gets no plan and a merge applies, so the plan from this
# script is the review surface before a merge. It never applies.
#
# Credentials resolve the way tf-state-repoint-media.sh resolves them: the Vault
# root token comes from the Keychain (vault-root-token / vault-223), and the
# MinIO, Proxmox and LXC key values come from kv/iac/*. They live only in this
# process's environment and are never printed.
#
# The full plan lands in $OUT (default /tmp/media-plan.txt); the summary prints.
# Bash 3.2-compatible: it runs on the Mac.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_DIR="$HERE/../environments/media"
OUT="${OUT:-/tmp/media-plan.txt}"

if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  [ -r "$HERE/../environments/media/vault-ca.crt" ] || { echo "missing environments/media/vault-ca.crt" >&2; exit 1; }
  ROOT_TOKEN="$(security find-generic-password -s vault-root-token -a vault-223 -w 2>/dev/null)" || {
    echo "no Vault root token in the Keychain (vault-root-token / vault-223)" >&2; exit 1; }
  vget() {
    curl -s -m 10 --cacert "$HERE/../environments/media/vault-ca.crt" -H "X-Vault-Token: $ROOT_TOKEN" \
      "https://192.168.50.223:8200/v1/kv/data/iac/$1" \
      | python3 -c "import sys,json;print((json.load(sys.stdin).get('data',{}).get('data') or {}).get('$2',''))"
  }
  AWS_ACCESS_KEY_ID="$(vget minio access_key)"
  AWS_SECRET_ACCESS_KEY="$(vget minio secret_key)"
  TF_VAR_proxmox_api_token="$(vget proxmox api_token)"
  TF_VAR_ssh_public_key="$(vget lxc-ssh public_key)"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY TF_VAR_proxmox_api_token TF_VAR_ssh_public_key
  unset ROOT_TOKEN
  [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$TF_VAR_proxmox_api_token" ] || {
    echo "could not read the keys from Vault; run: pet-secrets doctor" >&2; exit 1; }
  echo "credentials resolved from Vault"
fi

cd "$ENV_DIR"
echo "branch: $(git rev-parse --abbrev-ref HEAD) at $(git rev-parse --short HEAD)"
terraform init -input=false -reconfigure -no-color </dev/null >"$OUT.init" 2>&1 || {
  tail -15 "$OUT.init"; echo "terraform init failed" >&2; exit 1; }
rc=0
terraform plan -input=false -no-color -lock=false -detailed-exitcode </dev/null >"$OUT" 2>&1 || rc=$?
grep -E '^Plan:|^No changes|will be (created|destroyed|updated in-place)|must be replaced|^Error' "$OUT" || true
echo "full plan: $OUT (exit $rc: 0 no changes, 2 changes, 1 error)"
[ "$rc" -ne 1 ]
