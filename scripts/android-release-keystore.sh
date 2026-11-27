#!/usr/bin/env bash
# android-release-keystore.sh — create and back up the permanent Centaur Labs OÜ
# Android signing keys for Septena (Play Store + direct APK distribution).
#
# Guide: docs/RELEASING-ANDROID.md.
#
# Usage:
#   scripts/android-release-keystore.sh                 # create (if missing) + sync GitHub secrets + print fingerprints
#   scripts/android-release-keystore.sh --local-only    # create (if missing) + print fingerprints, skip gh secret set
#   scripts/android-release-keystore.sh --fingerprints  # print fingerprints and PEPK command for existing keys only
#
# Creates TWO permanent PKCS12 keystores under ~/.config/signing/centaur-labs/android/
# (chmod 700/600) AND stores both keystores + passwords in the macOS login Keychain:
#
#   1. septena-android-release.p12      (alias: septena-release)
#      Signs public direct-download APKs (GitHub Releases / septena.app/android/download).
#      Can also be enrolled into Google Play App Signing via PEPK so direct APKs and
#      Play Store installs share one certificate and update each other in place.
#
#   2. septena-android-play-upload.p12  (alias: septena-play-upload)
#      Signs .aab bundles uploaded to Google Play Console. Kept separate from the
#      direct-APK key so rotating the Play upload key never breaks direct-APK updates.
#
# Refuses to overwrite existing keys: replacing a release key breaks in-place updates
# for every installed device. Never prints any password or private key material.
set -euo pipefail

REPO="septena/septena"
SIGNING_DIR="${SEPTENA_ANDROID_SIGNING_DIR:-$HOME/.config/signing/centaur-labs/android}"
ACCOUNT="centaur-labs"

RELEASE_FILE="$SIGNING_DIR/septena-android-release.p12"
RELEASE_ALIAS="septena-release"
RELEASE_SVC="septena-android-release-keystore"
RELEASE_SUBJ="/CN=Septena/O=CENTAUR LABS OU/C=EE"

UPLOAD_FILE="$SIGNING_DIR/septena-android-play-upload.p12"
UPLOAD_ALIAS="septena-play-upload"
UPLOAD_SVC="septena-android-play-upload-keystore"
UPLOAD_SUBJ="/CN=Septena Play Upload/O=CENTAUR LABS OU/C=EE"

SYNC_GITHUB=1
PRINT_ONLY=0
case "${1:-}" in
  "") ;;
  --local-only) SYNC_GITHUB=0 ;;
  --fingerprints) SYNC_GITHUB=0; PRINT_ONLY=1 ;;
  -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
  *) echo "error: unknown argument: $1" >&2; exit 1 ;;
esac

ensure_key() {
  local file="$1" alias="$2" svc="$3" subj="$4"
  local pw_svc="${svc}-password"

  if security find-generic-password -s "$svc" -a "$ACCOUNT" >/dev/null 2>&1; then
    echo "Keychain already holds $svc — keeping existing key."
    if [[ ! -f "$file" ]]; then
      mkdir -p "$SIGNING_DIR"
      chmod 700 "$SIGNING_DIR"
      umask 077
      security find-generic-password -s "$svc" -a "$ACCOUNT" -w | base64 -d > "$file"
      chmod 600 "$file"
      echo "Restored $file from login Keychain."
    fi
    return 0
  fi

  if [[ -f "$file" ]]; then
    echo "error: $file exists on disk but $svc is missing from the login Keychain." >&2
    echo "Back it up and import it manually so nothing is overwritten." >&2
    exit 1
  fi

  if [[ "$PRINT_ONLY" -eq 1 ]]; then
    echo "error: $svc does not exist yet. Run without --fingerprints first." >&2
    exit 1
  fi

  mkdir -p "$SIGNING_DIR"
  chmod 700 "$SIGNING_DIR"
  local tmp pw
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  umask 077

  pw="$(openssl rand -hex 24)"
  openssl req -x509 -newkey rsa:4096 -sha256 -days 10000 -nodes \
    -subj "$subj" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1
  openssl pkcs12 -export -name "$alias" \
    -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$file" -passout "pass:$pw"
  chmod 600 "$file"

  security add-generic-password -s "$svc" -a "$ACCOUNT" \
    -w "$(base64 -i "$file" | tr -d '\n')"
  security add-generic-password -s "$pw_svc" -a "$ACCOUNT" -w "$pw"
  unset pw
  echo "Created $file (alias $alias) and saved backup in login Keychain ($svc)."
}

print_fingerprints() {
  local label="$1" svc="$2" alias="$3"
  local pw_svc="${svc}-password"
  local tmp pw
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  umask 077

  pw="$(security find-generic-password -s "$pw_svc" -a "$ACCOUNT" -w)"
  security find-generic-password -s "$svc" -a "$ACCOUNT" -w | base64 -d > "$tmp/k.p12"
  echo ""
  echo "=== $label (alias: $alias) ==="
  openssl pkcs12 -in "$tmp/k.p12" -nokeys -passin "pass:$pw" 2>/dev/null \
    | openssl x509 -noout -subject -dates -fingerprint -sha1 -fingerprint -sha256
  unset pw
}

sync_secret() {
  local svc="$1" b64_secret="$2" pw_secret="$3"
  local pw_svc="${svc}-password"
  security find-generic-password -s "$svc" -a "$ACCOUNT" -w \
    | gh secret set "$b64_secret" -R "$REPO"
  security find-generic-password -s "$pw_svc" -a "$ACCOUNT" -w \
    | gh secret set "$pw_secret" -R "$REPO"
  echo "Synced GitHub secrets: $b64_secret, $pw_secret ($REPO)"
}

ensure_key "$RELEASE_FILE" "$RELEASE_ALIAS" "$RELEASE_SVC" "$RELEASE_SUBJ"
ensure_key "$UPLOAD_FILE" "$UPLOAD_ALIAS" "$UPLOAD_SVC" "$UPLOAD_SUBJ"

print_fingerprints "Direct APK / App Signing Key" "$RELEASE_SVC" "$RELEASE_ALIAS"
print_fingerprints "Google Play Upload Key" "$UPLOAD_SVC" "$UPLOAD_ALIAS"

if [[ "$SYNC_GITHUB" -eq 1 ]]; then
  command -v gh >/dev/null || { echo "error: gh CLI is required (or pass --local-only)" >&2; exit 1; }
  echo ""
  sync_secret "$RELEASE_SVC" "ANDROID_RELEASE_KEYSTORE_B64" "ANDROID_RELEASE_KEYSTORE_PASSWORD"
  sync_secret "$UPLOAD_SVC" "ANDROID_PLAY_UPLOAD_KEYSTORE_B64" "ANDROID_PLAY_UPLOAD_KEYSTORE_PASSWORD"
fi

cat <<EOF

Next steps:
1. Back up BOTH .p12 files and their Keychain passwords into 1Password (Centaur Labs vault):
   - $RELEASE_FILE  (Keychain password service: ${RELEASE_SVC}-password, account: $ACCOUNT)
   - $UPLOAD_FILE   (Keychain password service: ${UPLOAD_SVC}-password, account: $ACCOUNT)
2. If enrolling the unified app signing key into Google Play App Signing (Option A):
   Download pepk.jar from Play Console (Setup -> App signing) and run:
     java -jar pepk.jar \\
       --keystore="$RELEASE_FILE" \\
       --alias="$RELEASE_ALIAS" \\
       --output=septena-play-signing-key.zip \\
       --rsa-aes-encryption \\
       --encryption-key-path=<google-encryption-public-key.pem>
   (When prompted, paste the password from Keychain service ${RELEASE_SVC}-password.)
EOF
