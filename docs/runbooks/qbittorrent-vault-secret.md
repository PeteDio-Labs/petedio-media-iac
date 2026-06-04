# Runbook — qBittorrent / Gluetun VPN secret in Vault

**Status: STUB (path + policy contract decided; seed pending a privileged Vault token).**

qbittorrent-vpn (LXC 110) runs qBittorrent behind Gluetun/Proton. Its secrets —
the **Proton WireGuard private key** and the **qBittorrent admin password** — must
live in Vault, never in this repo or in `ansible-vault`.

## The contract (decided)

- **Path:** `kv/services/media/qbittorrent`
  - `wireguard_private_key`
  - `qbit_password`
  - (add `wireguard_addresses` / endpoint if Gluetun needs them)
- **Reader:** the existing **`ansible`** Vault policy already grants
  `path "kv/data/services/*" { capabilities = ["read"] }`, so the media Ansible
  run can read this path **as soon as it's seeded** — no policy change needed for
  read. (Verified: `vault token capabilities kv/data/services/media/qbittorrent`
  → `read` with the `ansible` AppRole.)
- **Isolation:** these are media-only secrets under `services/*`. They are NOT
  readable by the `terraform`/`ci-read`/`colatro-ci` poker paths, and we do NOT
  widen any policy to reach them — `services/*` read is the right scope.

## Seed (privileged — run with a Vault admin/root token, not an AppRole)

```bash
export VAULT_ADDR=https://192.168.50.223:8200
export VAULT_CACERT=/path/to/vault-ca.crt
export VAULT_TOKEN=<admin/root token>   # the AppRoles can only READ services/*

vault kv put kv/services/media/qbittorrent \
  wireguard_private_key='...' \
  qbit_password='...'
```

The current secrets live in the OLD homelab-infra `ansible-vault`
(`qbittorrent.vault.yml`) — migrate those values here, then retire the
`ansible-vault` file (Epic E2 / Vault & Secrets milestone).

## Consume (Ansible, follow-up)

The qbittorrent-vpn role (not yet written) will read the secret at runtime, e.g.:

```yaml
- name: Read qBittorrent/Gluetun secrets from Vault
  ansible.builtin.set_fact:
    qbit: "{{ lookup('community.hashi_vault.vault_kv2_get',
                     'services/media/qbittorrent', engine_mount_point='kv') }}"
  no_log: true
```

Use the `ansible` AppRole token (services/* read) for that lookup.
