# plex-public-probe

Source: `.github/workflows/plex-public-probe.yml`

| | |
|---|---|
| **Trigger** | `workflow_dispatch` with input `expected_sha`. |
| **Runner** | GitHub-hosted (`ubuntu-latest`) (off the LAN, on purpose). |
| **Touches** | Requests `/identity` on the public Plex port and compares a hash of the machine identifier. |
| **Vault** | None. |
| **Secrets** | `PLEX_PUBLIC_URL` (the public address, never printed). |
| **Gates** | Logs only a SHA-256 of the machine id. Proves the router forward, pve03's takeover of `.236` and the DNAT to 244 in one request. |
| **Run it** | `gh workflow run plex-public-probe.yml -f expected_sha=<hex>`. |
