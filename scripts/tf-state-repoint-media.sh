#!/usr/bin/env bash
# tf-state-repoint-media.sh — repoint the media state off the dead pve01, and
# drop the guests that no longer exist anywhere.
#
# WHY THIS EXISTS. pve01 was removed from the cluster after its RAID controller
# failed on 2026-09-03. Six resources in media/terraform.tfstate still record it
# as their node, so every plan dies at refresh with:
#
#   Error: error retrieving container: received an HTTP 500 response - Reason:
#   hostname lookup 'pve01' failed
#
# Terraform refreshes each resource against the node named in ITS STATE, so
# config alone cannot fix this -- PET-325 repointed `target_node` and the plan
# kept failing. The supported repair is state rm + import, per resource.
#
# Because Plan exited 1, Apply never ran, so the one real diff in that plan --
# plex-gpu wanting its mesh leg back -- was reported on every merge and never
# applied. That is the "1 to change forever" symptom (PET-332).
#
# Terraform aborts the walk at whichever of the six errors first, so the module
# it blames differs run to run. It is not one bad resource.
#
# This is petedio-iac's scripts/tf-state-repoint-pve01.sh, scoped to THIS repo's
# state. That script hardcodes `cd environments/homelab` in its own repo, which
# is why the homelab state was repaired on 2026-09-04 and the media state was
# not.
#
# It is deliberately not run by CI: it rewrites state, and MinIO versioning on
# the tfstate bucket is the only undo.
set -euo pipefail

cd "$(dirname "$0")/../environments/media"

# ── Ordering guard ────────────────────────────────────────────────────────────
# This script must run AFTER the config change that removes module "plex" and
# plex-gpu's net1_* block. Run it before, and the repair arms two hazards:
#
#   * `state rm module.plex` with the module still declared makes the next plan
#     CREATE a new plex 103 on pve02 -- with pve01's bridge numbering, which is
#     inverted there, so its "mesh" address lands on the LAN bridge.
#   * a working refresh with net1_* still declared lets apply add plex-gpu's eth1
#     to a VXLAN whose remote (pve01) no longer exists.
#
# Both would report success. Encode the dependency rather than trusting the
# runbook to be read in order.
if grep -q '^module "plex" {' media.tf; then
  echo "REFUSING: media.tf still declares module \"plex\"." >&2
  echo "  Merge the config change that removes it first, then re-run." >&2
  exit 1
fi
if grep -q 'net1_bridge' media.tf; then
  echo "REFUSING: media.tf still declares a net1_bridge." >&2
  echo "  plex-gpu's mesh leg rides a VXLAN whose remote node is gone." >&2
  echo "  Merge the config change that removes it first, then re-run." >&2
  exit 1
fi

# ── Credentials ───────────────────────────────────────────────────────────────
# Resolved here rather than assumed. The terraform S3 backend needs the MinIO
# keys, and without them it falls back to the AWS credential chain and fails
# with "No valid credential sources found" plus an EC2 IMDS error, which reads
# as an AWS problem and is not.
if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  ROOT_TOKEN="$(security find-generic-password -s vault-root-token -a vault-223 -w 2>/dev/null)" || {
    echo "no Vault root token in the Keychain (vault-root-token / vault-223)" >&2; exit 1; }
  vget() {
    curl -sk -m 10 -H "X-Vault-Token: $ROOT_TOKEN" \
      "https://192.168.50.223:8200/v1/kv/data/iac/$1" 2>/dev/null \
      | python3 -c "import sys,json;print((json.load(sys.stdin).get('data',{}).get('data') or {}).get('$2',''))"
  }
  export AWS_ACCESS_KEY_ID="$(vget minio access_key)"
  export AWS_SECRET_ACCESS_KEY="$(vget minio secret_key)"
  export TF_VAR_proxmox_api_token="$(vget proxmox api_token)"
  export TF_VAR_ssh_public_key="$(vget lxc-ssh public_key)"
  [ -n "$AWS_ACCESS_KEY_ID" ] || { echo "could not read MinIO keys from Vault" >&2; exit 1; }
  echo "credentials resolved from Vault"
fi

terraform init -input=false -reconfigure >/tmp/media-repoint-init.log 2>&1 || {
  tail -15 /tmp/media-repoint-init.log; echo "terraform init failed" >&2; exit 1; }

BACKUP="/tmp/media-tfstate-pre-repoint-$(date +%Y%m%d-%H%M%S).json"
terraform state pull > "$BACKUP"
echo "state backed up to $BACKUP (serial $(python3 -c "import json;print(json.load(open('$BACKUP'))['serial'])"))"

# Guests that survived, and the node each is actually on. The container is real;
# only the state's idea of which node it sits on is wrong. rm + import corrects
# that without touching the running guest.
#
# ⚠ THIS HALF CANNOT BE DECLARATIVE, and it is not for want of trying. Repointing
# needs the row dropped and re-adopted, and terraform refuses to pair `removed`
# with `import` for an address the config still declares:
#
#   Error: Removed resource still exists
#   This statement declares that module.seerr.proxmox_virtual_environment_container.this
#   was removed, but it is still declared in configuration.
#
# An `import` block cannot adopt over an existing row either. Doing it in config
# would take two merges — one deleting five module blocks, one restoring them —
# with five live containers unmanaged in between. A guarded, backed-up, idempotent
# script run once is the better trade for a state corrupted by a dead node.
#
# Ground-truthed against /cluster/resources, not against the config:
#   101 seerr, 110 qbittorrent-vpn        -> pve02
#   104 sonarr, 105 radarr, 109 prowlarr  -> pve03  (moved there by PET-325)
# 236 plex-gpu is already correct in state and is deliberately absent here.
EXISTS="
module.seerr.proxmox_virtual_environment_container.this|pve02/101
module.qbittorrent_vpn.proxmox_virtual_environment_container.this|pve02/110
module.sonarr.proxmox_virtual_environment_container.this|pve03/104
module.radarr.proxmox_virtual_environment_container.this|pve03/105
module.prowlarr.proxmox_virtual_environment_container.this|pve03/109
"

# Rows for a guest that exists nowhere. plex 103 died with pve01, and Proxmox has
# already dropped 103 from the `homelab` pool, so its membership row is a phantom.
# It leaves state by `state rm`, NOT by destroy: terraform cannot destroy a guest
# on a node that does not resolve, and there is nothing left to destroy.
#
# ⚠ ONLY THE MEMBERSHIP IS HERE. module.plex's own row is handled in config, by a
# `removed` block in media.tf — the declarative form, reviewable in a PR. Prefer
# that; see the IaC-over-hand-fixes rule in CLAUDE.md.
#
# The membership cannot follow it, because a `removed` block addresses a RESOURCE
# and this is one INSTANCE of a for_each:
#
#   Resource address must be a resource (e.g. "test_instance.foo"), not a
#   resource instance (e.g. "test_instance.foo[1]").
#
# Forgetting the whole `proxmox_pool_membership.media` resource would drop all six
# surviving memberships and need six imports back, which is worse than one rm.
GONE='
proxmox_pool_membership.media["plex"]
'

echo
echo "== repointing guests that still exist =="
while IFS='|' read -r addr target; do
  [ -z "$addr" ] && continue
  echo "  $addr  -> $target"
  terraform state rm "$addr" >/dev/null
  terraform import -lock=false "$addr" "$target" >/dev/null
  echo "    imported as $target"
done <<< "$EXISTS"

echo
echo "== dropping the phantom pool membership for 103 =="
while read -r addr; do
  [ -z "$addr" ] && continue
  echo "  $addr"
  terraform state rm "$addr" >/dev/null
done <<< "$GONE"

echo
echo -n "== remaining references to pve01 in state: "
terraform state pull | grep -c '"node_name": "pve01"' || true

echo
echo "Now run a plan and READ IT. It must be a clean no-op:"
echo "  No changes. Your infrastructure matches the configuration."
echo
echo "To undo:  terraform state push $BACKUP"
