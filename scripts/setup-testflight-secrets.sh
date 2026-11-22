#!/usr/bin/env bash
#
# setup-testflight-secrets.sh — put the signing materials for
# .github/workflows/testflight-ios.yml into this repo's GitHub Actions secrets.
#
# The values go from this Mac straight to GitHub. Nothing is printed.
#
# Usage:
#   scripts/setup-testflight-secrets.sh --env <asc .env file> --p12 <file.p12>
#   scripts/setup-testflight-secrets.sh --key-id XXXX --issuer-id <uuid> --p12 <file.p12>
#
# --env reads the App Store Connect key id, issuer id and (optional) .p8 path
# from an env file: any variable whose name contains KEY_ID, ISSUER and
# (P8|KEY_PATH|KEY_FILE). Explicit flags win over the file.
# The .p8 defaults to ~/.appstoreconnect/private_keys/AuthKey_<key id>.p8.
#
# The .p12 must hold BOTH "Apple Development" and "Apple Distribution"
# identities for team 992N457T8D (Keychain Access: select both certificates
# under My Certificates, then File ▸ Export Items). The script asks for the
# .p12 password and does not take it as an argument, so it stays out of the
# shell history.
#
# Sets: APPLE_API_KEY, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID,
#       IOS_SIGNING_P12, IOS_SIGNING_P12_PASSWORD
set -euo pipefail

cd "$(dirname "$0")/.."

die() { echo "error: $*" >&2; exit 1; }

ENV_FILE="" KEY_ID="" ISSUER_ID="" P8="" P12=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_FILE="${2:-}"; shift 2 ;;
    --key-id) KEY_ID="${2:-}"; shift 2 ;;
    --issuer-id) ISSUER_ID="${2:-}"; shift 2 ;;
    --p8) P8="${2:-}"; shift 2 ;;
    --p12) P12="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || die "env file not found: $ENV_FILE"
  # Read in a subshell so the file's other variables never reach this shell.
  read_env() {
    ( set -a; source "$ENV_FILE" >/dev/null 2>&1; set +a
      env | grep -E "$1" | grep -vE "$2" | head -1 | cut -d= -f2- )
  }
  [[ -n "$KEY_ID" ]] || KEY_ID="$(read_env '^[A-Z_]*KEY_ID=' '^$')"
  [[ -n "$ISSUER_ID" ]] || ISSUER_ID="$(read_env '^[A-Z_]*ISSUER[A-Z_]*=' '^$')"
  [[ -n "$P8" ]] || P8="$(read_env '^[A-Z_]*(P8|KEY_PATH|KEY_FILE)[A-Z_]*=' '^$')"
fi

command -v gh >/dev/null || die "gh is required"
[[ -n "$KEY_ID" ]] || die "no key id (pass --key-id or an --env file with *KEY_ID*)"
[[ "$ISSUER_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || die "no valid issuer id (pass --issuer-id or an --env file with *ISSUER*)"
P8="${P8/#\~/$HOME}"
[[ -n "$P8" ]] || P8="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
[[ -f "$P8" ]] || die ".p8 not found: $P8"
grep -q 'BEGIN PRIVATE KEY' "$P8" || die "$P8 is not a .p8 private key"
[[ -n "$P12" && -f "$P12" ]] || die "--p12 <file> is required"

read -r -s -p "Password of $(basename "$P12"): " P12_PASSWORD; echo
[[ -n "$P12_PASSWORD" ]] || die "empty .p12 password"

# Check the .p12 before it goes anywhere: password right, both identities in it.
CHECK_KC="$(mktemp -d)/check.keychain-db"
trap 'security delete-keychain "$CHECK_KC" >/dev/null 2>&1 || true' EXIT
security create-keychain -p check "$CHECK_KC"
security import "$P12" -P "$P12_PASSWORD" -k "$CHECK_KC" -f pkcs12 >/dev/null \
  || die "could not open the .p12 (wrong password?)"
IDS="$(security find-identity -p codesigning "$CHECK_KC")"
grep -q '"Apple Development' <<<"$IDS" || die "the .p12 has no Apple Development identity"
grep -q '"Apple Distribution' <<<"$IDS" || die "the .p12 has no Apple Distribution identity"
grep -q '"Developer ID' <<<"$IDS" && echo "note: the .p12 also holds a Developer ID identity; CI does not need it"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "Setting 5 secrets on $REPO (key $KEY_ID) …"
gh secret set APPLE_API_KEY --repo "$REPO" < "$P8"
printf '%s' "$KEY_ID" | gh secret set APPLE_API_KEY_ID --repo "$REPO"
printf '%s' "$ISSUER_ID" | gh secret set APPLE_API_ISSUER_ID --repo "$REPO"
base64 < "$P12" | gh secret set IOS_SIGNING_P12 --repo "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set IOS_SIGNING_P12_PASSWORD --repo "$REPO"
echo "Done. Start a run with: gh workflow run testflight-ios.yml"
