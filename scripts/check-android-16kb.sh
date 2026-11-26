#!/usr/bin/env bash
# check-android-16kb.sh — verify 16 KB ELF LOAD alignment on 64-bit native
# libraries inside a built Android .apk or .aab (required by Google Play for
# targetSdk >= 35 / Android 15+ devices).
#
# Usage:
#   scripts/check-android-16kb.sh path/to/Septena.apk
#   scripts/check-android-16kb.sh path/to/Septena.aab
set -euo pipefail

ARCHIVE="${1:?usage: check-android-16kb.sh <apk-or-aab>}"
[[ -f "$ARCHIVE" ]] || { echo "error: file not found: $ARCHIVE" >&2; exit 1; }

READELF=""
for candidate in llvm-readelf readelf "${ANDROID_NDK_LATEST_HOME:-}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"; do
  if [[ -n "$candidate" ]] && command -v "$candidate" >/dev/null 2>&1; then
    READELF="$candidate"
    break
  fi
done
[[ -n "$READELF" ]] || { echo "error: llvm-readelf or readelf is required" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unzip -q "$ARCHIVE" '*.so' -d "$TMP" 2>/dev/null || true

checked=0
failed=0
while IFS= read -r -d '' so; do
  rel="${so#"$TMP"/}"
  case "$rel" in
    *arm64-v8a/*.so|*x86_64/*.so) ;;
    *) continue ;;
  esac
  checked=$((checked + 1))

  # Every PT_LOAD program header must have alignment >= 0x4000 (16384 bytes).
  bad_loads="$("$READELF" -lW "$so" | awk '
    $1 == "LOAD" {
      align = $NF
      val = strtonum(align)
      if (val < 16384) printf "  LOAD align=%s (%d < 16384)\n", align, val
    }
  ')"
  if [[ -n "$bad_loads" ]]; then
    echo "FAIL (not 16 KB aligned): $rel"
    echo "$bad_loads"
    failed=$((failed + 1))
  else
    echo "OK   (16 KB aligned):     $rel"
  fi
done < <(find "$TMP" -type f -name '*.so' -print0 | sort -z)

if [[ "$checked" -eq 0 ]]; then
  echo "error: no arm64-v8a or x86_64 .so libraries found in $ARCHIVE" >&2
  exit 1
fi

# For APKs, also check uncompressed .so zip entry alignment (must be 16 KB aligned).
if [[ "$ARCHIVE" == *.apk ]] && command -v python3 >/dev/null 2>&1; then
  python3 - "$ARCHIVE" <<'PY'
import struct, sys, zipfile

apk = sys.argv[1]
bad = 0
with zipfile.ZipFile(apk, "r") as zf, open(apk, "rb") as raw:
    for info in zf.infolist():
        if not info.filename.endswith(".so"):
            continue
        if not ("arm64-v8a/" in info.filename or "x86_64/" in info.filename):
            continue
        if info.compress_type != zipfile.ZIP_STORED:
            print(f"FAIL (compressed .so in APK): {info.filename}")
            bad += 1
            continue
        raw.seek(info.header_offset)
        sig, _, _, _, _, _, _, _, _, _, name_len, extra_len = struct.unpack("<IHHHHHIIIHH", raw.read(30))
        assert sig == 0x04034B50
        data_offset = info.header_offset + 30 + name_len + extra_len
        if data_offset % 16384 != 0:
            print(f"FAIL (APK zip offset {data_offset} % 16384 != 0): {info.filename}")
            bad += 1
        else:
            print(f"OK   (APK 16 KB zip-aligned): {info.filename}")
if bad:
    sys.exit(1)
PY
fi

if [[ "$failed" -gt 0 ]]; then
  echo "error: $failed native library(ies) failed 16 KB page alignment" >&2
  exit 1
fi

echo "All $checked 64-bit native libraries passed 16 KB page-alignment checks."
