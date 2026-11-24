#!/usr/bin/env bash
# Write the App Store Connect API key config that appstore/upload.sh reads.
#
#   appstore/asc-key.sh <key id> <issuer id>
#
# Reads the .p8 from ~/.appstoreconnect/private_keys/AuthKey_<key id>.p8 and
# writes ~/.appstoreconnect/septena.json (mode 600) in fastlane's api_key_path
# shape. The key contents are never printed. The key must belong to the team
# that owns the Septena App Store records, with the App Manager role or higher.
set -euo pipefail

key_id="${1:?usage: appstore/asc-key.sh <key id> <issuer id>}"
issuer="${2:?usage: appstore/asc-key.sh <key id> <issuer id>}"
p8="$HOME/.appstoreconnect/private_keys/AuthKey_${key_id}.p8"
out="$HOME/.appstoreconnect/septena.json"
[ -f "$p8" ] || { echo "asc-key: $p8 not found" >&2; exit 1; }

umask 077
KEY_ID="$key_id" ISSUER="$issuer" P8="$p8" OUT="$out" node -e '
const fs = require("fs");
const json = { key_id: process.env.KEY_ID, issuer_id: process.env.ISSUER,
               key: fs.readFileSync(process.env.P8, "utf8"), in_house: false };
fs.writeFileSync(process.env.OUT, JSON.stringify(json), { mode: 0o600 });
'
echo "asc-key: wrote $out for key $key_id"
