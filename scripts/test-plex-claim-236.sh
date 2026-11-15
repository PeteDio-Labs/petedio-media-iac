#!/usr/bin/env bash
# test-plex-claim-236.sh — prove plex-claim-236.sh passes its two tokens to curl on stdin,
# and that the redeem step still redeems (MED-11).
#
#   scripts/test-plex-claim-236.sh
#
# It stubs curl on PATH, so it reaches no Plex and no plex.tv.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/plex-claim-236.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
cat >"$TMP/bin/curl" <<'EOS'
#!/bin/sh
echo "$*" >>"$CURL_ARGV"
case "$*" in *' -K - '*|*' -K -') cat >>"$CURL_STDIN" ;; esac
printf 200
EOS
chmod +x "$TMP/bin/curl"

# The script holds the redeem step as one single-quoted assignment. Run it as written.
REDEEM="$(grep '^REDEEM=' "$SCRIPT" | sed "s/^REDEEM='//; s/'\$//")"
[ -n "$REDEEM" ] || { echo "FAIL: no REDEEM step found in $SCRIPT, so nothing was examined" >&2; exit 1; }
: >"$TMP/argv"; : >"$TMP/stdin"
code="$(echo "claim-canary-token" | PATH="$TMP/bin:$PATH" CURL_ARGV="$TMP/argv" CURL_STDIN="$TMP/stdin" sh -c "$REDEEM")"
[ "$code" = 200 ] || { echo "FAIL: redeem printed '$code', not the HTTP code" >&2; exit 1; }
if grep -q 'claim-canary-token' "$TMP/argv"; then echo "FAIL: the claim token is in curl's argv" >&2; exit 1; fi
grep -q 'myplex/claim?token=claim-canary-token' "$TMP/stdin" || { echo "FAIL: the claim URL did not reach curl on stdin" >&2; exit 1; }

# The account token is read inside 244 by the mint step. Check the script text: no curl
# on that path may carry it as an -H argument.
if grep -nE 'curl[^|]*-H "X-Plex-Token' "$SCRIPT"; then echo "FAIL: the account token is a curl -H argument" >&2; exit 1; fi
grep -q 'header = \\"X-Plex-Token' "$SCRIPT" || { echo "FAIL: the mint step does not pass the token on stdin" >&2; exit 1; }
echo "ok: both tokens reach curl on stdin, redeem returns the HTTP code"
