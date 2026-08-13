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

## Path collision — RESOLVED 2026-08-13 (read against live Vault)

Two paths existed for the same thing. Both were inspected once Vault was unsealed:

| Path | Actually contains | Consumers |
|---|---|---|
| `kv/services/qbittorrent` | `username`, `password` — **and nothing else** | `iac/scripts/vault-seed.sh`, `vault-verify.sh` |
| `kv/services/media/qbittorrent` | **empty** | none |

That settles it, and the answer is better than "pick one":

- **The seeded path holds only the phantom pair.** `username` + `password` are the
  values `iac`'s seed migrated out of the retired homelab-infra
  `qbittorrent.vault.yml` — the credential that matches nothing, because qBittorrent
  has no WebUI password configured. There is no Proton key there. So
  `kv/services/qbittorrent` contains **no secret worth keeping.**
- **The Proton WireGuard key is not in Vault at all.** It exists only in
  `/opt/qbittorrent-vpn/.env` on 110. The "seed pending" state was therefore real —
  it was just pending for a different secret than this runbook named.

**Actions:**

1. Seed `kv/services/media/qbittorrent` with the Proton key + addresses (below).
   Source them from the live `.env` on 110; that is currently the only copy, which
   is its own reason to get this done.
2. Delete `kv/services/qbittorrent` — it holds only the dead credential.
3. Drop the qBittorrent block from `iac/scripts/vault-seed.sh` (and `vault-verify.sh`)
   so the retired name stops being re-created. That is a `petedio-iac` change.

Until step 3 lands, re-running `vault-seed.sh` will recreate the dead path.

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
