#!/usr/bin/env bash
#
# seed-bazarr-vault.sh — write the OpenSubtitles.com login to
# kv/services/media/bazarr, then prove the write by reading it back. PET-852.
#
# Operator-run. No session runs it, and no value it handles is ever seen by one.
# Requires VAULT_ADDR, VAULT_CACERT and a token from `vault login` or VAULT_TOKEN.
#
# WHAT IT WRITES. Two fields, `username` and `password`, for an OpenSubtitles.com
# account (the free tier allows 20 downloads a day). roles/bazarr/tasks/vault.yml reads
# them as the `ansible` AppRole, whose policy covers kv/data/services/*, and passes
# them to Bazarr's opensubtitlescom provider.
#
# HOW A VALUE TRAVELS. From an env var or a silent `read -s` prompt into a shell
# variable, NUL-separated over a pipe to python3, which emits JSON piped to
# `vault kv put <path> -`. No argv, no temp file, no terminal echo, no disk. The
# read-back compares a SHA-256 digest, so a mismatch is debuggable without printing a
# value. This is the route seed-qbittorrent-vault.sh takes in petedio-iac (PET-110
# forbids a secret on argv).
#
# Usage:
#   export VAULT_ADDR="https://192.168.50.223:8200"
#   export VAULT_CACERT="$(pwd)/environments/media/vault-ca.crt"
#   vault login                      # or: export VAULT_TOKEN=<token>
#   ./scripts/seed-bazarr-vault.sh   # prompts for both values
#
# Optional pre-set env vars (skip the prompt for that value):
#   BAZARR_OS_USERNAME   BAZARR_OS_PASSWORD
#
# Idempotent. Re-running writes a new KV version holding the same values.
# Bash 3.2-compatible: it runs on the Mac.
set -euo pipefail

SECRET_PATH="kv/services/media/bazarr"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "FATAL: unknown argument: $1  (try --help)" >&2; exit 1 ;;
  esac
  shift
done

# --- preflight -------------------------------------------------------------------
: "${VAULT_ADDR:?set VAULT_ADDR (e.g. https://192.168.50.223:8200)}"
: "${VAULT_CACERT:?set VAULT_CACERT to the path of environments/media/vault-ca.crt}"

command -v vault   >/dev/null 2>&1 || { echo "FATAL: vault CLI not found on PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found on PATH (needed to build JSON payloads)" >&2; exit 1; }
command -v shasum  >/dev/null 2>&1 || { echo "FATAL: shasum not found on PATH (needed for the read-back digest)" >&2; exit 1; }

# Vault seals nightly. Fail here rather than half-way through.
if ! vault status >/dev/null 2>&1; then
  echo "FATAL: 'vault status' failed. Vault is unreachable or sealed. Check VAULT_ADDR and VAULT_CACERT, then unseal." >&2
  exit 1
fi

# Ask the CLI for the token, not VAULT_TOKEN: `vault login` stores its token with the
# token helper and exports nothing.
if ! vault token lookup >/dev/null 2>&1; then
  echo "FATAL: no usable Vault token. Run 'vault login', or export VAULT_TOKEN." >&2
  exit 1
fi

# --- helper: load a value from env var $1, else prompt silently ------------------
# Sets REPLY_VALUE. Never echoes the value. Rejects empty input.
load_value() {
  local var_name="$1" prompt="$2" existing
  existing="${!var_name-}"
  if [ -n "$existing" ]; then
    REPLY_VALUE="$existing"
    echo "  $var_name: using exported env var"
    return 0
  fi
  local v=""
  while [ -z "$v" ]; do
    read -r -s -p "  $prompt: " v < /dev/tty
    echo >&2
    [ -z "$v" ] && echo "  (empty, please re-enter)" >&2
  done
  REPLY_VALUE="$v"
}

# SHA-256 of a value via stdin, so it never reaches an argv.
digest() { printf '%s' "$1" | shasum -a 256 | cut -c1-12; }

echo "Seeding ${SECRET_PATH} at ${VAULT_ADDR} ..."
echo "(values are read from env or prompted silently; nothing is echoed or written to disk)"
echo

# --- collect ---------------------------------------------------------------------
load_value BAZARR_OS_USERNAME "OpenSubtitles.com username"
os_user="${REPLY_VALUE}"
load_value BAZARR_OS_PASSWORD "OpenSubtitles.com password"
os_pass="${REPLY_VALUE}"

# Shape check, not value check: a username with whitespace is a paste error.
case "$os_user" in
  *[[:space:]]*) echo "FATAL: the username contains whitespace. Length read: ${#os_user}. The value is not printed." >&2; exit 1 ;;
esac
echo "  shape: username ${#os_user} chars; password ${#os_pass} chars"
echo

# --- write -----------------------------------------------------------------------
# The pairs travel NUL-separated over a pipe to python3, which emits a JSON object
# piped to `vault kv put <path> -`.
json="$(printf '%s\0' \
  "username=${os_user}" \
  "password=${os_pass}" | python3 -c '
import json, sys
d = {}
for pair in sys.stdin.buffer.read().split(b"\0"):
    if not pair:
        continue
    k, sep, v = pair.decode().partition("=")
    if not sep:
        sys.exit("FATAL: malformed pair for key %r (no =)" % k)
    d[k] = v
print(json.dumps(d))
')"

if printf '%s' "$json" | vault kv put "$SECRET_PATH" - >/dev/null; then
  echo "  -> wrote ${SECRET_PATH}"
else
  echo "FATAL: failed to write ${SECRET_PATH}" >&2
  exit 1
fi
unset json

# --- read back -------------------------------------------------------------------
# A write that reports success and stored something else is the failure to rule out.
# Compare digests: a mismatch is debuggable and a match prints no secret.
echo
echo "Reading ${SECRET_PATH} back ..."
readback="$(vault kv get -format=json "$SECRET_PATH")" || {
  echo "FATAL: the write reported success and the path does not read back." >&2
  exit 1
}

fields_ok=1
for f in username password; do
  case "$f" in
    username) expect="$os_user" ;;
    password) expect="$os_pass" ;;
  esac
  got="$(printf '%s\0%s' "$f" "$readback" | python3 -c '
import json, sys
field, blob = sys.stdin.buffer.read().split(b"\0", 1)
data = json.loads(blob).get("data", {}).get("data", {})
sys.stdout.write(data.get(field.decode(), ""))
')"
  if [ -z "$got" ]; then
    echo "  x ${f}: absent from the read-back"
    fields_ok=0
  elif [ "$(digest "$got")" = "$(digest "$expect")" ]; then
    echo "  ok ${f}: matches what was sent (sha256 $(digest "$expect")...)"
  else
    echo "  x ${f}: stored value differs. Sent $(digest "$expect")... stored $(digest "$got")..."
    fields_ok=0
  fi
  unset got
done
unset expect

version="$(printf '%s' "$readback" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["metadata"]["version"])')"
echo "  version: ${version}"
unset readback os_user os_pass

if [ "$fields_ok" -ne 1 ]; then
  echo >&2
  echo "FATAL: the read-back did not match." >&2
  exit 1
fi

echo
echo "Done. Next: ansible-playbook playbooks/media-roles.yml --limit bazarr --check --diff"
