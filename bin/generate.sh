#!/usr/bin/env bash
# Canonical project generation. Ported from memos-ng-ios/bin/generate.sh (same rationale,
# one app target here). XcodeGen has no optional includes, so a missing per-machine
# signing.local.yml is stubbed with an empty spec that merges nothing.
#
# XcodeGen itself is fetched, not brew-installed: merkur has no brew, no mise, and no
# passwordless sudo (verified 2026-08-27 — see .phase-ledger.md, generation-strategy
# evaluation). tools/fetch-xcodegen.sh downloads the pinned 2.46.0 release zip (the exact
# version memos-ng-ios's CLAUDE.md names) straight from GitHub, sha256-verified, into a
# gitignored .tools/ directory — no install step, the extracted binary runs in place.
#
# Real device signing (P0b): cp signing.local.yml.example signing.local.yml, fill in the
# team id.
set -euo pipefail
cd "$(dirname "$0")/.."

./tools/fetch-xcodegen.sh
XCODEGEN=".tools/xcodegen/bin/xcodegen"

[ -f signing.local.yml ] || printf '{}\n' > signing.local.yml
"$XCODEGEN" generate "$@"

PINS="Package.resolved"
PINS_IN_PROJECT="ImgManager.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [ -f "$PINS" ]; then
  mkdir -p "$(dirname "$PINS_IN_PROJECT")"
  cp "$PINS" "$PINS_IN_PROJECT"
  echo "pins: restored $(grep -c '"identity"' "$PINS" || true) pinned packages into $PINS_IN_PROJECT"
else
  echo "pins: no Package.resolved yet at repo root (first-ever generate — one will be recorded after the first resolve)"
fi
