#!/usr/bin/env bash
# test-tf-plan-media.sh — prove tf-plan-media.sh keeps the Vault root token out of curl's
# argument list and fails when a secret does not come back (MED-11).
#
#   scripts/test-tf-plan-media.sh
#
# It stubs `security`, `curl` and `terraform` on PATH, so it reads no Keychain, reaches no
# Vault and plans nothing. The curl stub records its argv and reads its stdin config.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
TOKEN="s.canary-root-token-0123456789"

cat >"$TMP/bin/security" <<EOS
#!/bin/sh
printf '%s\n' "$TOKEN"
EOS
cat >"$TMP/bin/curl" <<'EOS'
#!/bin/sh
echo "$*" >>"$CURL_ARGV"
case "$*" in *' -K - '*) cat >>"$CURL_STDIN" ;; esac
[ -z "${CURL_FAIL:-}" ] || exit 22
echo '{"data":{"data":{"access_key":"a","secret_key":"b","api_token":"c","public_key":"d"}}}'
EOS
cat >"$TMP/bin/terraform" <<'EOS'
#!/bin/sh
echo "Plan: 0 to add, 0 to change, 0 to destroy."
EOS
chmod +x "$TMP/bin/"*

run() {
  env -u AWS_ACCESS_KEY_ID PATH="$TMP/bin:$PATH" CURL_ARGV="$TMP/argv" CURL_STDIN="$TMP/stdin" \
    OUT="$TMP/plan.txt" "$@" "$HERE/tf-plan-media.sh" >"$TMP/out" 2>&1
}

: >"$TMP/argv"; : >"$TMP/stdin"
run env || { cat "$TMP/out"; echo "FAIL: the script failed on a good run" >&2; exit 1; }
[ -s "$TMP/argv" ] || { echo "FAIL: curl was never called, so nothing was examined" >&2; exit 1; }
if grep -q "$TOKEN" "$TMP/argv"; then echo "FAIL: the root token is in curl's argv" >&2; exit 1; fi
grep -q "$TOKEN" "$TMP/stdin" || { echo "FAIL: the token did not reach curl on stdin" >&2; exit 1; }
grep -q -- '--cacert' "$TMP/argv" || { echo "FAIL: curl ran without --cacert" >&2; exit 1; }
if grep -qE '(^| )-[a-zA-Z]*k([a-zA-Z]* |$)|--insecure' "$TMP/argv"; then echo "FAIL: TLS verification is off" >&2; exit 1; fi
echo "ok: token on stdin only, $(wc -l <"$TMP/argv" | tr -d ' ') curl calls, TLS verified"

if run env CURL_FAIL=1; then echo "FAIL: the script passed although curl failed" >&2; exit 1; fi
echo "ok: a failed Vault read fails the script"
