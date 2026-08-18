# Media dashboard — API capability review

**Status:** review only. Nothing is being built yet.
**Companion:** [DASHBOARD-BACKEND.md](DASHBOARD-BACKEND.md) — how the thing that calls
these APIs would actually be built (runtime, credentials, collector, storage, deployment).
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

This document was written from source, without LAN access (`192.168.50.0/24` is
unroutable from a cloud container). Each claim is tagged:

| Tag | Means |
|---|---|
| **[live]** | Confirmed against these exact hosts — by this repo's production Ansible, or by the probe run below |
| **[src]** | Read out of the upstream source for the version we run — accurate, but unverified on our boxes |
| **[probe]** | Expected, needs confirming |

```bash
./scripts/api-capability-probe.sh -v          # from the Mac, id_ed25519_ansible loaded
./scripts/api-capability-probe.sh -o ./probe-out   # keep the raw JSON
```

### Probe run 2026-08-13 — 39 answered · 1 did not · 1 skipped

All seven hosts reached, every capability in this document exercised. **The headline:
the join holds.** `externalServiceId` comes back populated, so §7 Phase 0 is unblocked
and nothing below degrades to title matching. Details in §1 and §8.1.

The single remaining "did not" is Prowlarr's `/queue` (a real 404, below); the single
skip is gluetun's `/v1/vpn/status` (401, below). Nothing else is unproven.

Four things the run changed, each of which had been asserted here and was wrong:

- **Prowlarr has no `/queue`** — it is a hard `404`, not an empty list. §2 claimed
  Prowlarr shares the *arr queue contract. It does not.
- **Gluetun's control API auth is per-route, not global.** `/v1/portforward` and
  `/v1/publicip/ip` answer **unauthenticated**; only `/v1/vpn/status` 401s. The
  "find the credential before this is usable" blocker in §2 does not apply to the
  one comparison that matters.
- **`port-sync` was healthy at the 2026-08-13 probe** — gluetun's forwarded port and qBittorrent's
  `Session\Port` are both `43971`. The failure mode §2 describes is real; it is just
  not firing as of that probe.
- **qBittorrent's API is not reachable the way this doc assumed** — it has no WebUI
  password at all, and its subnet allowlist cannot be reached from the LXC host
  because Docker SNATs host-origin traffic to the bridge gateway. Finding that out
  cost an hour-long IP ban. It also means `media-lifecycle`'s qBittorrent in-use
  guard has never worked. See §2's auth note — the one real operational problem the
  run surfaced.

> The probe itself was also broken on first contact: `declare -A` on a bash-3.2 Mac
> meant it had never run anywhere, and a `jq -R` wrapper was reporting a green YES
> for the body `Forbidden`. Both fixed. The lesson is the repo's own first golden
> rule — ground-truth before docs, and *run the thing that does the ground-truthing.*

---

## 1. The join key — why this works at all

```
seerr request
  └─ .media.externalServiceId ──────────► Sonarr seriesId / Radarr movieId   [live]
       └─ /api/v3/episode?seriesId=…  ──► exact episodes, per-episode hasFile [live]
       └─ /api/v3/queue .downloadId   ──► torrent infohash                    [live]
            └─ qBittorrent /torrents/info?hashes=…  ──► state, seeds, ETA     [live]
                 ├─ /torrents/trackers?hash=…  ──► WHY it's dead ("unregistered") [live]
                 ├─ /torrents/files?hash=…     ──► per-episode files in a pack  [live]
                 └─ gluetun /v1/portforward    ──► is the tunnel port even right? [live]
  └─ .media.ratingKey ──────────────────► Plex /library/metadata/{ratingKey}  [live]
  └─ .media.serviceId ──────────────────► which Sonarr/Radarr instance        [live]
```

Confirmed on the `seerr-team/seerr` `Media` entity **[src]**: `serviceId`,
`externalServiceId`, `externalServiceSlug`, `ratingKey`, `mediaAddedAt`, `status`
(plus `*4k` twins for each). `externalServiceId` is the id *inside* Sonarr/Radarr —
so a request row points straight at the series, and `serviceId` says which instance
it went to.

`queue.downloadId` on the *arr side is the download client's id, which for a torrent
is the infohash — the same value qBittorrent keys on **[src]**. That closes the last
gap in the chain, request → torrent, with no name matching anywhere.

### Confirmed live, 2026-08-13 — the design holds

This was the one field the whole thing hung on. It is populated.

A real request, straight out of the probe (178 requests in the instance —
107 movie / 71 tv, 74 processing, 104 completed):

```json
{ "id": 174, "status": 5, "type": "movie",
  "media": { "tmdbId": 49018, "status": 5,
             "serviceId": 0, "externalServiceId": 118,
             "externalServiceSlug": "49018", "ratingKey": "4536" } }
```

`externalServiceId: 118` → Radarr `movieId` 118. `ratingKey: "4536"` → the Plex item.
`serviceId: 0` → which Radarr instance. Every hop is a stored id.

The other half of the chain is confirmed too — a live Sonarr queue record:

```json
{ "title": "Big Brother US S28E18 1080p HEVC x265-MeGusta",
  "trackedDownloadState": "downloading", "downloadClient": "qBittorrent",
  "downloadId": "521A893713E97755CD09E673525A4372F7202B4B",
  "indexer": "The Pirate Bay (Prowlarr)", "errorMessage": null }
```

`downloadId` is a 40-character hex infohash — exactly the key qBittorrent's
`/torrents/info?hashes=` takes. **Request → torrent is a join, with no title
matching at any hop.** That was the premise of this document and it is measured
rather than assumed.

## 2. What each API gives us

Ports, API versions and data paths below are the captured reality from
`ansible/inventory/host_vars/` — not assumptions.

### seerr (101 / .33 · `:5055` · `/api/v1` · `X-Api-Key`)

Key lives in `/opt/seerr/config/settings.json` **[live]**. Overseerr-lineage API.

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
| Health warnings | `GET /health` | [live] |
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

Same auth and the same `system/status`, `health`, `update`, `command` contract
**[live]**; the media-shaped endpoints differ (albums vs episodes).

**`queue` is NOT part of that shared contract.** Lidarr has one; Prowlarr's
`/api/v1/queue` returns **HTTP 404** **[live]** — it manages indexers, it does not
run downloads, so it has no queue to expose. An earlier draft of this section listed
`queue` as common to both. Anything iterating "the four *arrs" for queue rows has to
skip Prowlarr rather than treat the 404 as an outage.

Prowlarr's value to a dashboard is `GET /indexer` **[live]** — when nothing is being
found at all, a dead indexer is usually why, and that is a fourth tab to go
check.

### Plex (103 · `:32400` · `X-Plex-Token` header)

Token from `Preferences.xml` **[live]**. XML by default — send
`Accept: application/json`.

| Capability | Endpoint | Tag |
|---|---|---|
| Who is watching (already used as a stop-guard) | `GET /status/sessions` | [live] |
| Libraries + last scan time | `GET /library/sections` | [live] |
| **Trigger a scan, optionally one path** | `GET /library/sections/{key}/refresh[?path=…]` | [probe] |
| Item by the rating key seerr stored | `GET /library/metadata/{ratingKey}` | [probe] |
| Server version / identity | `GET /` | [live] |

### qBittorrent + Gluetun (110 /.21) — the deepest integration, and the most gotchas

This host is not one API, it is **three moving parts sharing one network namespace**:
gluetun (the tunnel), qbittorrent (`network_mode: service:gluetun`), and a `port-sync`
sidecar that copies gluetun's NAT-PMP forwarded port into qBit's listen port. Most
"everything is stalled" incidents in this stack originate here and surface three hops
upstream as a bland `stalledDL` in the Sonarr queue. Getting this integration right is
most of the diagnostic value of the whole tool.

#### qBittorrent WebUI API (`:8080`) — auth is not what this repo assumes

Login POST → `SID` cookie is what `roles/media-lifecycle/tasks/in-use-qbittorrent-vpn.yml`
implements. **That is not how access actually works on 110, and the difference bit us.**

Live config on the host **[live]**:

```
WebUI\AuthSubnetWhitelist=127.0.0.1/32, 192.168.50.0/24
WebUI\AuthSubnetWhitelistEnabled=true
```

**There is no `WebUI\Password_PBKDF2` in that config at all, and no `WebUI\Username`.**
qBittorrent has no WebUI password. The allowlist *is* the access control.

So `QBIT_WEBUI_PASSWORD` in `/opt/qbittorrent-vpn/.env` is a **phantom credential** —
there is nothing for it to match, and logging in with it cannot succeed no matter how
many times it is tried. Five tries ban the source IP for an hour.

### …and the allowlist is unreachable from the LXC host

This is the part that makes the whole thing counter-intuitive, and it is why the
first read of this looked like "the password went stale":

```
curl localhost:8080  ON LXC 110      →  Forbidden   (always)
docker exec qbittorrent curl …       →  v5.2.3      (always)
```

qBittorrent shares gluetun's netns and the WebUI is published `8080:8080` on the
`qbittorrent-vpn_default` bridge (gluetun at `172.18.0.2`, gateway `172.18.0.1`). A
request **originating on the host** to `localhost:8080` is SNAT'd to `172.18.0.1`
before qBittorrent sees a source address — and `172.18.0.1` is in neither
`127.0.0.1/32` nor `192.168.50.0/24`. It is refused every time, with no password to
fall back on.

Inside the namespace the source genuinely *is* `127.0.0.1`, the allowlist applies, and
everything answers. That is exactly what the container's own healthcheck does
(`curl -fsS http://localhost:8080/api/v2/app/version`), which is why it has reported
`healthy` for 26 hours throughout all of this. **The healthcheck and the host were
never testing the same path.**

Anything reading this API from LXC 110 must therefore go through `docker exec` — which
is what the probe does, and why its qBittorrent section went from 1/6 to 7/7.

The probe's first live run did the worst available combination: a host-side curl (never
allowlisted) *plus* a login (never satisfiable) once **per probe**. Six probes exhausted
the counter and banned `127.0.0.1` for an hour.

A trap worth recording, because it cost a whole extra round of diagnosis: **a banned
host answers `Forbidden`, not the ban message.** Only `/auth/login` ever says "banned".
So "retry the login unless we look banned" cannot distinguish a first failure from a
hundredth — and worse, `Forbidden` is *also* the normal answer for a non-allowlisted
source, so the ban and the DNAT problem are indistinguishable from the host. Waiting the
ban out (66 minutes of polling) changed nothing, which is what finally pointed at the
real cause.

**Two things follow, and the second is the one that matters:**

1. Anything reading this API from LXC 110 should go through `docker exec`, not log in,
   and not "helpfully" retry when refused.
2. **`roles/media-lifecycle`'s qBittorrent guard takes exactly this broken path, and
   fails open on it.** `host_vars/qbittorrent-vpn.yml` sets
   `qbit_api: "http://localhost:8080"`, and Ansible's `uri` module runs on the target
   host — so the guard is the host-side curl described above. It gets `Forbidden`,
   every time, and has since the compose stack was built. Then the guard collapses
   *"I could not determine whether this is in use"* into *"it is not in use"*, so
   `stack-down.yml` will stop qBittorrent mid-download and report no reason not to.

   The `.env` password never worked, so this was never a regression — the fail-open
   default is what kept it invisible. See
   [GOTCHAS.md § "The in-use guards cannot say I could not tell"](GOTCHAS.md). The
   Plex guard shares the blind spot but expresses it differently — it crashes rather
   than permitting; see that section.

   This is the same shape as the seerr `creates:` incident in `.agent/lessons.md`: a
   check that cannot fail loudly is not a check. **Not fixed here** — failing closed
   changes shutdown behaviour and would start blocking qBittorrent stops immediately
   (its auth is broken), so it wants an operator's call, not a drive-by.

| Capability | Endpoint | Tag |
|---|---|---|
| **Torrent by infohash — the join target** | `GET /torrents/info?hashes={downloadId}` | [live] |
| Filtered lists (`downloading`, `stalled`, `errored`, …) | `GET /torrents/info?filter=…` | [live] |
| **Which app owns it, without the hash** | `GET /torrents/info?category=tv-sonarr\|radarr` | [probe] |
| **Why a torrent is dead** — tracker status + message | `GET /torrents/trackers?hash=` | [live] |
| **Per-file progress inside a season pack** | `GET /torrents/files?hash=` | [live] |
| Deep detail (seeding time, reannounce, piece counts) | `GET /torrents/properties?hash=` | [probe] |
| Tunnel throughput + connection state | `GET /transfer/info` | [live] |
| **Delta polling — one call for the whole UI** | `GET /sync/maindata?rid=N` | [live] |
| Version (drives the naming gotcha below) | `GET /app/version` | [live] |

Four things here matter more than the rest:

- **`/torrents/trackers` is the real error message.** The *arr queue tells you a
  download is stalled; the tracker record tells you *why* — its `status` enum
  (`0` disabled · `1` not contacted · `2` working · `3` updating · `4` not working)
  plus a `msg` string carrying things like `unregistered torrent`. That is the
  difference between "it's stuck" and "this release was nuked, blocklist it" — and
  it is invisible from every tab you'd think to check.
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

#### Gluetun control API (`127.0.0.1:8000`) — already enabled, unused

`docker-compose.yml.j2` sets `HTTP_CONTROL_SERVER_ADDRESS: ":8000"` and publishes it
as `127.0.0.1:8000:8000` **[live]**. So the tunnel can be interrogated directly:

| Capability | Endpoint | Tag |
|---|---|---|
| Is the tunnel actually up | `GET /v1/vpn/status` | **401 — needs auth** [live] |
| **The forwarded port** (what port-sync is syncing) | `GET /v1/portforward` | **open** [live] |
| **Public egress IP** — the leak check, on demand | `GET /v1/publicip/ip` | **open** [live] |
| DNS state | `GET /v1/dns/status` | [probe] |

Two constraints, one of which turned out to be smaller than it looked:

- **It is bound to loopback deliberately** — "not reachable from the LAN". A
  dashboard running anywhere else therefore *cannot* reach it without either
  changing that binding (weakens the current posture) or reading it on-host over
  SSH the way the probe script does. This one stands, and is an argument for the
  Phase 0 CLI over a remote web service, at least for the VPN panel.
- **~~The control API requires auth~~ — auth is PER-ROUTE, and the routes that
  matter are open** **[live]**. The compose comment (a healthcheck would 401) is
  true of `/v1/vpn/status`, and an earlier draft generalised that to the whole API.
  It does not hold: `/v1/portforward` and `/v1/publicip/ip` both answer
  unauthenticated on 110.

  So the highest-value widget in this proposal needs **no credential at all**:

  ```json
  GET /v1/portforward  →  {"port":43971,"ports":[43971]}
  GET /v1/publicip/ip  →  {"public_ip":"169.150.226.162","country":"Israel", …}
  ```

  Finding `port-sync`'s credential is still worth doing for `/v1/vpn/status`, but it
  is no longer a blocker on the port comparison or the leak check.

This turns the stack-up leak check — a once-per-boot assertion in
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
whole proposal, and it costs two GETs — **neither of which needs a credential**
(gluetun's `/v1/portforward` is unauthenticated, and qBit's port is also readable
straight from `qBittorrent.conf` as `Session\Port`, no API session at all).

**Measured 2026-08-13: healthy.** Both sides read from their own APIs:

```json
gluetun /v1/portforward   →  {"port":43971,"ports":[43971]}
qBit    /app/preferences  →  {"listen_port":43971,"random_port":false,"upnp":false}
```

All three containers up 26h. So the port-sync failure mode is real but not
firing — which also means the widget has a known-good baseline to have been built
against.

The two per-torrent diagnostics behind it are confirmed too: `/torrents/trackers`
returns the tracker rows with `status` and `msg` (DHT/PeX/LSD all `status: 2`,
working), and `/torrents/files` returns **48 files** for a season pack with per-file
`progress` — the episode-level truth inside a pack that §2 calls the missing half of
"pull exact episodes".

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

A dashboard cannot preserve that. It has to hold **six credentials centrally** — four
*arr API keys, the seerr key, and the Plex token — and each *arr key is equivalent to
full control of that app. That makes the dashboard the most privilege-concentrated
thing in the media stack.

**Six, not seven: there is no qBittorrent credential to hold.** Earlier drafts counted
a qBit password; it does not exist (no `WebUI\Password_PBKDF2` at all — the subnet
allowlist is the auth). A dashboard reaching qBittorrent does so from an allowlisted
source or not at all, which is a real constraint on *where it runs* rather than one
more secret to store. See § qBittorrent WebUI API.

What follows from that:

- Keys belong in Vault under the existing media scope (`kv/services/media/*`,
  alongside the pending qBittorrent secret), read at runtime — never in a config file
  in the repo, never baked into an image.
- The *arr keys are generated-and-forgotten in `config.xml`. Reading them
  into Vault is a **capture** task of the same kind as the rest of this repo.
- Anything with write endpoints exposed needs auth in front of it. Authentik/OIDC is
  the homelab's answer — but there is no live issue to wait on. PET-31 ("Epic D")
  was **Canceled** when epics became milestones (PET-40); the work sits in the
  Platform **Identity & SSO** milestone, which is parked at 0%. Until that moves,
  keep the tool read-only or LAN-only.
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
CLI turns out to be enough — nothing new at all. Deciding that up front would be
premature.

### The failure taxonomy this is all really for

Every one of these is a manual hop between four tabs, and every one is a
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

1. ~~**Does `media.externalServiceId` come back populated?**~~ **ANSWERED
   2026-08-13 — yes.** `externalServiceId`, `serviceId` and `ratingKey` are all set
   on real requests, and `queue.downloadId` is the torrent infohash. The join chain
   holds end to end; see §1. Phase 0 is unblocked.

   The probe surfaced one genuinely new question in its place, answered too:
   **`QBIT_WEBUI_PASSWORD` is a phantom** — qBittorrent has no WebUI password at all,
   and its allowlist is unreachable from the LXC host because of Docker's SNAT. The
   live question that remains is what to do about `media-lifecycle`, whose qBittorrent
   in-use guard has consequently never worked.
2. **Cleanuparr first?** If self-healing queues removes most of the triage, Phase 1
   shrinks to a viewer and Phase 2 may never be needed.
3. **Read-only for how long?** Write endpoints are what force the auth decision, and
   the Identity & SSO milestone (Authentik) is parked at 0%, and PET-31 itself is
   Canceled — so "wait for auth" means waiting on nothing scheduled.
4. **Does the CLI satisfy the actual need?** If `media-trace` answers the question in
   one command from the terminal you already have open, a web UI may be ceremony.
5. **New LXC, or ride an existing host?** Only worth answering after Phase 0.
