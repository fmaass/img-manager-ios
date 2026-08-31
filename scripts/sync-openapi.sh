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
# The canonicalization below can REFUSE, and `fetch` has already overwritten the destination by
# then — which would leave the package holding a raw, un-canonicalized document that still builds
# and silently drops fields. Observed while testing the refusal path, so the previous artifact is
# kept and put back on any refusal: a refused sync changes nothing at all.
previous="$(mktemp)"
if [ -f "$dest" ]; then cp "$dest" "$previous"; else rm -f "$previous"; previous=""; fi
restore_previous() {
  [ -n "$previous" ] && [ -f "$previous" ] && cp "$previous" "$dest"
  [ -n "$previous" ] && rm -f "$previous"
  return 0
}
fetch frontend/openapi.json "$dest"

# --- Nullable model references (IMGMGR-249) -------------------------------------------------
# img-manager canonicalises SCALAR nullables to the OAS 3.1 `type: [X, "null"]` idiom natively —
# that is what retired the old rewrite bridge, and 188 sites arrive in that form. A nullable
# MODEL reference has no such spelling: JSON Schema can only say
# `anyOf: [{"$ref": X}, {"type": "null"}]`, and swift-openapi-generator 1.13.0 DROPS a property
# declared that way rather than generating an Optional. Measured, not assumed: at the previously
# vendored 5615fd9 the generated `StatusResponse` carried no `activeRun` at all (0 hits in the
# gate's own Types.swift; positive control `lastIndexedAt`, 5 hits), which is why the Status
# sheet could not name the job that is running.
#
# So exactly that one shape is rewritten to the bare `$ref` it means, and ONLY where the site is
# already optional — a property absent from its schema's `required`, or a parameter with
# `required: false` — because there the generator's own "not required -> Optional" rule produces
# precisely the type the union described. A REQUIRED site would change meaning, so that refuses
# outright rather than guessing.
#
# The rewrite is deliberately confined to a union with NO sibling keys. Sites that carry one (the
# ten `?sidecar` query parameters carry a `title`) are left exactly as the server wrote them and
# are still dropped by the generator — so they are ENUMERATED on every sync and counted into
# OPENAPI_SOURCE rather than passed over in silence. Nothing in this client consumes `?sidecar`
# today; when something does, this is the rule that extends.
#
# `json.dumps(indent=2)` plus a trailing newline round-trips img-manager's own writer byte for
# byte (verified), so diffing the result against
# `git -C <img-manager> show <sha>:frontend/openapi.json` shows the rewritten sites and nothing
# else.
canonicalized="$(python3 - "$dest" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as handle:
    doc = json.load(handle)

def is_null_member(member):
    """EXACTLY {"type": "null"} and nothing else. A sibling key on the null member changes what
    the union says — `{"type": "null", "not": {}}` describes a branch that matches nothing, so
    collapsing it to a bare `$ref` would erase a constraint rather than restate it — and a shape
    this rule has not been reasoned about must not be rewritten on the strength of one matching
    key (codex gate round 1, blocker 2)."""
    return isinstance(member, dict) and set(member) == {"type"} and member["type"] == "null"

def nullable_ref(schema):
    """The one shape this rule knows: exactly {$ref} + {type: null}, no sibling keys anywhere."""
    if not isinstance(schema, dict) or set(schema) != {"anyOf"}:
        return None
    members = schema["anyOf"]
    if not isinstance(members, list) or len(members) != 2:
        return None
    refs = [m for m in members if isinstance(m, dict) and set(m) == {"$ref"}]
    nulls = [m for m in members if is_null_member(m)]
    return refs[0]["$ref"] if len(refs) == 1 and len(nulls) == 1 else None

# The predicate's own probes, run on EVERY sync before a single byte is rewritten, because this
# script has no other test harness and a matcher that quietly widens is the whole risk. The first
# probe is the positive control: a predicate that has stopped matching anything fails here too,
# rather than silently rewriting nothing and reporting a clean run.
_PROBES = [
    ({"anyOf": [{"$ref": "#/c/S"}, {"type": "null"}]}, "#/c/S"),
    ({"anyOf": [{"$ref": "#/c/S"}, {"type": "null", "not": {}}]}, None),
    ({"anyOf": [{"$ref": "#/c/S"}, {"type": "null"}], "title": "T"}, None),
    ({"anyOf": [{"$ref": "#/c/S", "description": "d"}, {"type": "null"}]}, None),
    ({"anyOf": [{"type": "string"}, {"type": "null"}]}, None),
    ({"anyOf": [{"$ref": "#/c/S"}, {"$ref": "#/c/T"}, {"type": "null"}]}, None),
]
for _probe, _expected in _PROBES:
    _actual = nullable_ref(_probe)
    if _actual != _expected:
        sys.stderr.write(
            "REFUSED: predicate self-test failed on %s — expected %r, got %r\n"
            % (json.dumps(_probe), _expected, _actual))
        sys.exit(3)

rewritten = []
refusals = []

for name, schema in (doc.get("components", {}).get("schemas") or {}).items():
    required = set(schema.get("required") or [])
    for prop, value in (schema.get("properties") or {}).items():
        ref = nullable_ref(value)
        if ref is None:
            continue
        if prop in required:
            refusals.append("components.schemas.%s.%s is REQUIRED" % (name, prop))
            continue
        schema["properties"][prop] = {"$ref": ref}
        rewritten.append("components.schemas.%s.%s -> %s" % (name, prop, ref))

for route, operations in (doc.get("paths") or {}).items():
    for verb, operation in operations.items():
        if not isinstance(operation, dict):
            continue
        for parameter in operation.get("parameters") or []:
            ref = nullable_ref(parameter.get("schema"))
            if ref is None:
                continue
            if parameter.get("required"):
                refusals.append(
                    "%s %s parameter %s is REQUIRED" % (verb.upper(), route, parameter["name"]))
                continue
            parameter["schema"] = {"$ref": ref}
            rewritten.append("%s %s ?%s -> %s" % (verb.upper(), route, parameter["name"], ref))

def remaining(node, pointer=""):
    """EVERY anyOf still carrying a null member — deliberately the BROAD test (a null member with
    siblings counts), because the generator drops the union whatever else is on it. So a shape the
    narrow rewrite predicate declines, `{"type": "null", "not": {}}` included, is reported here as
    still-dropped rather than passing through unmentioned."""
    if isinstance(node, dict):
        members = node.get("anyOf")
        if isinstance(members, list) and any(
            isinstance(m, dict) and m.get("type") == "null" for m in members
        ):
            yield pointer
        for key, value in node.items():
            for found in remaining(value, "%s/%s" % (pointer, key)):
                yield found
    elif isinstance(node, list):
        for index, value in enumerate(node):
            for found in remaining(value, "%s/%d" % (pointer, index)):
                yield found

if refusals:
    for line in refusals:
        sys.stderr.write("REFUSED: %s\n" % line)
    sys.exit(3)

with open(path, "w") as handle:
    json.dump(doc, handle, indent=2)
    handle.write("\n")

for line in rewritten:
    print("rewrote %s" % line)
for pointer in remaining(doc):
    print("still-dropped %s" % pointer)
PY
)" || { restore_previous; die "nullable-ref canonicalization refused (the previous vendored document is untouched)" 1; }
canonicalized_count="$(printf '%s\n' "$canonicalized" | grep -c '^rewrote ')"
dropped_count="$(printf '%s\n' "$canonicalized" | grep -c '^still-dropped ')"
echo "canonicalized $canonicalized_count nullable model references; $dropped_count still dropped:"
printf '%s\n' "$canonicalized" | sed 's/^/  /'

{
  echo "# Provenance of the img-manager artefact vendored into this package."
  echo "# Written by scripts/sync-openapi.sh — do not edit by hand."
  echo "repo=img-manager"
  echo "commit=$sha"
  echo "subject=$(git -C "$src" log -1 --pretty=%s "$sha")"
  echo "committed=$(git -C "$src" log -1 --pretty=%cI "$sha")"
  echo "files=Sources/ImgManagerAPI/openapi.json (source, with the nullable-\$ref canonicalization below)"
  echo "canonicalized_nullable_refs=$canonicalized_count"
  echo "still_dropped_nullable_unions=$dropped_count"
} > "$provenance" || die "cannot write $provenance" 1

[ -n "$previous" ] && rm -f "$previous"
echo "recorded $provenance:"
sed 's/^/  /' "$provenance"
