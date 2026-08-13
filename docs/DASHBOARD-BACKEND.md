# Media dashboard — backend design

Companion to [DASHBOARD-CAPABILITIES.md](DASHBOARD-CAPABILITIES.md), which
established *what the APIs can do*. This is *how the thing that calls them is
built*. Still design-stage — no code exists.

Everything here is shaped by four constraints the capability review turned up,
and they drive more of the design than any preference does:

1. **The joins are cheap, the credentials are not.** The data model is easy; holding
   seven credentials centrally is the actual cost.
2. **Gluetun's control API is loopback-bound on LXC 110.** A remote backend cannot
   reach the single most useful VPN signal without a deliberate posture change.
3. **Planned downtime is normal in this stack.** `stack-down.yml` exists, the *arr
   built-in updater restarts services mid-run, and a gluetun update recreates the
   whole compose stack. "Service not answering" is a routine state, not an incident.
4. **This is a diagnostic tool.** If it is down, it is down exactly when you need it.

---

## 1. Shape: one core, two frontends

```
        mediatrace/            core — joins, polling, no I/O policy
           ├── cmd/mtrace      CLI      · runs on the Mac · creds via SSH-on-host
           └── cmd/mtraced     daemon   · runs on an LXC  · creds from Vault
```

The core library does the joining and knows nothing about where credentials come
from or who is asking. Two thin frontends wrap it.

This is not architecture for its own sake — it falls out of constraint 4. The CLI
must keep working when the daemon is down, during a `stack-down`, or while the
dashboard host itself is being updated. It also means **Phase 0 needs no new secret
infrastructure at all**: the CLI reads each key on its own host over SSH exactly the
way `scripts/api-capability-probe.sh` already does, so nothing is centralised until
there is a daemon worth centralising for.

## 2. Runtime: Go

**Recommendation: Go. This is the one decision to confirm before any code is
written.**

The argument is deployment, not language taste. A single static binary makes the
Ansible role trivially idempotent — copy the binary, compare `--version`, restart the
unit — which is the same contract `roles/servarr` already implements. No runtime, no
venv, no `node_modules`, nothing to drift.

The counter-example is in this repo. `roles/seerr` documents what a
build-from-source Node app costs on an LXC:

> *"the single riskiest operation in this stack: it is the only update that can fail
> halfway and leave the service down, and it runs on a 12G disk"*

— hence `seerr_min_free_mb: 3072`, an 1800s build timeout, an atomic tree swap, a
rollback path, and `seerr_update_enabled: false` by default. That is the real price of
a second Node service here, and it is not worth paying for a status aggregator.

Go also happens to fit the workload: fan-out to seven services with per-service
timeouts, contexts, and independent circuit breakers is precisely what its
concurrency model is for.

**Honest counter:** Python/FastAPI is more idiomatic for an Ansible shop and faster to
prototype. If this never grows past the CLI, Python is a perfectly good answer and the
deployment argument mostly evaporates. The Go case gets strong specifically at the
daemon step. If you'd rather stay in Python, the rest of this document is unchanged
except §7's packaging.

## 3. Where it runs, and the Gluetun problem

A new LXC — call it `media-dash`. Sizing is small: **1 core, 512 MB, 4 G** on
`local-lvm`. A Go binary plus a SQLite file does not need more.

### This would be the repo's first greenfield apply

Every host in `environments/media/media.tf` got there by `terraform import` against a
running container. A new module block is the **first plan in this repo whose diff is a
create**, in a repo whose golden rule is *"Never `apply` against drift"* and whose CI
applies on merge. That is not a reason to avoid it, but the first apply deserves to be
watched rather than merged on a Friday.

`template_file_id` is in `lifecycle.ignore_changes` (it never round-trips on import),
so a greenfield create must get it right at creation time — it will not be corrected
later.

### VMID and IP — a decision, not a default

The captured hosts are the legacy 100–110 block. This section originally argued for
taking a 21x number on the grounds that the renumber was *deferred* and a new host
could set the precedent it would eventually want.

**That premise is wrong. PET-49 was Canceled on 2026-07-21, not deferred** — so
100–110 are permanent and there is no future renumber to align with. The argument
inverts with it: a 21x host would not be "temporarily mixed until PET-49 happens", it
would be permanently the odd one out, in service of a scheme nothing else will ever
adopt.

**Revised call: take the next free number in the legacy block.** The only reason to
prefer 21x was forward-compatibility with a migration that is not going to happen.
Worth Pedro confirming, since it reverses the earlier recommendation.

### Gluetun: three options, one recommendation

`/v1/portforward` vs qBit's `listen_port` is the highest-value comparison in the whole
proposal, and it is behind a loopback binding:

| Option | Cost |
|---|---|
| **(a) Rebind the control port to the LXC's LAN IP, keep auth** | One line in `docker-compose.yml.j2` — now templated in-repo, so it is a reviewable diff. The API already requires auth and the Proxmox firewall on 110 is already on. **Recommended.** |
| (b) Backend SSHes to 110 and curls loopback | Works, but the backend now holds an SSH key into a container — a strictly larger credential than the HTTP one it was avoiding |
| (c) VPN panel is CLI-only | Free, but drops the best signal from the surface that is meant to show it |

(a) is a deliberate posture change and should be reviewed as one. It is not a silent
widening: the port stays firewalled and authenticated, and the credential goes in
Vault with the rest.

## 4. Credentials

Today every key is read on the host it belongs to and used over loopback —
`roles/servarr` is explicit that *"the API key never leaves the container."* A daemon
cannot preserve that, so this needs to be done deliberately.

**Vault layout.** `kv/services/media/dashboard/` holding the seven credentials, read by
a new read-only `media-dashboard` policy and AppRole. Separate from the `ansible`
policy — the dashboard should not be able to read what Ansible can.

**The capture step comes first.** The four *arr keys exist only in each host's
`config.xml`; nothing has ever written them to Vault. That is a one-time Ansible task
(slurp → write) needing a policy with create/update on that path — the same shape as
the still-pending qBittorrent secret seed, which already has a runbook at
[runbooks/qbittorrent-vault-secret.md](runbooks/qbittorrent-vault-secret.md). Worth
doing both in one privileged session.

**Delivery.** Vault Agent with auto-auth, rendering an env file that systemd picks up
via `EnvironmentFile=`. The app stays ignorant of Vault, token renewal is the agent's
problem, and no secret is ever written into the repo or an image.

**Blast radius, stated plainly.** This LXC becomes the highest-value target in the
media stack: four *arr keys (each equivalent to full control of its app), the seerr
key, the Plex token, and the qBit password, all in one process. Phase 1 stays
read-only, the host keeps the Proxmox firewall on with only the UI port inbound, and
Phase 2 does not ship without auth in front of it.

## 5. Storage: SQLite, and it is disposable

A point-in-time poll cannot tell you a request has been stuck for three days, and
"stuck since" is most of the value. So there is state — but not much.

```sql
request_state (request_id PK, stage, since, last_seen, detail_json)   -- upserted
trace_event   (id PK, request_id, at, from_stage, to_stage)           -- append-only
action_log    (id PK, at, actor, action, target, result)              -- phase 2
service_state (service PK, reachable, version, last_ok, last_error)
```

SQLite, one file, no service. Postgres would mean a new daemon and a new backup
obligation for a few thousand rows.

**It is derived data.** Everything in it can be rebuilt by polling the services again.
That matters in a repo whose central promise is no-data-loss: losing this file is an
inconvenience, not a data-loss event, and it should be explicitly excluded from
whatever PET-48 concludes about volumes that matter. Prune `trace_event` past 30 days
and the file stays trivially small.

## 6. The collector

### Intervals, staggered

| Source | Interval | Notes |
|---|---|---|
| seerr `/request` | 60 s | only active filters — `processing`, `pending`, `failed`, `unavailable` |
| *arr `/queue` | 20 s | **once per app**, indexed by `seriesId`/`movieId` — never per request |
| *arr `/episode?seriesId=` | on demand, cached | invalidated when that series' queue rows change |
| qBit `/sync/maindata?rid=N` | 10 s | rid-based deltas, which is what makes this cheap |
| Plex `/status/sessions` | 30 s | |
| gluetun `/v1/portforward` + `/v1/vpn/status` | 60 s | compared against qBit `listen_port` |
| `/system/status` + `/update` (all) | 15 min | feeds the stale-version panel |

`/sync/maindata` is the reason qBittorrent polling is nearly free — it returns only
what changed since revision `N`, which is what the qBit WebUI itself does. Everything
else is a handful of requests per minute across seven services.

### Downtime is a state, not an alarm

Constraint 3 is a design requirement, not a caveat. Each service gets its own circuit
breaker with exponential backoff, and the model distinguishes three things:

- **ok** — answering
- **degraded** — not answering, but expected (a playbook is running, an *arr is
  mid-`ApplicationUpdate`, gluetun is recreating its dependents)
- **unknown** — not answering, unexpected

The *arr built-in updater deliberately takes the service down mid-swap — `roles/servarr`
already tolerates connection failures while polling for it. A collector that pages on
that would cry wolf every single update. Simplest workable signal: the update playbook
drops a marker the daemon can read; absent that, treat any service that went away
within N seconds of a version change as `degraded`.

### Single-flight and cache

Browser tabs must not multiply upstream load. One in-flight fetch per source, shared
across all readers; the HTTP layer serves the last good snapshot with its age attached.

## 7. The join engine

The failure taxonomy in the capability review is not documentation — it is the state
machine. Each trace resolves to exactly one `stage`, and the taxonomy's rows are the
enum.

```
for each active request:
    resolve arr        := media.serviceId        → which Sonarr/Radarr
    resolve series     := media.externalServiceId → seriesId / movieId
    episodes           := cached /episode?seriesId=   (Sonarr only)
    queue rows         := batched /queue index, keyed by seriesId
    torrent            := qBit index, keyed by queue.downloadId (infohash)
    plex               := media.ratingKey presence
    → classify(stage)
```

Batching is the whole performance story: one `/queue` call per app and one qBit
snapshot serve every request in the table. Nothing is fetched per-request except
episodes, which are cached per series.

**Partial results are a first-class outcome.** Each hop carries its own status, so a
trace with Plex down renders seerr → arr → qBit and marks the Plex hop `unknown`
rather than failing the row. Given constraint 3, a design that needs all seven
services up to render anything would be unusable during exactly the situations it
exists for.

## 8. HTTP surface

| Route | Purpose |
|---|---|
| `GET /api/traces` | the triage table — one row per active request |
| `GET /api/traces/{requestId}` | one trace, every hop, full detail |
| `GET /api/services` | reachability + version of all seven (stale-version panel) |
| `GET /api/events` | SSE stream for live updates |
| `GET /healthz` | liveness, and the version the Ansible role reports |
| `POST /api/actions/{action}` | **Phase 2 only** — explicit allowlist, audit-logged |

SSE rather than websockets: the traffic is one-way, and SSE needs no protocol
upgrade, no reconnect logic worth speaking of, and no extra dependency.

Every Phase 2 action maps to exactly one upstream call from the capability review's
tables — no action composes several, because a half-applied composite is worse than
no button. Each writes an `action_log` row before and after.

## 9. The update button delegates to CI

Button → `workflow_dispatch` on a new `.github/workflows/ansible-media.yml` → the
existing self-hosted homelab runner → Vault OIDC → `update-media.yml`. The backend
then polls the run and streams status to the UI. It needs one more credential: a
fine-grained GitHub token scoped to `actions:write` on this repo alone, in Vault with
the others.

**Why not just run `ansible-playbook` on the dashboard host?** Because then it needs
the SSH key to every media host *and* the Vault credentials the playbook uses — it
stops being a client and becomes a control node, which is a far larger blast radius
than the one in §4. Delegating to CI also inherits the audit trail, the log UI, and
the Vault-OIDC path that already exist. The dashboard stays a thing that *asks*.

`petedio-iac` already factored a reusable `ansible-stack.yml` under PET-250; mirror it
rather than writing a fourth copy of the same job.

## 10. How it plugs into what already exists

The repo's contracts make this genuinely small. From `playbooks/media-roles.yml`:

> *"Every role ends by setting a `media_update_report` fact with a common shape […]
> The report play at the bottom is the only consumer, so adding a new service is
> 'write a role that sets that fact' and nothing else changes."*

So:

- **`ansible/roles/media-dashboard/`** sets `media_update_report` with
  `mechanism: "binary-swap"`, comparing the deployed `--version` against the release
  built by CI. It then appears in `check-updates.yml` with no change to the report
  template. The dashboard reports its own staleness through the same mechanism it
  displays — which is a decent smoke test of both.
- **`inventory/hosts.yml`** — one host under `media`, which picks up the `media-base`
  baseline for free. No new capability group; it is not a `servarr`.
- **`host_vars/media-dash.yml`** — `media_health_port`, `media_service_unit`, timezone.
- **Lifecycle ordering** — it consumes everything and produces nothing, so it belongs
  in the outermost tier: **down first, up last**, alongside plex/seerr. It has no
  in-use guard; nobody is harmed by restarting it.
- **CI** — the existing plan-on-PR covers the new module block with no workflow change.

## 11. What I would deliberately not build

Each of these is either a repeat of what killed PET-96/PET-155 or a cost with no
matching need:

- **No Prometheus/Grafana.** Mission Control v1 died on metrics aggregation.
- **No LLM in the loop.** PET-96 listed an "AI backing" decision among the things that
  made it unshippable.
- **No plugin system, no generic widgets.** The scope fence from the capability review
  holds: it answers "where is this request stuck" and "update the stack."
- **No auth server of its own.** Authentik is the homelab's answer, but nothing is
  scheduled: PET-31 is Canceled and the Identity & SSO milestone is parked at 0%.
  Read-only and LAN-bound until that changes.
- **No Postgres, no Redis, no message queue.** Seven services and a few thousand rows.
- **No websockets.**

## 12. Rough sequence

| | Work | Needs |
|---|---|---|
| **0** | Core library + `mtrace` CLI, creds over SSH | nothing new |
| **0.5** | Capture *arr keys into Vault (with the pending qBit secret) | one privileged Vault session |
| **1** | `media-dash` LXC (TF + Ansible role), daemon, read-only UI | §3 VMID decision, §4 AppRole |
| **1.5** | Gluetun control rebind + credential | §3(a) posture review |
| **2** | Actions + `ansible-media.yml` workflow | GitHub token, auth in front |

Phase 0 is the one that de-risks everything else: it proves `externalServiceId` is
populated and the joins hold, and it costs an afternoon. If it turns out the CLI
answers the question well enough from the terminal you already have open, phases 1–2
are optional — which is the honest test of whether this needs to be a service at all.
