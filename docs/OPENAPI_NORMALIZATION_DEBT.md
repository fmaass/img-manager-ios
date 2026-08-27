# OpenAPI normalization bridge — pinned debt

**Status:** active debt, P0a-scoped. Owner of the fix: P1-backend (img-manager repo).
Owner of the deletion: P1-ios (this repo, P1's ios sub-branch).

## What this is

`tools/normalize-openapi.py`, invoked by `scripts/sync-openapi.sh` on every vendor, rewrites
img-manager's `anyOf: [X, {"type": "null"}]` nullable idiom into the OAS 3.1
`type: [X, "null"]` array form before `Sources/ImgManagerAPI/openapi.json` (the file the
`swift-openapi-generator` SwiftPM plugin actually reads) is written. Without this rewrite,
the generator silently drops every property expressed the first way — no error, no warning
naming the property, the build exits 0 with the property simply absent from the generated
type.

This is not a new phenomenon: `memos-ng-ios` — the estate's own reference iOS project —
hit and fixed the identical generator bug against the identical FastAPI-emitted idiom, and
retired its own equivalent script once its backend (memos-ng) started emitting OAS 3.1
type arrays natively (commit `433a3fe`; the retirement commit is `dfc2545` in that repo,
`git show dfc2545~1:scripts/normalize-openapi.py` recovers the retired script this repo's
`tools/normalize-openapi.py` was ported from, logic unchanged).

## The scope, measured against the real vendored schema (not recalled)

Against `Packages/ImgManagerAPI/Sources/ImgManagerAPI/openapi.vendored.json` (byte-identical
to `git show 4b952701ac79a6ec7ac245e8f1bf3b9657ca64c6:frontend/openapi.json` in img-manager
— img-manager's v0.9.0 tag), the bridge currently rewrites **117 properties**, split:

| Scope | Count | Individually regression-tested? |
|---|---|---|
| `#/components/schemas/*` properties (data model fields the client reads) | **29** | **Yes** — `Packages/ImgManagerAPI/Tests/ImgManagerAPITests/NullableSurvivalTests.swift`, compile-time `WritableKeyPath` existence-and-type check per property, plus a Codable round-trip test for `ImagePage.next_cursor` specifically. Full list: `docs/evidence/p0a-probe/failing-field-list.txt`. |
| `#/paths/*` query/path parameter schemas | **88** | **No** — fixed by the same rewrite (same `openapi.json`, same generator run), but no test names them individually. This is the gap P1-ios's re-vendor should close (see Disposition below). |
| `$ref` + `{"type":"null"}` (e.g. `sidecar` → `SidecarPresence`) | 12 | N/A — correctly left untouched by design; a reference plus null needs a different fix (see the script's own docstring). |

`Packages/ImgManagerAPI/OPENAPI_SOURCE` records the live counters from the last sync:
`bridge_nullable_rewritten=117`, `bridge_nullable_left_as_anyof_ref=12` — these are exactly
the 117 and 12 above.

**Correction to an earlier claim (this doc did not exist before this fix round; the two
files that reference it — `tools/normalize-openapi.py`'s docstring and
`scripts/sync-openapi.sh`'s header — previously said "29/29 ... vanish" without
distinguishing the component-schema scope from the full rewrite scope, and pointed here
before this file existed. Both are corrected in the same commit as this doc.)**

## The probe/closure split (quoted from the governing plan)

This debt's shape — and the reason it is a bridge landing in P0a rather than a schema fix
landing in P0a — comes directly from the plan gate's disposition, recorded verbatim in
`docs/plans/PLAN_2026-08-27_wp8-native-client.md` §Phase 0a:

> "The probe and the closure are two different things, and conflating them deadlocked the
> previous revision (delta finding 1). P0a's obligation is the **generation PROBE**: run
> the generator against the vendored schema and produce a finding — the list of properties
> that survived and the list that did not. **The probe is allowed to fail; a failing probe
> is its deliverable, not its blocker.** What P0a must then close is the **generated
> client**, and it closes it on a documented `anyOf` failure by pinning a **temporary
> normalisation bridge** — the shape the precedent itself ran until its backend emitted
> OAS 3.1 type arrays natively (`memos-ng-ios/CLAUDE.md:118-127`) — pinned, named as debt
> in this file, and carrying the failing field list. **The schema fix itself is handed to
> P1-backend**, which is the first phase permitted to change the contract after v0.9.0
> ships. So: probe fails → bridge lands → P0a completes and merges → P1-backend fixes the
> contract → the bridge is deleted in P1's ios sub-branch, which re-vendors from P1's own
> backend SHA. **There is no cycle: P0a never waits on P1, and P1 never waits on a green
> probe.**"

("named as debt in this file" refers to the plan document itself at the time it was
written; this document is that debt record made concrete, in the repo the bridge actually
lives in, which is where a reader fixing P1 will look.)

## Disposition — what P1-backend and P1-ios each owe

**P1-backend (img-manager repo):** fix the contract for **all 117** properties this bridge
currently rewrites, not only the 29 tested here — the parameter-schema cases are just as
real a generator hazard, they are simply untested in this repo today. The fix is the same
shape memos-ng took: emit `type: [X, "null"]` (OAS 3.1 type arrays) instead of
`anyOf: [X, {"type": "null"}]`, wherever FastAPI's schema generation currently produces the
latter. A partial fix (components only, parameters left as `anyOf`) would leave this bridge
partially necessary and defeats the point of retiring it.

**P1-ios (this repo, P1's ios sub-branch), once P1-backend has shipped and the backend
release checkpoint is deployed and read back:**
1. Re-vendor `openapi.vendored.json` from **P1's own backend SHA** (not v0.9.0's) via
   `scripts/sync-openapi.sh <new-sha>`.
2. Re-run the generation probe (`swift build --package-path Packages/ImgManagerAPI`) against
   the freshly-vendored, UNBRIDGED schema and confirm `nullable_rewritten=0` from
   `tools/normalize-openapi.py` — the signal that the fix landed and the bridge has nothing
   left to do.
3. **Delete the bridge**: `tools/normalize-openapi.py`, its invocation in
   `scripts/sync-openapi.sh`, and `openapi.vendored.json`/`openapi.json`'s split (the
   vendored file becomes the generator's direct input again, exactly as memos-ng-ios's
   `sync-openapi.sh` does today post-retirement).
4. **Add the parameter-test gap this debt names**: extend (or replace)
   `NullableSurvivalTests.swift` to cover the query/path parameter schemas too — the 88
   currently untested here — so a future regression in either scope is caught the same way.
5. Close this document (delete it, or mark it resolved with the closing SHA) in the same
   commit.

## Evidence

`docs/evidence/p0a-probe/`:
- `failing-field-list.txt` — the 29 component-schema properties, with the reproducing
  Python one-liner.
- `Types-RAW-unbridged-excerpt.swift` — the 11 struct definitions (covering all 29
  properties) as generated from the RAW, unbridged schema. All 29 are absent.
- `Types-BRIDGED-excerpt.swift` — the same 11 structs generated from the bridged schema.
  All 29 present, each carrying its `- Remark: Generated from` provenance comment.
- `greps.txt` — the actual survival-check commands and their real output (0/29 survived
  raw, 29/29 survived bridged), plus the `userInterfaceIdiom` absence grep with its
  positive control.

These replace an earlier reference to `.phase-ledger.md` as the evidence location — that
file is operational (gitignored, never committed, never part of what a gate reviews), so a
reader of the committed tree could never actually reach it. The evidence now lives in the
tree the bridge itself lives in.
