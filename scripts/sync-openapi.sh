#!/usr/bin/env bash
#
# sync-openapi.sh — vendor img-manager's OpenAPI contract at ONE commit, verbatim.
#
# Ported from memos-ng-ios's scripts/sync-openapi.sh (same pattern, adapted source path). The iOS
# client is generated from img-manager's `frontend/openapi.json`; vendoring it verbatim means the
# committed file is byte-for-byte `git show <sha>:frontend/openapi.json` in img-manager, so
# provenance is checkable with one command rather than trusted.
#
# PINNED DEBT (WP8 P0a): img-manager's schema expresses nullability as
# anyOf: [X, {"type": "null"}], which swift-openapi-generator silently DROPS (confirmed
# 2026-08-27: 29/29 inline-type anyOf-nullable component-schema properties vanish,
# next_cursor included). Until img-manager's P1-backend phase fixes the contract to emit
# OAS 3.1 type arrays natively, this script writes TWO files: openapi.vendored.json (the
# byte-identical provenance artifact) and openapi.json (the bridged copy
# tools/normalize-openapi.py produces from it, which is what the generator plugin actually
# reads — SwiftPM's OpenAPIGenerator plugin looks for a file literally named openapi.json
# in the target's source directory, so the bridged copy cannot be renamed). Delete this
# bridge in the same swipe P1-backend re-vendors: see docs/OPENAPI_NORMALIZATION_DEBT.md.
#
# Usage:
#   scripts/sync-openapi.sh <img-manager-full-sha>
#
# Environment:
#   IMG_MANAGER_REPO  path to an img-manager clone that contains the commit (default: ../img-manager)
#
# Exit codes: 2 = refusal (bad arguments, unusable repo, unknown commit); 1 = a fetch or the
#             bridge failed (a genuine anyOf collision, not merely present).

set -uo pipefail

die() { printf 'sync-openapi: %s\n' "$1" >&2; exit "${2:-2}"; }

sha="${1:-}"
[ -n "$sha" ] || die "usage: scripts/sync-openapi.sh <img-manager-full-sha>"
# A short SHA is ambiguous and can start matching a different commit as the repo grows; the
# provenance record is only worth keeping if it is exact.
printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$' || die "expected a full 40-character commit SHA, got '$sha'"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git working tree"
src="${IMG_MANAGER_REPO:-$repo_root/../img-manager}"
[ -d "$src" ] || die "no img-manager clone at $src (set IMG_MANAGER_REPO)"
git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || die "$src is not a git repository"
git -C "$src" cat-file -e "$sha^{commit}" 2>/dev/null || die "commit $sha is not in $src (fetch it first)"

vendored_dest="$repo_root/Packages/ImgManagerAPI/Sources/ImgManagerAPI/openapi.vendored.json"
bridged_dest="$repo_root/Packages/ImgManagerAPI/Sources/ImgManagerAPI/openapi.json"
normalizer="$repo_root/tools/normalize-openapi.py"
provenance="$repo_root/Packages/ImgManagerAPI/OPENAPI_SOURCE"
mkdir -p "$(dirname "$vendored_dest")" || die "cannot create the destination directory"
[ -f "$normalizer" ] || die "missing $normalizer"

fetch() {
  local path="$1" dest="$2"
  git -C "$src" show "$sha:$path" > "$dest.tmp" || { rm -f "$dest.tmp"; die "cannot read $path at $sha" 1; }
  [ -s "$dest.tmp" ] || { rm -f "$dest.tmp"; die "$path is empty at $sha" 1; }
  mv "$dest.tmp" "$dest"
  printf '  %-28s <- %s\n' "$(basename "$dest")" "$path"
}

echo "syncing from $src at $sha"
fetch frontend/openapi.json "$vendored_dest"

bridge_output="$(python3 "$normalizer" "$vendored_dest" "$bridged_dest")" \
  || die "normalize-openapi bridge failed: $bridge_output" 1
echo "$bridge_output" | sed 's/^/  bridge: /'
rewritten="$(printf '%s\n' "$bridge_output" | sed -n 's/^nullable_rewritten=//p')"
left="$(printf '%s\n' "$bridge_output" | sed -n 's/^nullable_left_as_anyof_ref=//p')"

{
  echo "# Provenance of the img-manager artefact vendored into this package."
  echo "# Written by scripts/sync-openapi.sh — do not edit by hand."
  echo "repo=img-manager"
  echo "commit=$sha"
  echo "subject=$(git -C "$src" log -1 --pretty=%s "$sha")"
  echo "committed=$(git -C "$src" log -1 --pretty=%cI "$sha")"
  echo "files=Sources/ImgManagerAPI/openapi.vendored.json (byte-identical to source) Sources/ImgManagerAPI/openapi.json (bridged, see tools/normalize-openapi.py)"
  echo "bridge_nullable_rewritten=$rewritten"
  echo "bridge_nullable_left_as_anyof_ref=$left"
} > "$provenance" || die "cannot write $provenance" 1

echo "recorded $provenance:"
sed 's/^/  /' "$provenance"
