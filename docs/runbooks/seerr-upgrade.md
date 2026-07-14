# Runbook — Seerr upgrade (3.1.0 → 3.3.0)

**Status: CODIFIED, NOT RUN.** The upgrade is captured as a guarded Ansible task
(`roles/seerr/tasks/upgrade.yml`) that is OFF by default. This runbook is the
authoritative procedure; run it deliberately, not as part of a capture pass.

## Context

- **Running:** Seerr **v3.1.0** (LXC 101 / .33, systemd `seerr.service`, built from
  a release tarball at `/opt/seerr`, data in `/opt/seerr/config`).
- **Latest:** **v3.3.0** (2026-06-02, `seerr-team/seerr` — the Jellyseerr successor).
- **Security note:** the running 3.1.0 already includes that release's CVE fixes
  (CVE-2026-27707 / -27793 / -27792), so this is a catch-up, not an emergency.

## Pre-flight (do this first)

1. **Snapshot the container** (instant rollback if the build/boot fails):
   ```bash
   ssh root@192.168.50.10 'pct snapshot 101 pre-seerr-330 --description "before 3.1.0->3.3.0"'
   ```
2. Confirm free space on the rootfs (build + node_modules ~2.4G):
   ```bash
   ssh root@192.168.50.33 'df -h /opt/seerr'
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
4. Extract over `/opt/seerr` (`--strip-components=1`; the `config/` data dir is left in place)
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

```bash
ssh root@192.168.50.10 'pct rollback 101 pre-seerr-330'
```
(or restore `/opt/seerr/config.bak-<ts>` and reinstall 3.1.0). Remove the snapshot
once 3.3.0 is confirmed healthy: `pct delsnapshot 101 pre-seerr-330`.
