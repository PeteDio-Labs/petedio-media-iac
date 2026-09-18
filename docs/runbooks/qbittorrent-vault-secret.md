# Runbook — qBittorrent / Gluetun VPN secret in Vault

**Status: seeded (PET-452), and rendered into `.env` by the `qbittorrent-vpn` role
(PET-453).** To change a value, see § "Rotate a value". A rotation recreates gluetun,
so it waits for an idle stack.

qbittorrent-vpn (LXC 110) runs qBittorrent behind Gluetun/Proton. Its `.env` is
deliberately not committed, and its real secrets must live in Vault rather than in
this repo or in `ansible-vault`.

## What is actually secret (corrected 2026-08-13, measured on the host)

The hand-written `/opt/qbittorrent-vpn/.env` carried four keys. The role's render
writes the first two from Vault and drops the other two:

| Key | Secret? | Notes |
|---|---|---|
| `PROTON_WG_PRIVATE_KEY` | **yes** | The real one. Gluetun's WireGuard identity. Vault field `wireguard_private_key`. |
| `PROTON_WG_ADDRESSES` | **yes-ish** | Tunnel address; not a credential but pairs with the key and is not public. Vault field `wireguard_addresses`. |
| `PROTON_SERVER_COUNTRIES` | no | Plain config. **Moved to the role's defaults as `proton_server_countries` (PET-295)**, where the compose template reads it. The render drops the key. |
| `QBIT_WEBUI_PASSWORD` | **no — it is a phantom** | See § `QBIT_WEBUI_PASSWORD` must NOT be seeded. The render drops the key. |

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
therefore allowlisted — that is what `roles/media-lifecycle` and
`scripts/api-capability-probe.sh` do.

If a real WebUI password is ever wanted, that is a **deliberate config change** to
qBittorrent (set `WebUI\Password_PBKDF2`), and only then is there something worth
storing. That change also needs the compose template's port-sync service, whose
`QBIT_PASSWORD` is empty on purpose (PET-453).

## Path collision — RESOLVED 2026-08-13 (read against live Vault)

Two paths existed for the same thing. Both were inspected once Vault was unsealed:

| Path | Contained on 2026-08-13 | Consumers on 2026-08-13 |
|---|---|---|
| `kv/services/qbittorrent` | `username`, `password` — **and nothing else** | `iac/scripts/vault-seed.sh`, `vault-verify.sh` |
| `kv/services/media/qbittorrent` | **empty** | none |

That settled it, and the answer was better than "pick one":

- **The seeded path held only the phantom pair.** `username` + `password` were the
  values `iac`'s seed migrated out of the retired homelab-infra
  `qbittorrent.vault.yml` — the credential that matches nothing, because qBittorrent
  has no WebUI password configured. There was no Proton key there. So
  `kv/services/qbittorrent` contained **no secret worth keeping.**
- **The Proton WireGuard key was not in Vault at all.** Its only copy was
  `/opt/qbittorrent-vpn/.env` on 110. The "seed pending" state was therefore real —
  it was just pending for a different secret than this runbook named.

**Actions.** All three are done:

1. PET-452 seeded `kv/services/media/qbittorrent` with the Proton key and addresses
   from the live `.env` on 110, using petedio-iac's `scripts/seed-qbittorrent-vault.sh`.
2. The same script's `--retire-old` deleted `kv/services/qbittorrent`, which held
   only the dead credential.
3. petedio-iac's `vault-seed.sh` no longer writes the retired path, and
   `vault-verify.sh` checks both fields at `kv/services/media/qbittorrent`.

## The contract

- **Path:** `kv/services/media/qbittorrent`
  - `wireguard_private_key`: 44 characters of base64, ending in `=`
  - `wireguard_addresses`: the tunnel's addresses in CIDR form, comma-separated,
    with no surrounding space
  - The render refuses any other shape. `tasks/env-verdict.yml` holds the checks.
- **Reader:** `roles/qbittorrent-vpn/tasks/env.yml`, on the controller, as the
  **`ansible`** AppRole. Its policy grants
  `path "kv/data/services/*" { capabilities = ["read"] }`, so the read needed no
  policy change. (Verified: `vault token capabilities kv/data/services/media/qbittorrent`
  → `read` with the `ansible` AppRole.)
- **Isolation:** media-only secrets under `services/*`, not readable by the
  `terraform`/`ci-read`/`colatro-ci` poker paths. Do not widen a policy to reach
  them — `services/*` read is the right scope.

## Seed (privileged — Vault admin/root token, not an AppRole)

To rotate a value, or to seed a rebuilt Vault, run `petedio-iac`'s
`scripts/seed-qbittorrent-vault.sh`. It prompts for both values silently, or takes
them from `WIREGUARD_PRIVATE_KEY` and `WIREGUARD_ADDRESSES`, writes the path, and
reads it back to prove the write. Its `--retire-old` flag deleted the stale
`kv/services/qbittorrent` under PET-452, so a later run doesn't need it.

```bash
export VAULT_ADDR=https://192.168.50.223:8200
export VAULT_CACERT=/path/to/vault-ca.crt
vault login                             # the AppRoles can only READ services/*

cd ~/petedio/iac && ./scripts/seed-qbittorrent-vault.sh
```

> [!warning] Do not seed this by hand with `vault kv put key='value'`
> This page told you to, until PET-452. A value passed as an argument lands on
> the child process's argv, where any user on the box reads it out of `ps` or
> `/proc/<pid>/cmdline` for as long as the process runs, and where your shell
> history keeps it afterwards. PET-110 forbids it. The script pipes the value to
> `vault kv put <path> -` on stdin instead, so it never reaches an argv.

Note the absence of `qbit_password`. That is deliberate — see § `QBIT_WEBUI_PASSWORD` must NOT be seeded.

## Consume

`roles/qbittorrent-vpn/tasks/env.yml` writes `.env` on every run of the role, before
the compose render reads the file. `configure-media.yml`, `check-updates.yml` and
`update-media.yml` all run the role. `media-updates.yml` never does, because none of
its targets is qbittorrent-vpn.

Each run takes four steps:

1. **Log in.** The `vault` CLI on the controller logs in as the `ansible` AppRole,
   with the `ansible.role_id` and `ansible.secret_id` files that petedio-iac's
   `docs/runbooks/vault-seed.md` writes to `iac/.secrets`.
2. **Read.** The CLI reads `kv/services/media/qbittorrent`. The credentials and the
   token reach the CLI on stdin, so none of them lands on an argv or in `-vvv` output.
   The login and the read both run the CLI with `VAULT_TOKEN` empty, `HOME` set to
   `/var/empty` and `VAULT_CONFIG_PATH` set to `/dev/null`. The CLI then finds no
   token of its own to send, such as a root token in the Mac's `~/.vault-token`.
3. **Judge.** `tasks/env-verdict.yml` checks the shape of both values, then compares
   them with the values gluetun runs with, from `docker inspect gluetun` on 110.
4. **Render.** `.env` gets the two keys, owned by root with mode `0600`. The task
   shows no diff and keeps no backup, because either would copy the key.

The role reads Vault through the CLI, not `community.hashi_vault`. That collection
needs the `hvac` library inside Ansible's Python, and Homebrew's Ansible doesn't ship
it.

### The verdict

Compose recreates gluetun when its resolved config changes, and qBittorrent restarts
with it. So the render restarts nothing only when gluetun runs with the values Vault
holds.

| Verdict | Meaning | The render |
|---|---|---|
| `same` | gluetun runs with both values Vault holds. | Writes `.env`. |
| `differs` | Vault holds a value gluetun doesn't run with. | Refuses. |
| `unknown` | `docker inspect gluetun` failed or printed no list. | Refuses. |

A malformed value refuses under every verdict, and `qbit_env_force` doesn't lift that
refusal. Under `--check`, the login, the read and the verdict run for real, and only
the write is skipped.

### Settings

| To | Do this |
|---|---|
| Converge while Vault is sealed | Pass `--skip-tags qbit_env`. The compose render then reads the `.env` on the host. |
| Read the AppRole files from another directory | Set `SECRETS_DIR`. The default is `iac/.secrets` in the clone beside this one. |
| Use another Vault | Set `VAULT_ADDR`. Set `VAULT_CACERT` as well when its CA isn't `environments/media/vault-ca.crt`. |
| Write a value gluetun doesn't run with | Pass `-e qbit_env_force=true`, with the stack idle. |

### Rotate a value

A rotation recreates gluetun, which stops every transfer. Run these steps from
`ansible/`:

1. Seed the new values, as in § "Seed".
2. On 110, check that nothing is downloading. The command prints `[]` when nothing is:

   ```bash
   docker exec qbittorrent curl -fsS 'http://localhost:8080/api/v2/torrents/info?filter=downloading'
   ```

3. Dry-run the converge. Expect the verdict `differs` and a refusal:

   ```bash
   ansible-playbook playbooks/configure-media.yml --limit qbittorrent-vpn --check
   ```

4. Converge with the override:

   ```bash
   ansible-playbook playbooks/configure-media.yml --limit qbittorrent-vpn -e qbit_env_force=true
   ```

5. Check the tunnel. The run ends with `VPN OK`:

   ```bash
   ansible-playbook playbooks/stack-up.yml --limit qbittorrent-vpn
   ```
