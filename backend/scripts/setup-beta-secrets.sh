#!/usr/bin/env bash
#
# setup-beta-secrets.sh: put the App Store Connect key that adds TestFlight
# testers into the backend Worker (ADR 0064, docs/BETA_ONBOARDING_SPEC.md).
# The values go from this Mac straight to Cloudflare. Nothing is printed.
#
# Usage, from backend/:
#   scripts/setup-beta-secrets.sh                      (reads the asc CLI profile "headroom-ci" from the keychain)
#   scripts/setup-beta-secrets.sh --profile <name>
#   scripts/setup-beta-secrets.sh --key-id XXXX --issuer-id <uuid> [--p8 <file>]
#
# Sets: ASC_KEY_P8, ASC_KEY_ID, ASC_ISSUER_ID. The app id and the group id
# are plain vars in wrangler.toml.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="headroom-ci" KEY_ID="" ISSUER_ID="" P8=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --key-id) KEY_ID="$2"; shift 2 ;;
    --issuer-id) ISSUER_ID="$2"; shift 2 ;;
    --p8) P8="$2"; shift 2 ;;
    *) echo "unknown flag $1" >&2; exit 64 ;;
  esac
done

WRANGLER="./node_modules/.bin/wrangler"
[[ -x "$WRANGLER" ]] || { echo "run pnpm install in backend/ first" >&2; exit 1; }

if [[ -z "$KEY_ID" || -z "$ISSUER_ID" ]]; then
  BLOB="$(security find-generic-password -s asc -a "asc:credential:$PROFILE" -w)"
  read_field() {
    BLOB="$BLOB" python3 -c '
import json, os, re, sys
d = json.loads(os.environ["BLOB"])
flat = {}
def walk(o, p=""):
    if isinstance(o, dict):
        for k, v in o.items(): walk(v, k)
    elif isinstance(o, str): flat[p] = o
walk(d)
pat = re.compile(sys.argv[1], re.I)
for k, v in flat.items():
    if pat.search(k): print(v); break
' "$1"
  }
  [[ -n "$KEY_ID" ]] || KEY_ID="$(read_field '^key_?id$')"
  [[ -n "$ISSUER_ID" ]] || ISSUER_ID="$(read_field 'issuer')"
  if [[ -z "$P8" ]]; then
    KEY_TEXT="$(read_field 'private_?key$')"
    if [[ "$KEY_TEXT" == *"BEGIN PRIVATE KEY"* ]]; then
      P8="$(mktemp)"; trap 'rm -f "$P8"' EXIT
      printf '%s\n' "$KEY_TEXT" > "$P8"
    fi
  fi
fi
[[ -n "$P8" ]] || P8="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
[[ -n "$KEY_ID" && -n "$ISSUER_ID" && -f "$P8" ]] || { echo "missing key id, issuer id or .p8 (try --key-id, --issuer-id, --p8)" >&2; exit 1; }

"$WRANGLER" secret put ASC_KEY_P8 < "$P8" >/dev/null
printf '%s' "$KEY_ID" | "$WRANGLER" secret put ASC_KEY_ID >/dev/null
printf '%s' "$ISSUER_ID" | "$WRANGLER" secret put ASC_ISSUER_ID >/dev/null
echo "Set ASC_KEY_P8, ASC_KEY_ID ($KEY_ID) and ASC_ISSUER_ID on the backend Worker."
