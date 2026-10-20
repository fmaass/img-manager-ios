#!/usr/bin/env bash
#
# sync-openapi.sh — vendor img-manager's OpenAPI contract at ONE commit, verbatim except the
# bridged nullable property sites this script rewrites (see the canonicalization below): nine
# optional ones and, since 22726ee, two required ones on response-only schemas (IMGMGR-538).
#
# Ported from memos-ng-ios's scripts/sync-openapi.sh (same pattern, adapted source path). The iOS
# client is generated from img-manager's `frontend/openapi.json`; vendoring it this way means the
# committed file is `git show <sha>:frontend/openapi.json` in img-manager plus exactly the
# rewrites the canonicalization prints and counts (two counts in OPENAPI_SOURCE), so provenance
# is checkable with one `diff` rather than trusted — and the diff has a known, enumerated length
# rather than being empty.
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

# CANDIDATE-FILE FLOW (codex gate round 2). The live artifact is not touched until every check
# has passed: the raw document is fetched into a CANDIDATE, the predicate's own probes and every
# refusal check run against the candidate, the canonicalization rewrites the candidate, and only a
# fully successful run renames it over `$dest`. A refusal therefore leaves the previous artifact
# byte-identical, and an ABSENT `$dest` stays absent.
#
# The save-and-restore this replaces could do neither reliably: it fetched onto the live file
# first, its `mktemp`/`cp` were unchecked, and with no previous file there was nothing to restore
# — so a refused sync left the raw, un-canonicalized document in place, which still builds and
# silently drops every nullable model reference.
#
# The candidate is created IN the destination directory rather than `$TMPDIR`, because `mv` is
# only atomic within one filesystem; across devices it is a copy that can fail half-written. It is
# named with a leading dot and removed by the EXIT trap on every path, including a refusal.
candidate="$(mktemp "$(dirname "$dest")/.openapi.candidate.XXXXXX")" \
  || die "cannot create a candidate file beside $dest" 1
cleanup_candidate() {
  [ -n "${candidate:-}" ] && rm -f "$candidate"
  return 0
}
trap cleanup_candidate EXIT INT TERM

fetch() {
  local path="$1" target="$2"
  git -C "$src" show "$sha:$path" > "$target" || die "cannot read $path at $sha" 1
  [ -s "$target" ] || die "$path is empty at $sha" 1
  printf '  %-28s <- %s\n' "$(basename "$dest")" "$path"
}

echo "syncing from $src at $sha"
fetch frontend/openapi.json "$candidate"

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
# outright rather than guessing — unless its schema is response-only, where it is rewritten AND
# un-required under the separately counted rule below (IMGMGR-538); a request-reachable required
# site, or any site when the reachability walk fails closed, still refuses.
#
# The rewrite is deliberately confined to a union with NO sibling keys, and stays that way even
# though it now matches zero parameters. Until img-manager v0.20.0 the ten `?sidecar` query
# parameters carried a `title` beside the union, were left exactly as the server wrote them and
# were still dropped by the generator; that half was retired by the SERVER, which now writes them
# as a bare `$ref` with the `title` beside it — the shape the generator emits. So the parameter
# loop and the enumeration below match nothing at bac5dd16 (`still_dropped_nullable_unions=0`) and
# are kept as a GUARD: a regression that re-introduces the shape is counted into OPENAPI_SOURCE on
# the next sync rather than passed over in silence, and the loop keeps its REQUIRED-site refusal.
# The optional MODEL properties (seven at 6865f8e, nine at 22726ee) still rewrite (IMGMGR-281
# (b): keep the null union server-side and bridge it here).
#
# `json.dumps(indent=2)` plus a trailing newline round-trips img-manager's own writer byte for
# byte (verified), so diffing the result against
# `git -C <img-manager> show <sha>:frontend/openapi.json` shows the rewritten sites and nothing
# else.
canonicalized="$(python3 - "$candidate" <<'PY'
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

# --- Required nullable model references on response-only schemas (IMGMGR-538) -----------------
# img-manager 22726ee's sync routes declare two such sites — FolderSyncStatusOut.latest and
# SyncRequestOut.report: a key the server always writes, with a model or a null. The generator
# drops them exactly like the optional ones, and the bare `$ref` alone would make them
# non-Optional. So a REQUIRED site is rewritten to the bare `$ref` AND taken out of its schema's
# `required` — a decoding accommodation with relaxed key presence: an absent key decodes as nil
# where the server promises the key with a null; not schema-equivalent, and never applied to a
# request-reachable schema (synthesized encoding would omit the key). Those still REFUSE.
#
# Request-reachable is a generic walk — every dict value and list element, a visited set for
# cycles — from every path item's path-level `parameters` and every operation's `parameters` and
# `requestBody`, resolving `#/components/schemas|parameters|requestBodies/*` refs on the way. It
# FAILS CLOSED: a `$ref` that does not resolve, or that points anywhere else (a `$ref`'d path
# item included), returns None, which disables the exception for the whole run, so every required
# site refuses as before. Over-inclusion only ever turns a rewrite into a refusal.
_VERBS = ("get", "put", "post", "delete", "options", "head", "patch", "trace")
_REF_ROOTS = ("schemas", "parameters", "requestBodies")

class _Unresolved(Exception):
    pass

def _resolve(doc, ref):
    parts = ref.split("/")
    if len(parts) != 4 or parts[0] != "#" or parts[1] != "components" or parts[2] not in _REF_ROOTS:
        raise _Unresolved("$ref %s points outside components.%s" % (ref, "|".join(_REF_ROOTS)))
    name = parts[3].replace("~1", "/").replace("~0", "~")
    table = (doc.get("components") or {}).get(parts[2])
    if not isinstance(table, dict) or name not in table:
        raise _Unresolved("$ref %s does not resolve" % ref)
    return parts[2], name, table[name]

def request_reachable(doc):
    """(set of request-reachable schema names, None) — or (None, reason) when it fails closed."""
    reachable, visited = set(), set()

    def walk(node):
        if isinstance(node, dict):
            ref = node.get("$ref")
            if isinstance(ref, str):
                kind, name, target = _resolve(doc, ref)
                if kind == "schemas":
                    reachable.add(name)
                if ref not in visited:
                    visited.add(ref)
                    walk(target)
            for key, value in node.items():
                if not (key == "$ref" and isinstance(value, str)):
                    walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    try:
        paths = doc.get("paths") or {}
        if not isinstance(paths, dict):
            raise _Unresolved("paths is not an object")
        for route, item in paths.items():
            if not isinstance(item, dict):
                raise _Unresolved("path item %s is not an object" % route)
            if "$ref" in item:
                raise _Unresolved("path item %s is a $ref" % route)
            walk(item.get("parameters") or [])
            for verb in _VERBS:
                if verb not in item:
                    continue
                operation = item[verb]
                if not isinstance(operation, dict):
                    raise _Unresolved("%s %s is not an object" % (verb.upper(), route))
                walk(operation.get("parameters") or [])
                walk(operation.get("requestBody") or {})
    except _Unresolved as reason:
        return None, str(reason)
    return reachable, None

def canonicalize_schemas(doc, rewritten, rewritten_required, refusals):
    reachable, unknown = request_reachable(doc)
    for name, schema in (doc.get("components", {}).get("schemas") or {}).items():
        required = set(schema.get("required") or [])
        for prop, value in (schema.get("properties") or {}).items():
            ref = nullable_ref(value)
            if ref is None:
                continue
            if prop in required:
                if reachable is None:
                    refusals.append("components.schemas.%s.%s is REQUIRED (request reachability "
                                    "failed closed: %s)" % (name, prop, unknown))
                    continue
                if name in reachable:
                    refusals.append("components.schemas.%s.%s is REQUIRED (request-reachable)"
                                    % (name, prop))
                    continue
                schema["properties"][prop] = {"$ref": ref}
                schema["required"] = [r for r in schema["required"] if r != prop]
                if not schema["required"]:
                    del schema["required"]
                rewritten_required.append("components.schemas.%s.%s -> %s" % (name, prop, ref))
                continue
            schema["properties"][prop] = {"$ref": ref}
            rewritten.append("components.schemas.%s.%s -> %s" % (name, prop, ref))

# The walk's and the rewrite's own probes, on fixture documents, before the real one is touched —
# the same reason as `_PROBES`: no other harness. Each fixture names the outcome it must produce:
# (rewritten-required sites, refused count). a) and d) are the positive controls.
def _fixture(schemas, paths):
    return {"paths": paths, "components": {"schemas": schemas}}

_S = {"type": "object", "properties": {"n": {"type": "integer"}}}
_NULLABLE_P = {"type": "object", "required": ["p"],
               "properties": {"p": {"anyOf": [{"$ref": "#/components/schemas/S"},
                                              {"type": "null"}]}}}

def _ok(ref):
    return {"responses": {"200": {"content": {"application/json": {"schema": {"$ref": ref}}}}}}

def _body(schema):
    return {"content": {"application/json": {"schema": schema}}}

_DOC_PROBES = [
    ("a) response-only required site rewrites",
     _fixture({"S": _S, "R": json.loads(json.dumps(_NULLABLE_P))},
              {"/r": {"get": _ok("#/components/schemas/R")}}),
     (["components.schemas.R.p -> #/components/schemas/S"], 0)),
    ("b) Q nested in a requestBody through allOf -> Wrap.x.items refuses",
     _fixture({"S": _S, "Q": json.loads(json.dumps(_NULLABLE_P)),
               "Wrap": {"type": "object", "properties": {
                   "x": {"type": "array", "items": {"$ref": "#/components/schemas/Q"}}}}},
              {"/q": {"get": _ok("#/components/schemas/Q"),
                      "post": dict(_ok("#/components/schemas/Q"), requestBody=_body(
                          {"allOf": [{"$ref": "#/components/schemas/Wrap"}]}))}}),
     ([], 1)),
    ("c) Q reachable only through a path-level parameter refuses",
     _fixture({"S": _S, "Q": json.loads(json.dumps(_NULLABLE_P))},
              {"/c": {"parameters": [{"name": "f", "in": "query", "schema": {
                  "type": "object", "additionalProperties": {"$ref": "#/components/schemas/Q"}}}],
                      "get": _ok("#/components/schemas/Q")}}),
     ([], 1)),
    ("d) response-only chain R2 -> R3 rewrites R3",
     _fixture({"S": _S, "R3": json.loads(json.dumps(_NULLABLE_P)),
               "R2": {"type": "object", "properties": {"c": {"$ref": "#/components/schemas/R3"}}}},
              {"/d": {"get": _ok("#/components/schemas/R2")}}),
     (["components.schemas.R3.p -> #/components/schemas/S"], 0)),
    ("e) an unresolvable $ref in a request root fails closed",
     _fixture({"S": _S, "R": json.loads(json.dumps(_NULLABLE_P))},
              {"/e": {"get": _ok("#/components/schemas/R"),
                      "post": dict(_ok("#/components/schemas/R"), requestBody=_body(
                          {"$ref": "#/components/schemas/Missing"}))}}),
     ([], 1)),
]
for _label, _doc, (_expected_sites, _expected_refused) in _DOC_PROBES:
    _rw, _rq, _rf = [], [], []
    canonicalize_schemas(_doc, _rw, _rq, _rf)
    # The document itself, not only the report: a rewritten site is a bare `$ref` and no longer
    # required; a refused one is untouched.
    _state = all(
        (_s["properties"]["p"] == {"$ref": "#/components/schemas/S"}
         and "p" not in (_s.get("required") or []))
        if any(_e.startswith("components.schemas.%s.p " % _n) for _e in _expected_sites)
        else (nullable_ref(_s["properties"]["p"]) is not None and "p" in _s["required"])
        for _n, _s in _doc["components"]["schemas"].items() if "p" in (_s.get("properties") or {}))
    if (_rq, len(_rf)) != (_expected_sites, _expected_refused) or not _state:
        sys.stderr.write(
            "REFUSED: reachability self-test %s failed — expected %r/%d refused, got %r/%r\n"
            % (_label, _expected_sites, _expected_refused, _rq, _rf))
        sys.exit(3)

rewritten = []
rewritten_required = []
refusals = []
canonicalize_schemas(doc, rewritten, rewritten_required, refusals)

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
for line in rewritten_required:
    print("rewrote-required %s (un-required; response-only)" % line)
for pointer in remaining(doc):
    print("still-dropped %s" % pointer)
PY
)" || die "nullable-ref canonicalization refused — $dest is untouched" 1

# `grep -c` exits 1 on a legitimate zero, so the counts are validated by SHAPE rather than by that
# exit code — a non-numeric here would mean the python step printed something unexpected, which
# must not reach the provenance record.
#
# EACH count is checked on its own (codex gate round 3). Checking them concatenated was a hole:
# an empty extraction on one side and digits on the other concatenate to a digits-only string, so
# `canonicalized_count=""` with `dropped_count="3"` read as "3" and passed — and the provenance
# record then carried an empty count for the side that had actually failed.
require_count() {
  case "$2" in
    "") die "the $1 count came back empty — the canonicalization output was not readable" 1 ;;
    *[!0-9]*) die "the $1 count is not a number ('$2')" 1 ;;
  esac
}

# The guard's own probes, in subshells so a refusal is observed rather than taken. Cheap, and they
# run on every sync for the same reason the predicate's probes do: this script has no other
# harness. The accepted "0" is the positive control — a guard that rejected everything would
# satisfy the two rejections above and still be wrong.
( require_count probe "" ) >/dev/null 2>&1 \
  && die "the count guard is inert: it accepted an empty value" 1
( require_count probe "7x" ) >/dev/null 2>&1 \
  && die "the count guard is inert: it accepted a non-numeric value" 1
( require_count probe "0" ) >/dev/null 2>&1 \
  || die "the count guard rejects a legitimate zero" 1

canonicalized_count="$(printf '%s\n' "$canonicalized" | grep -c '^rewrote ' || true)"
required_count="$(printf '%s\n' "$canonicalized" | grep -c '^rewrote-required ' || true)"
dropped_count="$(printf '%s\n' "$canonicalized" | grep -c '^still-dropped ' || true)"
require_count canonicalized "$canonicalized_count"
require_count canonicalized-required "$required_count"
require_count still-dropped "$dropped_count"
echo "canonicalized $canonicalized_count nullable model references and $required_count required" \
  "response-only ones; $dropped_count still dropped:"
printf '%s\n' "$canonicalized" | sed 's/^/  /'

# Every check has passed. Install the candidate — the ONE point at which the live artifact moves.
# `mktemp` makes the candidate 0600, so the mode has to be set deliberately: the file it replaces
# keeps its own (a sync must not quietly re-permission a tracked file, and git would not record
# the change), and a first vendoring gets ordinary 644.
if [ -f "$dest" ]; then
  dest_mode="$(stat -c '%a' "$dest" 2>/dev/null || stat -f '%Lp' "$dest" 2>/dev/null)" \
    || die "cannot read the current mode of $dest" 1
else
  dest_mode=644
fi
chmod "$dest_mode" "$candidate" || die "cannot set the candidate's file mode" 1
mv "$candidate" "$dest" || die "cannot install the vendored document at $dest" 1
candidate=""  # installed: the EXIT trap must not delete it

{
  echo "# Provenance of the img-manager artefact vendored into this package."
  echo "# Written by scripts/sync-openapi.sh — do not edit by hand."
  echo "repo=img-manager"
  echo "commit=$sha"
  echo "subject=$(git -C "$src" log -1 --pretty=%s "$sha")"
  echo "committed=$(git -C "$src" log -1 --pretty=%cI "$sha")"
  echo "files=Sources/ImgManagerAPI/openapi.json (source, with the nullable-\$ref canonicalization below)"
  echo "canonicalized_nullable_refs=$canonicalized_count"
  echo "canonicalized_required_nullable_refs=$required_count"
  echo "still_dropped_nullable_unions=$dropped_count"
} > "$provenance" || die "cannot write $provenance" 1

echo "recorded $provenance:"
sed 's/^/  /' "$provenance"
