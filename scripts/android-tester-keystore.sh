#!/bin/sh
# android-tester-keystore.sh — the one signing key for every Android tester
# APK (the same model as Bipe's tools/tester-keystore.sh). Runs on mz's Mac.
#
# Android installs an update only when the new APK has the same signing key
# as the installed one. A CI runner makes a new debug key on every run, so
# without a fixed key no APK from CI can update the one on the phone.
#
# 1. Makes one PKCS12 keystore (alias septena-tester, RSA 4096) with a random
#    password, once. It refuses to replace a key that exists: a new key stops
#    every installed APK from updating.
# 2. Keeps it in the login Keychain: service septena-android-tester-keystore
#    (the keystore, base64) and septena-android-tester-keystore-password,
#    account septena. This is the only backup.
# 3. Sets the repository secrets ANDROID_TESTER_KEYSTORE_B64 and
#    ANDROID_TESTER_KEYSTORE_PASSWORD through stdin.
# Nothing is printed except the SHA-256 fingerprint of the certificate.
set -eu

repo=septena/septena
service=septena-android-tester-keystore
account=septena

if security find-generic-password -s "$service" -a "$account" >/dev/null 2>&1; then
  echo "The tester key exists in the Keychain. Copying it to GitHub again."
else
  dir=$(mktemp -d)
  trap 'rm -rf "$dir"' EXIT
  umask 077
  pw=$(openssl rand -hex 24)
  openssl req -x509 -newkey rsa:4096 -sha256 -days 10000 -nodes \
    -subj "/CN=Septena tester APK/O=Septena" \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" >/dev/null 2>&1
  openssl pkcs12 -export -name septena-tester -inkey "$dir/key.pem" -in "$dir/cert.pem" \
    -out "$dir/tester.p12" -passout "pass:$pw"
  security add-generic-password -s "$service" -a "$account" -w "$(base64 -i "$dir/tester.p12" | tr -d '\n')"
  security add-generic-password -s "$service-password" -a "$account" -w "$pw"
  unset pw
fi

security find-generic-password -s "$service" -a "$account" -w | gh secret set ANDROID_TESTER_KEYSTORE_B64 -R "$repo"
security find-generic-password -s "$service-password" -a "$account" -w | gh secret set ANDROID_TESTER_KEYSTORE_PASSWORD -R "$repo"

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
security find-generic-password -s "$service" -a "$account" -w | base64 -d > "$dir/k"
openssl pkcs12 -in "$dir/k" -nokeys -passin "pass:$(security find-generic-password -s "$service-password" -a "$account" -w)" 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 | sed 's/^.*=/Tester certificate SHA-256 /'
echo "Done: ANDROID_TESTER_KEYSTORE_B64 and ANDROID_TESTER_KEYSTORE_PASSWORD are set in $repo."
