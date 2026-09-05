# OpenAPI normalization bridge — pinned debt (RESOLVED)

**Addendum 2026-09-05 (WP21 P1, IMGMGR-371) — the PARAMETER half is retired, by the SERVER, and
this document's last open count is now zero.** Re-vendored at img-manager
`bac5dd16cb137ebcf4fe92b5b3361b52b93658ae` (tag v0.20.0, the WP17 P5 `--accept-breaking` recut).
The ten `?sidecar` query parameters that carried a `title` beside their `anyOf: [$ref, null]` —
counted as `still_dropped_nullable_unions=10` at every sha up to 0edeb4f (v0.18.0) — now arrive as
`{"$ref": "#/components/schemas/SidecarPresence", "title": "Sidecar"}`, the shape
swift-openapi-generator emits. Nothing in this repo changed to achieve that and nothing in this
repo may claim it: the server stopped writing the union. `Packages/ImgManagerAPI/OPENAPI_SOURCE`
now reads `canonicalized_nullable_refs=7`, `still_dropped_nullable_unions=0`, read back from the
file.

The seven optional MODEL properties (`ApiHealthResponse.maintenance`, `MaintenanceBusy.active_run`,
`RunCounters.backfill/index/precompute/progress`, `StatusResponse.active_run`) still rewrite, by
owner decision IMGMGR-281 **(b)** (2026-09-03): the null union stays in the server's schema and the
iOS bridge stays here. `NullableSurvivalTests` still pins those seven, and adds none.

`scripts/sync-openapi.sh`'s parameter loop is KEPT although it now matches zero sites — deleting it
would also delete its REQUIRED-site refusal (`scripts/sync-openapi.sh:174-178`), the guard against a
regression re-introducing the shape on a parameter this client cannot then send. It is an inert
guard, and the counter it feeds is the evidence that it is inert. The `diff` against
`git show bac5dd16…:frontend/openapi.json` is 77 lines, all seven property sites and nothing else.

**Addendum 2026-08-31 (WP14 lane A, IMGMGR-249) — one narrow rewrite is back, and the
"byte-identical" claim below is no longer the whole truth.** The retirement was right about
SCALAR nullables: img-manager emits `type: [X, "null"]` natively and 188 sites arrive that way.
It was wrong to generalise. A nullable MODEL reference has no type-array spelling — JSON Schema
can only write `anyOf: [{"$ref": X}, {"type": "null"}]` — so 17 such sites survive at every sha
since (measured at 5615fd9, at img-manager main 106fbd1 and at the vendored
`74203992ac1d41d6a2eea097bbe3b7101753e41a`), and swift-openapi-generator 1.13.0 drops each one
whole. Measured on the gate's own generated `Types.swift` at ios 0466798: `activeRun` 0 hits,
positive control `lastIndexedAt` 5 hits — which is exactly why the Status sheet could not name
the maintenance job that was running.

`scripts/sync-openapi.sh` therefore canonicalises that ONE shape to the bare `$ref` it means, at
the 7 optional component-schema sites that carry no sibling keys, refusing outright on a required
site. The 10 `?sidecar` query parameters carry a `title` sibling, are left exactly as the server
wrote them, are still dropped by the generator, and are ENUMERATED by the script on every sync
(`still_dropped_nullable_unions` in `OPENAPI_SOURCE`) rather than passed over in silence. Nothing
in this client consumes `?sidecar` today. The vendored file is byte-identical to the source
except for those 7 rewrites — a plain `diff` against
`git show <sha>:frontend/openapi.json` shows 77 lines and nothing else. `NullableSurvivalTests`
pins all seven individually. The cleaner fix lives in the SERVER (emit a bare `$ref` for a
non-required `Optional[Model]`), which would let this rewrite retire a second time.

**Status:** CLOSED, WP8 P1-ios, re-vendor at img-manager commit
`eff6a12ddf3c7e2a6f748625747345ca57c86349` (v0.9.2 tag). P1-backend fixed the schema to emit
OAS 3.1 `type: [X, "null"]` natively; re-vendoring measured `bridge_nullable_rewritten=0`
(the condition named below as the retirement trigger). `tools/normalize-openapi.py`,
`Sources/ImgManagerAPI/openapi.vendored.json` and `scripts/sync-openapi.sh`'s bridge
invocation are deleted; `openapi.json` is now the single, byte-identical vendored file
(`cmp` against `git show eff6a12d…:frontend/openapi.json` exits 0). Disposition items 1–4
below are done; `NullableSurvivalTests.swift` covers the parameter-schema gap (item 4) with
`GET /api/folders`'s `tree` parameter and additionally proves the native-auth operations
(`NativeAuthOperationsExposedTests`) are exposed by the unbridged client. The rest of this
document is kept as the historical record the evidence in `docs/evidence/p0a-probe/` refers
to — the P0a probe findings below are still true of the schema AS IT WAS, not stale claims
about the current one.

**Original status (P0a, superseded by the above):** active debt, P0a-scoped. Owner of the
fix: P1-backend (img-manager repo). Owner of the deletion: P1-ios (this repo, P1's ios
sub-branch).

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

`docs/evidence/p0a-probe/` (corrected 2026-08-27, round 3 — an earlier round's hand-
extracted "excerpt" files here truncated mid-struct and were brace-unbalanced; they are
GONE, replaced by the complete generator output, independently auditable rather than
trusted):
- `failing-field-list.txt` — the 29 component-schema properties, with the reproducing
  Python one-liner.
- `Types-RAW-unbridged-COMPLETE.swift.gz` — the ENTIRE generated `Types.swift` (5511
  lines, gzip -9; exact sha256 of both the compressed file and its decompressed content
  in `SHA256SUMS.txt` — not reproduced here as a truncated fragment, to avoid a
  transcription error), from a fresh `swift build` against the RAW (unbridged) vendored
  schema. All 29 target properties are absent — verifiable with `gunzip -c … | grep -F
  '#/components/schemas/ImagePage/next_cursor'` (0 hits) or with
  `check-nullable-survival.sh` below.
- `Types-BRIDGED-COMPLETE.swift.gz` — the ENTIRE generated `Types.swift` (6326 lines,
  gzip -9, same hash-recording convention in `SHA256SUMS.txt`), same build against the
  bridged schema. All 29 present, each with its `- Remark: Generated from` provenance
  comment.
- `check-nullable-survival.sh` — the exact, committed, executable checker: for each
  `<Schema>/<property>` line in `failing-field-list.txt`, greps the given `Types.swift`
  for that property's exact provenance-comment marker and reports SURVIVED/DROPPED plus a
  `SURVIVED: n/N` summary. Reproducible by anyone: `gunzip -k
  Types-BRIDGED-COMPLETE.swift.gz && ./check-nullable-survival.sh
  Types-BRIDGED-COMPLETE.swift failing-field-list.txt`.
- `SHA256SUMS.txt` — sha256 of both COMPLETE files, compressed and uncompressed.
- `greps.txt` — the checker's REAL, literal output run against both COMPLETE files (0/29
  survived raw, 29/29 survived bridged, every one of the 29 lines individually), plus the
  `userInterfaceIdiom` absence grep with its positive control.

These replace an earlier reference to `.phase-ledger.md` as the evidence location — that
file is operational (gitignored, never committed, never part of what a gate reviews), so a
reader of the committed tree could never actually reach it. The evidence now lives in the
tree the bridge itself lives in, and it is the complete generator output rather than a
hand-extracted excerpt, so nothing about its completeness needs to be taken on trust.
