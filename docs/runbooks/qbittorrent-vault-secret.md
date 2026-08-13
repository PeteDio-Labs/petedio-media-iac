# Runbook — qBittorrent / Gluetun VPN secret in Vault

**Status: seed still pending — but the secret set changed. Read § "What is actually
secret" before seeding; the previously-specified contract included a credential that
does not exist.**

qbittorrent-vpn (LXC 110) runs qBittorrent behind Gluetun/Proton. Its `.env` is
deliberately not committed, and its real secrets must live in Vault rather than in
this repo or in `ansible-vault`.

## What is actually secret (corrected 2026-08-13, measured on the host)

`/opt/qbittorrent-vpn/.env` carries four keys:

| Key | Secret? | Notes |
|---|---|---|
| `PROTON_WG_PRIVATE_KEY` | **yes** | The real one. Gluetun's WireGuard identity. |
| `PROTON_WG_ADDRESSES` | **yes-ish** | Tunnel address; not a credential but pairs with the key and is not public. |
| `PROTON_SERVER_COUNTRIES` | no | Plain config. Belongs in the role's defaults, not Vault. |
| `QBIT_WEBUI_PASSWORD` | **no — it is a phantom** | See below. |

### `QBIT_WEBUI_PASSWORD` must NOT be seeded

There is **no WebUI password configured on this qBittorrent at all.** Measured on
110:

```
grep -c 'WebUI.Password' qBittorrent.conf   ->  0
grep -c 'WebUI.Username' qBittorrent.conf   ->  0
WebUI\AuthSubnetWhitelistEnabled=true
```

Access control is `WebUI\AuthSubnetWhitelist` (`127.0.0.1/32, 192.168.50.0/24`)
alone. So the value in `.env` matches nothing, can never authenticate, and five
attempts to use it ban the source IP for an hour — which is exactly what happened on
2026-08-13 and cost most of a day chasing a "stale password" that was never a
password. See `docs/GOTCHAS.md` § "qBittorrent's WebUI cannot be reached from LXC
110's own host".

**Seeding it into Vault would give a non-credential the appearance of a credential**
and guarantee the next person wires up a login that cannot work. Anything on 110 that
needs the API should use `docker exec qbittorrent curl …`, which is in-namespace and
therefore whitelisted — that is what `roles/media-lifecycle` and
`scripts/api-capability-probe.sh` now do.

If a real WebUI password is ever wanted, that is a **deliberate config change** to
qBittorrent (set `WebUI\Password_PBKDF2`), and only then is there something worth
storing. Removing the dead key from `.env` is worth doing at the same time.

## ⚠ Path collision — decide before seeding

Two paths exist for the same thing, and this is precisely the "which is it called?"
tax that `pet-secrets` was written to remove:

| Path | State | Referenced by |
|---|---|---|
| `kv/services/qbittorrent` | **seeded** (`username`, `password`) | `iac/scripts/vault-seed.sh`, `vault-verify.sh` |
| `kv/services/media/qbittorrent` | **not seeded** | this repo's docs only — 0 code consumers |

`iac`'s seed migrated the values out of the retired homelab-infra
`qbittorrent.vault.yml` — *the same source this runbook was going to migrate from*.
So the work was already done once, under a different name, and both copies inherit
the phantom password.

**Recommendation:** consolidate on **`kv/services/media/qbittorrent`** — it matches
the `services/media/*` grouping this repo already uses, keeps media secrets together,
and is the path the `ansible` policy check below was verified against. Then drop the
qBittorrent block from `iac/scripts/vault-seed.sh` so one script does not keep
re-creating the other name.

Confirm what `kv/services/qbittorrent` actually holds before deciding — it may carry
a Proton key worth keeping, or only the dead password. `pet-secrets get qbittorrent`
will show both candidates.

## The contract

- **Path:** `kv/services/media/qbittorrent`
  - `wireguard_private_key`
  - `wireguard_addresses`
- **Reader:** the existing **`ansible`** Vault policy already grants
  `path "kv/data/services/*" { capabilities = ["read"] }`, so the media Ansible run
  can read this path as soon as it is seeded — no policy change needed for read.
  (Verified: `vault token capabilities kv/data/services/media/qbittorrent` → `read`
  with the `ansible` AppRole.)
- **Isolation:** media-only secrets under `services/*`, not readable by the
  `terraform`/`ci-read`/`colatro-ci` poker paths. Do not widen a policy to reach
  them — `services/*` read is the right scope.

## Seed (privileged — Vault admin/root token, not an AppRole)

```bash
export VAULT_ADDR=https://192.168.50.223:8200
export VAULT_CACERT=/path/to/vault-ca.crt
export VAULT_TOKEN=<admin/root token>   # the AppRoles can only READ services/*

vault kv put kv/services/media/qbittorrent \
  wireguard_private_key='...' \
  wireguard_addresses='...'
```

Note the absence of `qbit_password`. That is deliberate — see above.

## Consume

The `qbittorrent-vpn` role **exists** (it renders `docker-compose.yml.j2` and pulls
every image through `docker.pdlab.dev`), but `.env` is still unmanaged: it is the
one file the role does not render, precisely because these values are not in Vault
yet. Seeding closes that gap and lets the role template `.env` like everything else.

```yaml
- name: Read qBittorrent/Gluetun secrets from Vault
  ansible.builtin.set_fact:
    qbit: "{{ lookup('community.hashi_vault.vault_kv2_get',
                     'services/media/qbittorrent', engine_mount_point='kv') }}"
  no_log: true
```

Use the `ansible` AppRole token (`services/*` read) for that lookup.
