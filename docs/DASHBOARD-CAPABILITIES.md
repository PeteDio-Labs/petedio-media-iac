# Media dashboard — API capability review

**Status:** review only. Nothing is being built yet.
**Question asked:** can we get one surface that (1) traces a seerr request through
Sonarr/Radarr when something goes wrong, (2) shows exact episodes, and (3) updates
Plex and everything else from a button?

**Short answer:** yes to all three, and the reason is a single non-obvious fact —
seerr already stores the downstream Sonarr/Radarr row id and the Plex rating key on
every request, so the cross-app trace is a **join on stored ids, not a fuzzy title
match**. That is what makes this a small tool instead of a correlation engine.

But the update button should **not** be built on the APIs, and the whole thing
should not be built as "Mission Control v4". Both points below.

## Provenance of every claim here

I could not reach the LAN from the session this was written in (`192.168.50.0/24`
is unroutable from the cloud container), so nothing here was probed live. Each
claim is tagged:

| Tag | Means |
|---|---|
| **[live]** | This repo's Ansible already calls it against these exact hosts in production — proven |
| **[src]** | Read out of the upstream source for the version we run — accurate, but unverified on our boxes |
| **[probe]** | Expected, needs confirming |

`scripts/api-capability-probe.sh` turns every **[src]**/**[probe]** into **[live]**.
It is strictly read-only, runs each `curl` *on* the host over loopback so no API key
crosses the LAN, and prints response *shapes* rather than payloads:

```bash
./scripts/api-capability-probe.sh -v          # from the Mac, id_ed25519_ansible loaded
./scripts/api-capability-probe.sh -o ./probe-out   # keep the raw JSON
```

Run that before anyone writes a line of dashboard code. This repo's first golden
rule is ground-truth-before-docs, and the Linear inventory being wrong about media
VMIDs is precedent enough.

---

## 1. The join key — why this works at all

```
seerr request
  └─ .media.externalServiceId ──────────► Sonarr seriesId / Radarr movieId   [src]
       └─ /api/v3/episode?seriesId=…  ──► exact episodes, per-episode hasFile [src]
       └─ /api/v3/queue .downloadId   ──► torrent infohash                    [src]
            └─ qBittorrent /torrents/info?hashes=…  ──► state, seeds, ETA     [live]
                 ├─ /torrents/trackers?hash=…  ──► WHY it's dead ("unregistered") [probe]
                 ├─ /torrents/files?hash=…     ──► per-episode files in a pack  [probe]
                 └─ gluetun /v1/portforward    ──► is the tunnel port even right? [probe]
  └─ .media.ratingKey ──────────────────► Plex /library/metadata/{ratingKey}  [probe]
  └─ .media.serviceId ──────────────────► which Sonarr/Radarr instance        [src]
```

Confirmed on the `seerr-team/seerr` `Media` entity **[src]**: `serviceId`,
`externalServiceId`, `externalServiceSlug`, `ratingKey`, `mediaAddedAt`, `status`
(plus `*4k` twins for each). `externalServiceId` is the id *inside* Sonarr/Radarr —
so a request row points straight at the series, and `serviceId` says which instance
it went to.

`queue.downloadId` on the *arr side is the download client's id, which for a torrent
is the infohash — the same value qBittorrent keys on **[src]**. That closes the last
gap in the chain, request → torrent, with no name matching anywhere.

**If the probe shows `externalServiceId` is null on real requests, this whole design
changes** and everything below degrades to title/tmdbId matching. That single field
is the thing to check first.

## 2. What each API gives us

Ports, API versions and data paths below are the captured reality from
`ansible/inventory/host_vars/` — not assumptions.

### seerr (101 / .33 · `:5055` · `/api/v1` · `X-Api-Key`)

Key lives in `/opt/seerr/config/settings.json` **[probe]**. Overseerr-lineage API.

| Capability | Endpoint | Tag |
|---|---|---|
| List requests, filterable | `GET /request?take&skip&filter&sort&sortDirection&requestedBy&mediaType` | [src] |
| Status rollup for a header strip | `GET /request/count` | [src] |
| One request + joined `media`, `seasons`, `requestedBy` | `GET /request/{id}` | [src] |
| **Retry a failed push to the *arr** | `POST /request/{id}/retry` | [src] |
| Approve / decline | `POST /request/{id}/{status}` | [src] |
| Which Sonarr/Radarr instances exist | `GET /settings/sonarr`, `/settings/radarr` | [src] |

`filter` accepts `approved · pending · unavailable · failed · completed · available ·
deleted · processing` **[src]** — so "show me only the broken ones" is one call.

Status enums **[src]** (worth hardcoding, they are the vocabulary of the whole UI):

```
MediaRequestStatus:  1 PENDING · 2 APPROVED · 3 DECLINED · 4 FAILED · 5 COMPLETED
MediaStatus:         1 UNKNOWN · 2 PENDING · 3 PROCESSING · 4 PARTIALLY_AVAILABLE
                     5 AVAILABLE · 6 BLOCKLISTED · 7 DELETED
```

Note `4 PARTIALLY_AVAILABLE` — that is precisely the "some episodes landed, some
didn't" case, and it is the state the current workflow makes you dig for by hand.

### Sonarr / Radarr (104 /.15 · 105 /.16 · `:8989` / `:7878` · `/api/v3` · `X-Api-Key`)

Key + port read from `/var/lib/<app>/config.xml` **[live]** — the pattern the
`servarr` role already uses.

| Capability | Endpoint | Tag |
|---|---|---|
| **Exact episodes for a series** | `GET /episode?seriesId=&seasonNumber=&includeEpisodeFile=true` | [src] |
| Queue with failure detail | `GET /queue?pageSize&includeUnknownSeriesItems=true` | [src] |
| What's monitored and missing | `GET /wanted/missing?monitored=true&includeSeries=true` (paged, sorts on `episodes.airDateUtc`) | [src] |
| Grab/import history | `GET /history`, `GET /history/since` | [probe] |
| Health warnings | `GET /health` | [probe] |
| Version + update feed | `GET /system/status`, `GET /update` | [live] |
| Trigger a search | `POST /command` `{name: "EpisodeSearch", episodeIds: […]}` | [src] |
| **Blocklist a bad grab and re-search** | `DELETE /queue/{id}?removeFromClient=true&blocklist=true&skipRedownload=false` | [src] |
| Same, in bulk | `DELETE /queue/bulk` with `{Ids: […]}` | [src] |
| Monitor/unmonitor episodes | `PUT /episode/monitor` `{episodeIds, monitored}` | [src] |

The queue record is the richest object in the stack and carries exactly the fields
that answer "what went wrong" **[src]**: `errorMessage`, `statusMessages[]`,
`trackedDownloadStatus`, `trackedDownloadState`, `downloadId`, `downloadClient`,
`indexer`, `estimatedCompletionTime`, `outputPath`, `episodeHasFile`.

Command names are the C# class name minus the `Command` suffix, matched
case-insensitively **[src]** — so `ApplicationUpdate`, `EpisodeSearch`,
`MissingEpisodeSearch`, `RefreshSeries`, `RescanSeries`, `ManualImport`.

Radarr is the same shape with `movieIds` / `includeUnknownMovieItems` **[src]**.

### Lidarr (100 /.14 · `:8686`) and Prowlarr (109 /.20 · `:9696`) — both `/api/v1`

Same auth and the same `system/status`, `health`, `queue`, `update`, `command`
contract **[live]** for status/update; the media-shaped endpoints differ (albums vs
episodes). Prowlarr's value to a dashboard is `GET /indexer` — when nothing is being
found at all, a dead indexer is usually why, and that is currently a fourth tab to go
check.

### Plex (103 · `:32400` · `X-Plex-Token` header)

Token from `Preferences.xml` **[live]**. XML by default — send
`Accept: application/json`.

| Capability | Endpoint | Tag |
|---|---|---|
| Who is watching (already used as a stop-guard) | `GET /status/sessions` | [live] |
| Libraries + last scan time | `GET /library/sections` | [probe] |
| **Trigger a scan, optionally one path** | `GET /library/sections/{key}/refresh[?path=…]` | [probe] |
| Item by the rating key seerr stored | `GET /library/metadata/{ratingKey}` | [probe] |
| Server version / identity | `GET /` | [probe] |

### qBittorrent + Gluetun (110 /.21) — the deepest integration, and the most gotchas

This host is not one API, it is **three moving parts sharing one network namespace**:
gluetun (the tunnel), qbittorrent (`network_mode: service:gluetun`), and a `port-sync`
sidecar that copies gluetun's NAT-PMP forwarded port into qBit's listen port. Most
"everything is stalled" incidents in this stack originate here and surface three hops
upstream as a bland `stalledDL` in the Sonarr queue. Getting this integration right is
most of the diagnostic value of the whole tool.

#### qBittorrent WebUI API (`:8080` · cookie auth)

Login POST → `SID` cookie, then send it on every call **[live]** — already implemented
in `roles/media-lifecycle/tasks/in-use-qbittorrent-vpn.yml`.

| Capability | Endpoint | Tag |
|---|---|---|
| **Torrent by infohash — the join target** | `GET /torrents/info?hashes={downloadId}` | [live] |
| Filtered lists (`downloading`, `stalled`, `errored`, …) | `GET /torrents/info?filter=…` | [live] |
| **Which app owns it, without the hash** | `GET /torrents/info?category=tv-sonarr\|radarr` | [probe] |
| **Why a torrent is dead** — tracker status + message | `GET /torrents/trackers?hash=` | [probe] |
| **Per-file progress inside a season pack** | `GET /torrents/files?hash=` | [probe] |
| Deep detail (seeding time, reannounce, piece counts) | `GET /torrents/properties?hash=` | [probe] |
| Tunnel throughput + connection state | `GET /transfer/info` | [probe] |
| **Delta polling — one call for the whole UI** | `GET /sync/maindata?rid=N` | [probe] |
| Version (drives the naming gotcha below) | `GET /app/version` | [probe] |

Four things here matter more than the rest:

- **`/torrents/trackers` is the real error message.** The *arr queue tells you a
  download is stalled; the tracker record tells you *why* — its `status` enum
  (`0` disabled · `1` not contacted · `2` working · `3` updating · `4` not working)
  plus a `msg` string carrying things like `unregistered torrent`. That is the
  difference between "it's stuck" and "this release was nuked, blocklist it" — and
  it is currently invisible from every tab you'd think to check.
- **`/torrents/files` gives episode-level truth inside a season pack.** A single
  torrent holding S03E01–E10 is one opaque row in Sonarr's queue, but the file list
  shows per-file `progress` and `priority`. This is the missing half of "pull exact
  episodes": Sonarr knows which episodes it *wants*, qBittorrent knows which files
  in the pack have actually landed.
- **`/sync/maindata?rid=N` is what the WebUI itself uses.** It returns only what
  changed since revision `N`. A polling dashboard should use this rather than
  re-fetching `torrents/info` on a timer — one call, whole-state deltas.
- **Sonarr/Radarr set the category on every grab**, so `category` is a usable
  fallback join if a `downloadId` ever comes back empty.

#### Gotcha: this is qBittorrent 5.x, and 5.0 renamed the action endpoints

The stack pins `lscr.io/linuxserver/qbittorrent:latest` **[live]**, so it tracks 5.x.
qBittorrent 5.0 was a **breaking WebAPI change** **[src]**:

| Pre-5.0 | 5.x |
|---|---|
| `POST /torrents/pause` | `POST /torrents/stop` |
| `POST /torrents/resume` | `POST /torrents/start` |
| `?filter=paused` | `?filter=stopped` |

Most tutorials, older client libraries and LLM-recalled snippets still use the old
names, and they fail *silently-ish* rather than loudly. The read path this repo
already relies on (`filter=downloading`) is unaffected — but anything written for
Phase 2 must use `start`/`stop`. Confirm with `GET /app/version` before writing a
single action call.

#### Gluetun control API (`127.0.0.1:8000`) — already enabled, currently unused by us

`docker-compose.yml.j2` sets `HTTP_CONTROL_SERVER_ADDRESS: ":8000"` and publishes it
as `127.0.0.1:8000:8000` **[live]**. So the tunnel can be interrogated directly:

| Capability | Endpoint | Tag |
|---|---|---|
| Is the tunnel actually up | `GET /v1/vpn/status` | [probe] |
| **The forwarded port** (what port-sync is syncing) | `GET /v1/portforward` | [probe] |
| **Public egress IP** — the leak check, on demand | `GET /v1/publicip/ip` | [probe] |
| DNS state | `GET /v1/dns/status` | [probe] |

Two constraints, both from our own compose file:

- **It is bound to loopback deliberately** — "not reachable from the LAN". A
  dashboard running anywhere else therefore *cannot* reach it without either
  changing that binding (weakens the current posture) or reading it on-host over
  SSH the way the probe script does. This is an argument for the Phase 0 CLI, and
  against a remote web service, at least for the VPN panel.
- **The control API requires auth** — our own compose comment records that a custom
  healthcheck against it would 401. Whatever credential `port-sync` uses has to be
  found before this is usable; it is not in the repo.

This turns the stack-up leak check — currently a once-per-boot assertion in
`stack-up.yml` — into something continuously observable, which is strictly better.

#### The `port-sync` sidecar is the stack's least-visible single point of failure

`port-sync.sh` is mounted from `/opt/qbittorrent-vpn/port-sync/port-sync.sh` on the
host and is **not rendered from this repo** **[live]** — like `.env`, it is
unmanaged. It re-syncs every 300s. If it dies, or if ProtonVPN rotates the forwarded
port and the sync silently fails, qBittorrent keeps listening on a stale port,
incoming connections stop, torrents drift to zero seeds, and Sonarr reports
`stalledDL` — with nothing anywhere in the *arr tabs pointing at the real cause.

A dashboard that shows **gluetun's `/v1/portforward` next to qBit's
`app/preferences.listen_port`** makes that entire failure class a glance instead of
an investigation. That single comparison is arguably the highest-value widget in the
whole proposal, and it costs two GETs.

(Templating `port-sync.sh` into this repo is a separate, smaller task worth doing on
its own merits — the README already flags the compose file's unmanaged `.env` as
blocked on getting the Proton key into the media Vault scope.)

---

## 3. The update button — build it on Ansible, not on the APIs

This is the one place where the obvious design is wrong. Only **four of the seven**
services can update themselves over an API:

| Service | Self-update over API? | The actual supported path |
|---|---|---|
| sonarr · radarr · lidarr · prowlarr | **Yes** — `POST /command {ApplicationUpdate}` | Already how `roles/servarr` does it **[live]** |
| **plex** | **No** | apt from `repo.plex.tv`. Plex's `/updater/*` endpoints exist, but repository updating is the supported mechanism for Linux packages — the Linux ecosystem is full of third-party update scripts precisely because PMS does not self-update from a distro package. The probe records what `/updater/status` actually returns on our box. |
| seerr | **No** | No release assets published at all — source tag + `pnpm build` **[live]** |
| qbittorrent-vpn | **No** | `docker compose pull` against digest comparison **[live]** |

So an API-driven "update everything" button would cover Sonarr/Radarr/Lidarr/Prowlarr
and silently do nothing for Plex — which is the one the question actually named.

More importantly, `playbooks/update-media.yml` already does all seven *and* carries
guards that took real work to get right and that a dashboard would be reimplementing
from zero:

- refuses to restart Plex while someone is watching, and qBittorrent while something
  is downloading (skip-not-fail, with overrides)
- verifies each *arr actually came back **on the target version** — a 200 on the old
  version is treated as a failed update, not a success
- atomic tree swap with rollback and a disk-space precheck for the seerr build
- asserts the VPN egress still differs from the host's after a qBit update
- recreates gluetun's dependents correctly so the tunnel namespace isn't stranded

**Recommendation:** the button calls `workflow_dispatch` on a new
`.github/workflows/ansible-media.yml` running on the existing self-hosted homelab
runner. That reuses the Vault-OIDC path already wired for CI, produces an audit trail
and streaming logs for free, and adds **no new long-running privileged service**.
`check-updates.yml` gives the same surface a read-only "what's stale" panel.
(`petedio-iac` already factored a reusable `ansible-stack.yml` under PET-250 — worth
mirroring rather than inventing.)

## 4. Auth is the hard part, and it is a real decision

Today every credential is read *on the host it belongs to* and used over loopback.
`roles/servarr` says so explicitly: *"Always talk to the app over loopback — the API
key never leaves the container."*

A dashboard cannot preserve that. It has to hold **seven credentials centrally** — four
*arr API keys, the seerr key, the Plex token, the qBit password — and each *arr key is
equivalent to full control of that app. That makes the dashboard the most
privilege-concentrated thing in the media stack.

What follows from that:

- Keys belong in Vault under the existing media scope (`kv/services/media/*`,
  alongside the pending qBittorrent secret), read at runtime — never in a config file
  in the repo, never baked into an image.
- The *arr keys are currently generated-and-forgotten in `config.xml`. Reading them
  into Vault is a **capture** task of the same kind as the rest of this repo.
- Anything with write endpoints exposed needs auth in front of it. Authentik/OIDC is
  the homelab's answer (PET-31 is parked) — until that exists, keep the tool
  read-only or LAN-only.
- The probe script deliberately does *not* centralise anything: it keeps the loopback
  property so that reviewing capabilities costs no new exposure.

## 5. Two prior dashboards were canceled — what that implies

- **PET-96** "Design the new homelab control surface" — canceled 3 days after
  starting. Scope was every system in the lab (Proxmox/Vault/Nexus/MinIO/OpenFaaS +
  Co-latro + media + HA), plus a form decision (kiosk vs web vs desktop), plus an AI
  backing decision.
- **PET-155** "Mission Control v3: read-only dashboard" — framed explicitly as the
  lesson: *"the dashboard as a viewer, not a system — the reason v1 and v2 died."*
  Canceled too, blocked on a data layer that did not exist yet.

The failure mode is consistent: **generic scope, and no data layer to start from.**

This request is the opposite on both counts, and that is the case for it succeeding
where those didn't. The scope is one workflow ("why is this request not playable"),
and the data layer already exists and is already exercised in production by this
repo's Ansible. Keeping it that way is the whole discipline:

> It answers "where is this request stuck" and "update the stack". It is not a
> homelab dashboard, it does not render Proxmox, and it does not grow a plugin system.

## 6. Buy before build, for part of it

| Tool | Solves | Verdict |
|---|---|---|
| **Cleanuparr** / **Decluttarr** | Watch the *arr queues, remove stalled/blocked/zero-seeder items, trigger a fresh search — self-healing queues | Genuinely overlaps the pain. Worth evaluating **first** — it may delete a chunk of the manual triage without any UI |
| **Homarr** / **Homepage** | Per-service widgets side by side | Fine for an "is it all up" strip. Does **not** join a request to its download to its Plex item — the tabs stay separate, which is the actual complaint |
| **Huntarr** | Hunts missing/upgradable media | Adjacent, not this |

The joined per-request trace is the part with no off-the-shelf answer. The
auto-remediation part has several, and they are mature.

## 7. Recommended shape

**Phase 0 — `media-trace` CLI (a few hours, no infra).** One command:
`media-trace "The Bear" s03e07` → prints the chain: request state → media status →
Sonarr series/episode → queue record with `errorMessage` → torrent state → Plex
presence. Pure reads. This proves every join for real, and per the PET-155 lesson the
data layer should decide what's renderable *before* anything is rendered. If the
joins hold, the UI is a thin skin over a working library; if `externalServiceId`
turns out to be null, we found out at a cost of one afternoon.

**Phase 1 — read-only web view.** The triage table: one row per active request,
columns for each hop, colour-coded by where it is stuck. Plus a stale-version panel
fed by `check-updates.yml`. Still zero write endpoints, so still no auth blocker.

**Phase 2 — the buttons.** Retry request · search episode · blocklist-and-redownload
· scan Plex library · run the update playbook. Each one maps to exactly one call
already listed above. This is the phase that needs Vault-held credentials and auth in
front, and it should not start until Phase 1 has been in use long enough to know
which five buttons actually matter.

**Where it runs:** an LXC captured the same way as everything else here, or — if the
CLI turns out to be enough — nothing new at all. Deciding that now would be
premature.

### The failure taxonomy this is all really for

Every one of these is currently a manual hop between four tabs, and every one is a
single field once the join exists:

| Where it's stuck | How you know | One-click fix |
|---|---|---|
| Awaiting approval | `request.status = 1` | `POST /request/{id}/approve` |
| Approved, never reached the *arr | `status = 2` but `media.externalServiceId` is null | `POST /request/{id}/retry` |
| In the *arr, nothing found | appears in `wanted/missing`, absent from `queue` | `POST /command {EpisodeSearch}`; check Prowlarr `GET /indexer` |
| Grabbed, release is dead | torrent `num_seeds: 0` **and** `trackers[].msg` says `unregistered torrent` | `DELETE /queue/{id}?blocklist=true` — blocklist so it isn't re-grabbed |
| Grabbed, stalled, tracker fine | `state: stalledDL`, tracker `status: 2` (working) | `POST /torrents/reannounce`; if it persists, suspect the port ↓ |
| **Whole client stalled — VPN port** | gluetun `/v1/portforward` ≠ qBit `listen_port`; everything at zero seeds at once | restart `port-sync`; the tell is *many* torrents stalling together, not one |
| Tunnel down entirely | gluetun `/v1/vpn/status` not running; `/v1/publicip/ip` equals the host's | `docker compose restart gluetun` (recreates dependents — see README) |
| Season pack half-landed | torrent `progress` < 1 but some `/torrents/files` entries at `progress: 1` | usually just wait; per-file view says which episodes are already there |
| Downloaded, import blocked | `trackedDownloadState: importBlocked` + `statusMessages[]` | blocklist-and-redownload, or `ManualImport` |
| Imported, not in Plex | *arr `hasFile: true`, `media.ratingKey` null | `GET /library/sections/{key}/refresh?path=…` |
| In Plex, seerr still says unavailable | `media.status != 5` while `ratingKey` is set | seerr availability-sync job |

## 8. Open questions

1. **Does `media.externalServiceId` come back populated?** Everything hinges on it.
   Run the probe.
2. **Cleanuparr first?** If self-healing queues removes most of the triage, Phase 1
   shrinks to a viewer and Phase 2 may never be needed.
3. **Read-only for how long?** Write endpoints are what force the auth decision, and
   PET-31 (Authentik) is parked.
4. **Does the CLI satisfy the actual need?** If `media-trace` answers the question in
   one command from the terminal you already have open, a web UI may be ceremony.
5. **New LXC, or ride an existing host?** Only worth answering after Phase 0.
