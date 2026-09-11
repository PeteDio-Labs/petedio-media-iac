# Runbook — Direct Play on plex-gpu

**Status: the role is written and validated against fixtures, not against 236.** No
one has run it on the server, so the first run is also the first ground-truthing of
the three preference keys. The role fails loudly if a key is wrong — see
§ "If the keys are wrong".

Plex has **no Direct Play switch.** Direct Play is the outcome of a negotiation
between the client and the server. The server's only part in that negotiation is a
set of ceilings that force a transcode whatever the client could have played. This
runbook lifts those ceilings.

## Context

Plex sorts each client into LAN or remote by matching its address against the LAN
Networks list, which defaults to the server's own subnets. plex-gpu (236) holds one
LAN address, `192.168.50.236`. The TVs reach it over the tailnet at
`100.97.96.88`, which sits outside `192.168.50.0/24`, so **Plex files your own TVs
as remote clients** and applies the remote ceilings to them. See the group comment
on `gpu-media` in `ansible/inventory/hosts.yml` for how the tailnet became that path.

`roles/plex-settings` converges three preferences over `/:/prefs`:

| Key | Value | Effect |
|---|---|---|
| `TreatWanIpAsLocal` | `1` | A remote address takes the local-quality path, which carries no ceiling. |
| `WanPerStreamMaxUploadRate` | `0` | No per-stream ceiling. |
| `WanTotalMaxUploadRate` | `0` | No total ceiling across remote streams. |

> ## ⚠ The ceilings come off for off-site clients too
>
> This does not distinguish a TV on the tailnet from a laptop in a hotel. Every
> remote client becomes eligible for the original file, so one large file can take
> the whole upload link.
>
> The narrower fix is to classify **only** the tailnet range as LAN, through
> `LanNetworksBandwidth`, and leave the ceilings standing for everyone else. That
> keeps off-site playback capped. Pick it if saturating the uplink matters more than
> off-site quality; see § Revert for how to get there.

## Run it

No trigger applies this. `ansible/**` sits in the `push` `paths-ignore` of
`.github/workflows/terraform.yml`, so **merging the change converges nothing.** Run
it yourself:

```bash
cd ansible
ansible-playbook playbooks/configure-plex-settings.yml --check   # read and report
ansible-playbook playbooks/configure-plex-settings.yml           # write
```

The `--check` run reads the values in force and prints each one against the value it
would write. It sends no write, so it skips the read-back assertion.

Writing over `/:/prefs` applies live. Plex needs no restart, and a stream already
running keeps the decision it started with, so the role holds no in-use guard.

**Record the before-values.** The role prints what each key held, in the "report what
is in force" task. Those values are what you put back, and this runbook is the only
place outside the vault that they exist.

## Verify

The role asserts that each value read back matches what it wrote. That proves the
server accepted the setting; it does not prove any client Direct Plays.

To check a real stream, start playback on a TV and read the session:

```bash
ssh root@192.168.50.236 \
  'TOK=$(grep -oE "PlexOnlineToken=\"[^\"]*\"" \
     "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml" \
     | sed "s/.*=\"//;s/\"//"); \
   curl -s -H "X-Plex-Token: $TOK" http://127.0.0.1:32400/status/sessions'
```

Look for `Direct Play` in the session's decision rather than `Transcode`. Settings >
Dashboard in the web UI shows the same thing.

**A client can still transcode after this.** A player set below Original quality
asks for a transcode, and the server obliges. Fix that on the device, under Settings
> Quality. That setting lives in each client app, so no Ansible in this repo reaches
it.

## If the keys are wrong

`/:/prefs` answers `200` for a key it has never heard of and changes nothing, so a
misspelling reads as success. The role guards that twice: it asserts each key exists
before writing any of them, and asserts each value reads back afterwards. A wrong key
fails the play and names itself.

To see what the server does know:

```bash
curl -H "X-Plex-Token: <token>" http://127.0.0.1:32400/:/prefs
```

Then correct the key in `roles/plex-settings/defaults/main.yml`.

## Revert

Put the ceilings back by overriding the three variables. Use the values the role
reported before it wrote:

```bash
ansible-playbook playbooks/configure-plex-settings.yml \
  -e plex_settings_treat_wan_as_local=false \
  -e plex_settings_wan_per_stream_max_kbps=2000 \
  -e plex_settings_wan_total_max_kbps=8000
```

Set the same values in `roles/plex-settings/defaults/main.yml` to make the revert
stick across runs.

To switch to the narrower fix instead, add `LanNetworksBandwidth` to
`plex_settings_prefs` with the tailnet range, and return the three keys above to
their original values. The existence check tells you on the first run whether the
server knows that key.

## Write it down in the vault

Plex's playback settings are configured through its API and live nowhere in git.
This role moves three of them into git; every other one stays invisible. Record the
change in `Systems/media-stack.md`, including the before-values, so a rebuild does
not silently restore the old behaviour.
