#!/usr/bin/env bash
# Fetch and pin XcodeGen without brew, mise or sudo — merkur has none of the three
# (verified 2026-08-27: `command -v brew`/`mise` both absent; `sudo -n true` refuses with
# "a password is required"). The upstream release ships a self-contained universal
# (x86_64+arm64) binary zip with no installer step required — `xcodegen.zip`, distinct
# from `xcodegen.artifactbundle.zip` (the SwiftPM artifact-bundle form; either works, this
# one needs no Package.swift wiring). Verified on merkur (Darwin 25.6.0, arm64, T8103 —
# Apple Silicon): `bin/xcodegen --version` reports 2.46.0 straight out of the zip.
#
# CONTENT-ADDRESSED, RE-VERIFIED ON EVERY INVOCATION (fixed 2026-08-27, P0a fix round):
# an earlier version only checked `--version` text on the "already present" fast path,
# which trusts the cache's SELF-REPORTED identity rather than its bytes — a corrupted,
# truncated, or hand-edited cached binary that still prints "2.46.0" would pass silently.
# BINARY_SHA256 pins the sha256 of the EXTRACTED `bin/xcodegen` executable itself (not
# just the zip), so the check covers exactly what gets executed, and it runs before every
# use, cached or not.
#
# Version pinned to 2.46.0 — the exact version the estate's reference project
# (memos-ng-ios/CLAUDE.md) names. Re-pin deliberately: bump VERSION, ZIP_SHA256 and
# BINARY_SHA256 together, never one alone (all three were captured from the same
# `curl | unzip | shasum` run on merkur, 2026-08-27).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.46.0"
ZIP_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
BINARY_SHA256="8774da746668bc18fe74e54cbaf10f2631a1fb05947cd374179aa912f14f99db"
URL="https://github.com/yonaskolb/XcodeGen/releases/download/${VERSION}/xcodegen.zip"

DEST=".tools/xcodegen"
BIN="$DEST/bin/xcodegen"

verify_binary() {
  [ -x "$BIN" ] || return 1
  local actual
  actual="$(shasum -a 256 "$BIN" | awk '{print $1}')"
  [ "$actual" = "$BINARY_SHA256" ]
}

if verify_binary; then
  echo "xcodegen $VERSION present at $BIN — sha256 re-verified this run ($BINARY_SHA256)"
  "$BIN" --version
  exit 0
fi

if [ -x "$BIN" ]; then
  echo "fetch-xcodegen: cached binary at $BIN failed sha256 re-verification — refetching" >&2
fi

mkdir -p .tools
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "fetching xcodegen $VERSION..."
curl -sSL --max-time 60 -o "$tmp/xcodegen.zip" "$URL"

actual_zip_sha="$(shasum -a 256 "$tmp/xcodegen.zip" | awk '{print $1}')"
if [ "$actual_zip_sha" != "$ZIP_SHA256" ]; then
  echo "fetch-xcodegen: REFUSED — zip sha256 mismatch for $URL" >&2
  echo "  expected: $ZIP_SHA256" >&2
  echo "  actual:   $actual_zip_sha" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p ".tools"
unzip -q "$tmp/xcodegen.zip" -d "$tmp/extracted"
mv "$tmp/extracted/xcodegen" "$DEST"

if ! verify_binary; then
  echo "fetch-xcodegen: REFUSED — extracted binary sha256 mismatch (zip verified but its contents did not match BINARY_SHA256)" >&2
  echo "  expected: $BINARY_SHA256" >&2
  echo "  actual:   $(shasum -a 256 "$BIN" 2>/dev/null | awk '{print $1}')" >&2
  rm -rf "$DEST"
  exit 1
fi

"$BIN" --version
echo "pinned xcodegen $VERSION at $DEST (zip sha256 $ZIP_SHA256, binary sha256 $BINARY_SHA256, both verified)"
