#!/usr/bin/env bash
#
# sync-openapi.sh — vendor img-manager's OpenAPI contract at ONE commit, verbatim.
#
# Ported from memos-ng-ios's scripts/sync-openapi.sh (same pattern, adapted source path). The iOS
# client is generated from img-manager's `frontend/openapi.json`; vendoring it verbatim means the
# committed file is byte-for-byte `git show <sha>:frontend/openapi.json` in img-manager, so
# provenance is checkable with one command rather than trusted.
#
# RETIRED BRIDGE (WP8 P1-ios, docs/OPENAPI_NORMALIZATION_DEBT.md): this script used to write a
# second, rewritten copy (openapi.vendored.json -> tools/normalize-openapi.py -> openapi.json)
# because img-manager's schema expressed nullability as anyOf: [X, {"type": "null"}], which
# swift-openapi-generator silently dropped. img-manager's v0.9.2 (P1-backend) now emits the OAS
# 3.1 `type: [X, "null"]` idiom natively — re-vendoring at eff6a12ddf3c7e2a6f748625747345ca57c86349
# measured bridge_nullable_rewritten=0 — so the bridge has nothing left to do and is deleted,
# exactly the way memos-ng-ios retired its own copy of the identical fix (memos-ng-ios commit
# dfc2545, "Vendor openapi.json verbatim now that memos-ng emits nullable type arrays"). This file
# is now that same single-fetch shape.
#
# Usage:
#   scripts/sync-openapi.sh <img-manager-full-sha>
#
# Environment:
#   IMG_MANAGER_REPO  path to an img-manager clone that contains the commit (default: ../img-manager)
#
# Exit codes: 2 = refusal (bad arguments, unusable repo, unknown commit); 1 = the fetch failed.

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

dest="$repo_root/Packages/ImgManagerAPI/Sources/ImgManagerAPI/openapi.json"
provenance="$repo_root/Packages/ImgManagerAPI/OPENAPI_SOURCE"
mkdir -p "$(dirname "$dest")" || die "cannot create the destination directory"

fetch() {
  local path="$1" dest="$2"
  git -C "$src" show "$sha:$path" > "$dest.tmp" || { rm -f "$dest.tmp"; die "cannot read $path at $sha" 1; }
  [ -s "$dest.tmp" ] || { rm -f "$dest.tmp"; die "$path is empty at $sha" 1; }
  mv "$dest.tmp" "$dest"
  printf '  %-28s <- %s\n' "$(basename "$dest")" "$path"
}

echo "syncing from $src at $sha"
fetch frontend/openapi.json "$dest"

{
  echo "# Provenance of the img-manager artefact vendored into this package."
  echo "# Written by scripts/sync-openapi.sh — do not edit by hand."
  echo "repo=img-manager"
  echo "commit=$sha"
  echo "subject=$(git -C "$src" log -1 --pretty=%s "$sha")"
  echo "committed=$(git -C "$src" log -1 --pretty=%cI "$sha")"
  echo "files=Sources/ImgManagerAPI/openapi.json (byte-identical to source)"
} > "$provenance" || die "cannot write $provenance" 1

echo "recorded $provenance:"
sed 's/^/  /' "$provenance"
