#!/usr/bin/env bash
# Fetch and pin XcodeGen without brew, mise or sudo — merkur has none of the three
# (verified 2026-08-27: `command -v brew`/`mise` both absent; `sudo -n true` refuses with
# "a password is required"). The upstream release ships a self-contained universal
# (x86_64+arm64) binary zip with no installer step required — `xcodegen.zip`, distinct
# from `xcodegen.artifactbundle.zip` (the SwiftPM artifact-bundle form; either works, this
# one needs no Package.swift wiring). Verified on merkur (Darwin 25.6.0, arm64, T8103 —
# Apple Silicon): `bin/xcodegen --version` reports 2.46.0 straight out of the zip.
#
# Version pinned to 2.46.0 — the exact version the estate's reference project
# (memos-ng-ios/CLAUDE.md) names. Re-pin deliberately: bump VERSION and SHA256 together,
# never one alone.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.46.0"
SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
URL="https://github.com/yonaskolb/XcodeGen/releases/download/${VERSION}/xcodegen.zip"

DEST=".tools/xcodegen"
if [ -x "$DEST/bin/xcodegen" ] && "$DEST/bin/xcodegen" --version 2>/dev/null | grep -q "$VERSION"; then
  echo "xcodegen $VERSION already present at $DEST/bin/xcodegen"
  exit 0
fi

mkdir -p .tools
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "fetching xcodegen $VERSION..."
curl -sSL --max-time 60 -o "$tmp/xcodegen.zip" "$URL"

actual_sha="$(shasum -a 256 "$tmp/xcodegen.zip" | awk '{print $1}')"
if [ "$actual_sha" != "$SHA256" ]; then
  echo "fetch-xcodegen: REFUSED — sha256 mismatch for $URL" >&2
  echo "  expected: $SHA256" >&2
  echo "  actual:   $actual_sha" >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p ".tools"
unzip -q "$tmp/xcodegen.zip" -d "$tmp/extracted"
mv "$tmp/extracted/xcodegen" "$DEST"

"$DEST/bin/xcodegen" --version
echo "pinned xcodegen $VERSION at $DEST (sha256 $SHA256 verified)"
