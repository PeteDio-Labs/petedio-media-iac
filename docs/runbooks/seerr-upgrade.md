# Runbook — Seerr upgrade (3.1.0 → 3.3.0)

**Status: APPLIED 2026-07-14 (3.1.0 → 3.3.0).** The upgrade is also captured as a
guarded Ansible task (`roles/seerr/tasks/upgrade.yml`) that stays OFF by default
for future version bumps. This runbook is the authoritative procedure; run it
deliberately, not as part of a capture pass.

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

## Verify

```bash
ssh root@192.168.50.33 'grep "\"version\"" /opt/seerr/package.json | head -1'   # -> 3.3.0
curl -fsS http://192.168.50.33:5055/api/v1/status                                # -> 200 JSON
```
Log into the WebUI, confirm requests/library still resolve.

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
Once 3.3.0 is confirmed healthy, delete the backups to reclaim space:
`rm /root/seerr-*-backup.tgz && rm -rf /opt/seerr/config.bak-*`.
