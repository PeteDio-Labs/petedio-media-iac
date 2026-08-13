# Runbook — Seerr upgrade

**Status: the procedure is authoritative; the version numbers below are historical.**
Applied 2026-07-14 (3.1.0 → 3.3.0). **The host now runs 3.4.1** — and that later
upgrade is the one that destroyed the live database. Read the warning below before
running any of this. The upgrade is also captured as a guarded Ansible task
(`roles/seerr/tasks/upgrade.yml`), OFF by default. Run deliberately, never as part
of a capture pass.

> ## ⚠ This runbook's verification step is not sufficient — it is how the 3.4.1 incident went unnoticed
>
> Step 7 below polls `/api/v1/status` until it returns 200. **Seerr returns 200,
> reports the new version, and logs nothing wrong while serving a brand-new empty
> database.** During the 3.4.1 upgrade the live `config/` was silently not moved
> into the new tree (a `creates:` guard pointed at a path the source tarball ships,
> so the move no-op'd), the old tree was then deleted, and every health check passed.
> It was caught only by eyeballing `db.sqlite3` at 4096 bytes where it had been
> 344064 with a 4.1MB WAL.
>
> **A liveness check is not a correctness check.** Assert the *state* — see § Verify.
> Full account in `docs/GOTCHAS.md`.

## Context

- **Running:** Seerr **v3.1.0** (LXC 101 / .33, systemd `seerr.service`, built from
  a release tarball at `/opt/seerr`, data in `/opt/seerr/config`).
- **Latest:** **v3.3.0** (2026-06-02, `seerr-team/seerr` — the Jellyseerr successor).
- **Security note:** the running 3.1.0 already includes that release's CVE fixes
  (CVE-2026-27707 / -27793 / -27792), so this is a catch-up, not an emergency.

## Pre-flight (do this first)

1. **Back up for rollback.** LXC 101's rootfs is on `sdb3-storage` (thick LVM), so
   `pct snapshot` is **not available** (`snapshot feature is not available`). Use a
   full-tree tarball plus the config dir instead:
   ```bash
   ssh root@192.168.50.33 'tar czf /root/seerr-<old>-backup.tgz -C /opt seerr'
   # the Ansible task additionally copies /opt/seerr/config -> config.bak-<ts>
   ```
2. Confirm free space on the rootfs (build + node_modules ~2.4G; keep a few GB):
   ```bash
   ssh root@192.168.50.33 'df -h /'
   ```

## Run the codified upgrade

From an interactive clone (needs `-e seerr_upgrade=true`; the guard makes it
refuse `--check`):

```bash
cd media-iac/ansible
ansible-playbook -i inventory/hosts.yml playbooks/configure-media.yml \
  --limit seerr -e seerr_upgrade=true -e seerr_version=3.3.0
```

What the task does (mirrors how the box was installed — community-scripts build):
1. `systemctl stop seerr`
2. Back up `/opt/seerr/config` → `…/config.bak-<ts>`
3. Fetch `https://github.com/seerr-team/seerr/archive/refs/tags/v3.3.0.tar.gz`
4. **Clean-deploy:** remove the old app tree (keeping `config` + `config.bak-*`),
   then extract fresh (`--strip-components=1`). Extracting *over* the old tree
   leaves stale files — 3.3.0 dropped `src/components/ToastContainer` and the
   `react-toast-notifications` dep, and a leftover 3.1.0 file fails the type-check.
5. `CYPRESS_INSTALL_BINARY=0 pnpm install --frozen-lockfile`
6. `NODE_OPTIONS=--max-old-space-size=3072 pnpm build`
7. `systemctl start seerr`, then poll `http://127.0.0.1:5055/api/v1/status` until 200

## Verify — assert the DATA, not just that it answers

Version + 200 are necessary and **nowhere near sufficient** (see the warning at the
top). Check the database first; a fresh sqlite file is ~4096 bytes.

**1. File size — the dependency-free check.** `sqlite3` is *not* installed on 101,
so do not reach for it; this works anywhere:

```bash
ssh root@192.168.50.33 'ls -l /opt/seerr/config/db/db.sqlite3*'
```

A healthy database is **~344 KB with a multi-MB `-wal`** (measured 2026-08-13:
`344064` bytes). **4096 bytes is an empty sqlite file** — that is the failure
signature, and it is what the 3.4.1 incident produced while every health check
passed.

**2. Row counts, via the API** (no extra packages, and it proves the app can
actually read the data rather than just that a file is the right size):

```bash
ssh root@192.168.50.33 '
  K=$(jq -r ".main.apiKey // empty" /opt/seerr/config/settings.json 2>/dev/null)
  curl -sS -H "X-Api-Key: $K" http://127.0.0.1:5055/api/v1/request/count'
```

Compare against pre-upgrade. As of 2026-08-13 the live instance returns
**`{"total":178,"movie":107,"tv":71,…}`**. A total in the single digits means you
are looking at a fresh database, not an upgraded one.

Only once the row counts survive:

```bash
ssh root@192.168.50.33 'grep "\"version\"" /opt/seerr/package.json | head -1'
curl -fsS http://192.168.50.33:5055/api/v1/status
```
Then log into the WebUI and confirm requests/library resolve.

**Do not delete the old tree or the config backup until the row counts check out.**
Destructive cleanup must depend on the data assertion, not on the service starting.

## Rollback

No snapshot (thick LVM), so restore from the tarball + data backup:
```bash
ssh root@192.168.50.33 '
  systemctl stop seerr
  find /opt/seerr -mindepth 1 -maxdepth 1 ! -name "config*" -exec rm -rf {} +
  tar xzf /root/seerr-<old>-backup.tgz -C /opt --strip-components=0
  systemctl start seerr'
```
(If the data dir itself is suspect, also restore `/opt/seerr/config.bak-<ts>`.)
Once the new version is confirmed healthy **by the row counts in § Verify — not by
a 200** — delete the backups to reclaim space:
`rm /root/seerr-*-backup.tgz && rm -rf /opt/seerr/config.bak-*`.
