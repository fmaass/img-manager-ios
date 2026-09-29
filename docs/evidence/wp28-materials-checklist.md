# WP28 materials checklist (IMGMGR-451)

Plan: WP28 Phase 4 (`PLAN_2026-09-28_wp28-glass-shell.md`), design record p4128 "Materials and
sizing rules", ADR-N1. One row per surface × rule. Every row cites the test, gate leg or named
screenshot that proves it. The screenshots are the 36 names in
`Tests/ImgManagerUITests/MaterialsScreenshotManifest.txt`, resolved by the gate into
`.gate-artifacts/screenshots/materials/` (`gate_check_materials_manifest`, which fails when a name
is missing, empty, or byte-identical to its default sibling; the one guarded exception, a Reduce
Transparency mode that is UNRESOLVED, is described below and did not trigger).

**Status: green on the gate on 35ba839 (queue-lane-m-004049) — exit 0, 01:54Z.** All 36 named shots resolved: 18 OK
per destination in both manifest checks, none UNRESOLVED, MISSING, EMPTY or IDENTICAL. Both
settings read back before every capture on both destinations. Reduce Transparency read
`reduceTransparency=1 envReduceTransparency=1` (6 × `MATERIALS-READBACK … ok=true` per
destination, in one run each). Increase Contrast read `darkerSystemColors=1
envIncreasedContrast=1` (6 × `ok=true` per destination).

Reduce Transparency takes through two keys written together: the plan's
`ReduceTransparencyEnabled` and `EnhancedBackgroundContrastEnabled`, the key the Settings switch
is stored under. The second key was added in fold round 1. The first gate (832e6f1) wrote the
plan's key alone, and the app never read the setting back.

The UNRESOLVED marker path is kept only as a guarded fallback, and it did not trigger on 35ba839.
If the app reads exactly the default reading in Reduce Transparency mode, the suite records
`materials-unresolved-<dest>-reduce-transparency` and skips. That marker must carry the run's gate
token (`TEST_RUNNER_IMG_MATERIALS_RUN`, recorded in `.gate-artifacts/materials-<leg>-<mode>.run`),
come from its own mode's export, and read `"reduceTransparency": "0"`. A stale or copied-in marker
is BADMARKER. A marker beside any captured shot of its mode is MIXED, and both fail the leg. Only a
run that exited 0 with the marker earns the one pivot retry.

## How each rule is proven

| Rule | Executable proof |
|---|---|
| No glass on glass | `no-custom-glass-grep` leg (no `glassEffect…(`, `GlassEffectContainer`, `.buttonStyle(.glass…`, `Glass(Prominent)ButtonStyle` in any app/widget source; no `UIDesignRequiresCompatibility`), plus the site audit below |
| Tint only for meaning | the tint audit below (grep: `.tint(`, `foregroundStyle(<colour>)`, `accentColor` over `Sources/ImgManager`) |
| 28 pt floor, 44 pt WATCH | the census (`ChromeCensus.swift`): `ChromeTouchTargetUITests` in the shell's resting states, `MaterialsScreenshotUITests` (default mode) in the states only the matrix reaches — every control in every navigation bar, toolbar and tab bar on screen, plus the app's own bars by identifier; every bar on screen must hold a counted control (a bar holding only text, with at least one non-empty text, is logged `title-only`; the matrix holds its census failures until the matrix ends, so they never stop a capture); an app-owned control below 28 pt fails, a system-owned one (closed list) is WATCH; `TOUCH-TARGET` line per control and a `touch-targets-…` attachment |
| Reduce Transparency | the real setting (`simctl spawn <udid> defaults write com.apple.Accessibility ReduceTransparencyEnabled -bool true` and `… EnhancedBackgroundContrastEnabled -bool true`; pivot `notifyutil -p com.apple.accessibility.cache.reduce.transparency` and `….cache.enhance.background.contrast`, then one more cold run), the full reading (setting AND SwiftUI environment) asserted in the app before each capture, read back on the gate on 35ba839 (queue-lane-m-004049); the guarded fallback (exactly the default reading ⇒ UNRESOLVED marker, nothing captured) did not trigger there; `MaterialPolicy` → opaque `secondarySystemBackground` |
| Increase Contrast | the real setting (`simctl ui <udid> increase_contrast enabled`), the full reading asserted in the app before each capture (no UNRESOLVED escape: a mismatch is red); `MaterialPolicy` → separator stroke |

## Glass-on-glass audit (every app-drawn material fill)

All nine fills now go through `MaterialPolicy` (`Shell/MaterialPolicy.swift`, `chromeFill`).

| # | Site | Where it renders | Finding | Fix |
|---|---|---|---|---|
| G1 | `Queue/QueueView.swift:111` refresh capsule (`.thinMaterial`) | over the folder list — at Regular that list IS the glass sidebar | material inside system glass | `chromeFill(.insideSystemGlass, in: Capsule())`: opaque `secondarySystemBackground` in every mode |
| G2 | `Grid/GridView.swift:1088` action bar (`.bar`) | bottom of the grid column; `.background(_:)` ignores safe areas by default | **OBSERVED** (`iphone-grid-pushed-default.png`, gate on 832e6f1): the fill runs on under the floating tab bar to the screen's bottom edge; the tab bar's glass floats over it as it floats over the grid, and every action-bar control sits wholly above the tab bar, none occluded. No app material is drawn INSIDE system glass, so no glass-on-glass; left for adjudication | routed (`chromeFill(.bar)`, default unchanged); stopping the fill at the bottom safe area would also change the Regular bottom edge, so it is not applied |
| G3 | `Grid/GridView.swift:791` options row, `:852` lock row, `:886` select row (`.thinMaterial`) | content column, directly below the navigation bar | not inside a bar | routed (`chromeFill(.thinMaterial)`) |
| G4 | `Grid/GridView.swift:1277` marks-copy banner, `:1302` conflict banner (`.thinMaterial`) | content column, above the action bar | not inside a bar | routed (`chromeFill(.thinMaterial)`) |
| G5 | `Loupe/LoupeView.swift:419` mark bar, `:710` filmstrip (`.bar`) | loupe content | not inside a system bar | routed (`chromeFill(.bar)`); no other loupe change (Do-NOT) |
| G6 | `Loupe/LoupeView.swift:316`, `:330` prev/next circles, `:786` changed-elsewhere badge (`.black.opacity`) | over the photograph | not a material; a legibility scrim on content | unchanged: no rule applies — `MaterialPolicy` governs material fills, and restyling loupe chrome is out of scope |

`glassEffect` call sites: 0. `SDKSurfaceProbe` (DEBUG) calls none of the leg's APIs, so the leg needs
no exclusion.

## Tint audit (chrome tints and coloured foregrounds)

| # | Site | Meaning |
|---|---|---|
| T1 | `Grid/GridView.swift:1240` `.tint(MarkPalette…)` on Pick/Dislike | mark verdict |
| T2 | `Loupe/LoupeView.swift:449` `.tint(isActive ? MarkPalette… : nil)` | active mark state |
| T3 | `Queue/QueueView.swift:331` sync badge `presentation.tint` (orange/green/secondary) | sync state |
| T4 | `Grid/FilterPopoverView.swift:38` accent dot | filters active |
| T5 | `Queue/FolderTreeSection.swift:516,519` accent selection | selected row |
| T6 | `Grid/TileView.swift`, `Grid/SceneCardView.swift`, `Grid/FilterPopoverView.swift:173` mark colours and focus strokes | content, mark/focus state (not chrome) |

No decorative tint in chrome; nothing changed.

## Touch-target WATCH rows

Read from the gate's `TOUCH-TARGET` census lines (and the `touch-targets-compact`,
`touch-targets-regular3`, `touch-targets-iphone-matrix` and `touch-targets-ipad-matrix`
attachments): one line per control with its state, owner, name, frame and verdict, a
`TOUCH-TARGET BAR` line per bar and a `TOUCH-TARGET CENSUS` count line per report.

Ownership is decided by identifier first (`ChromeOwnership`, fold round 2): an identifier in the
app's namespace (every id the app sets starts with a lowercase letter) is ALWAYS app-owned,
whatever its label. A control without one is system-owned only on a closed list — the
identifiers `BackButton` and `ToggleSidebar`, a tab bar button, a search field and its contents,
and the navigation title menu — only in a state the census declares as carrying one, for an
unidentified navigation-bar button inside no other control whose label ends with ", Actions
Menu", is exactly a fixture title or the workspace's neutral fallback title "Shoot" (fold round
3; the gate on bd47740 showed "Shoots, Actions Menu" on the Shoots root and the bare fixture
title at Regular-3), or is exactly the declared state's own title (final audit: the Shoots root
read bare "Shoots" on one gate of c71718c and "Shoots, Actions Menu" on another, so the census
declares `stateTitles: ["Shoots"]` there). A label alone never makes a control the system's, so
an app control reusing "More" or "Search" is judged against the floor
(`testOwnershipIsByIdentifierFirst` proves the precedence). System-owned chrome is reported,
never failed — growing it would need custom chrome, which ADR-N1 forbids. Measured on the gate
on 832e6f1; the title-menu rows are from the gate on 35ba839 (queue-lane-m-004049; 0 FAIL, 96 WATCH):

| Control | Owner | Frame | Verdict |
|---|---|---|---|
| Title menu trigger, Compact grid bar ("stub") | system | 36 × 20.7 pt (its title text) | **WATCH** — below 28 pt, system-owned |
| Title menu trigger, Compact Shoots root ("Shoots, Actions Menu", or bare "Shoots") | system | 56 × 20.7 pt (its title text) | **WATCH** — below 28 pt, system-owned |
| Title menu trigger, Regular-3 grid bar | system | 211 × 21 pt (its title text) | **WATCH** — below 28 pt, system-owned |
| Account / View / Info, Compact bar | app | 36 × 36 pt | WATCH (≥ 28, < 44) |
| Account / View / Info, Regular-3 bar | app | 50 × 36 / 51 × 36 / 40 × 36 pt | WATCH |
| The five view options, Regular-3 bar | app | 39–47 × 36 pt | WATCH |
| Filter / Sort / Group / Zoom, Compact options row | app | 42 × 31, 65 × 32, 77 × 34, 71 × 32 pt | WATCH |
| Keyboard shortcuts, Compact options row | app | 46.7 × 27.7 pt | **FAIL → fixed in fold round 1**: the bordered capsule is the hit target and the keyboard glyph is short; the label now has an 18 pt minimum height, bringing the capsule to its siblings' height. The next gate's line is the proof |
| The three tabs, Compact | system (app when the button carries its `tab.*` id) | 94 × 54, 94 × 54, 62 × 62 pt | OK |
| More (action bar) | app | not measured before fold round 1 | the menu draws no capsule, so its label now carries the bar's 44 pt with a hit shape (nothing drawn); the next gate's census line is the proof |

NOT MEASURED: the loupe's bars. The loupe is in no matrix state and reaching it would add a
launch and a navigation to a leg that already runs 82+ tests; its chrome is routed fills only
(plan: no restyle). Not in the plan's list but noted: the Regular minimised
search button, 36 × 36 pt (P2 gate on 20d9c58) — WATCH.

## Surface × rule

| Surface | Rule | Status | Proof |
|---|---|---|---|
| Shoots tab root (Compact) | No glass on glass | CITED — gate leg | no-custom-glass-grep; audit G1 (the refresh capsule is never a material: `insideSystemGlass`); screenshot `iphone-shoots-home-default.png` |
| Shoots tab root (Compact) | Tint only for meaning | CITED — audit | audit T1–T6 (every chrome tint is a mark/state tint); screenshot `iphone-shoots-home-default.png` |
| Shoots tab root (Compact) | 28 pt floor / 44 pt WATCH | CITED — census (`TOUCH-TARGET` lines; app < 28 fails, system < 28 WATCH) | `ChromeTouchTargetUITests.testCompactChromeTouchTargets`, state `shoots`: every nav bar + tab bar control (requires Account and the three tabs) |
| Shoots tab root (Compact) | Reduce Transparency | CITED — screenshot, full read-back asserted (`reduceTransparency=1 envReduceTransparency=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `iphone-shoots-home-reduce-transparency.png` + `MaterialsScreenshotUITests` read-back (`reduceTransparency=1`) + `MaterialPolicyTests.reduceTransparencyIsOpaque` |
| Shoots tab root (Compact) | Increase Contrast | CITED — screenshot, full read-back asserted (`darkerSystemColors=1 envIncreasedContrast=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `iphone-shoots-home-increase-contrast.png` + `MaterialsScreenshotUITests` read-back (`darkerSystemColors=1`) + `MaterialPolicyTests.increaseContrastStrokes` |
| Library tab root (Compact) | No glass on glass | CITED — gate leg | no-custom-glass-grep; audit G1; screenshot `iphone-library-default.png` |
| Library tab root (Compact) | Tint only for meaning | CITED — audit | audit T1–T6 (every chrome tint is a mark/state tint); screenshot `iphone-library-default.png` |
| Library tab root (Compact) | 28 pt floor / 44 pt WATCH | CITED — census (`TOUCH-TARGET` lines; app < 28 fails, system < 28 WATCH) | `ChromeTouchTargetUITests.testCompactChromeTouchTargets`, state `library`: every nav bar + tab bar control (requires View) |
| Library tab root (Compact) | Reduce Transparency | CITED — screenshot, full read-back asserted (`reduceTransparency=1 envReduceTransparency=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `iphone-library-reduce-transparency.png` + `MaterialsScreenshotUITests` read-back (`reduceTransparency=1`) + `MaterialPolicyTests.reduceTransparencyIsOpaque` |
| Library tab root (Compact) | Increase Contrast | CITED — screenshot, full read-back asserted (`darkerSystemColors=1 envIncreasedContrast=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `iphone-library-increase-contrast.png` + `MaterialsScreenshotUITests` read-back (`darkerSystemColors=1`) + `MaterialPolicyTests.increaseContrastStrokes` |
| Search tab, field active (Compact) | No glass on glass | CITED — gate leg | no-custom-glass-grep; no app-drawn fill on this surface; screenshot `iphone-search-active-default.png` |
| Search tab, field active (Compact) | Tint only for meaning | CITED — audit | audit T1–T6 (every chrome tint is a mark/state tint); screenshot `iphone-search-active-default.png` |
| Search tab, field active (Compact) | 28 pt floor / 44 pt WATCH | CITED — matrix census (default mode; `TOUCH-TARGET` lines and `touch-targets-iphone-matrix` attachment; app < 28 fails, system < 28 WATCH, every bar on screen must hold a counted control) | `MaterialsScreenshotUITests.testCompactMaterialsMatrix`, state `search-active`: every bar plus the search field (required) |
| Search tab, field active (Compact) | Reduce Transparency | CITED — screenshot, full read-back asserted (`reduceTransparency=1 envReduceTransparency=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `iphone-search-active-reduce-transparency.png` + `MaterialsScreenshotUITests` read-back (`reduceTransparency=1`) + `MaterialPolicyTests.reduceTransparencyIsOpaque` |
| Search tab, field active (Compact) | Increase Contrast | CITED — screenshot, full read-back asserted (`darkerSystemColors=1 envIncreasedContrast=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `iphone-search-active-increase-contrast.png` + `MaterialsScreenshotUITests` read-back (`darkerSystemColors=1`) + `MaterialPolicyTests.increaseContrastStrokes` |
| Grid pushed on a tab (Compact) | No glass on glass | CITED — gate leg | no-custom-glass-grep; audit G2 **OBSERVED** (the action bar's `.bar` runs under the floating tab bar; no control occluded); screenshot `iphone-grid-pushed-default.png` |
| Grid pushed on a tab (Compact) | Tint only for meaning | CITED — audit | audit T1–T6 (every chrome tint is a mark/state tint); screenshot `iphone-grid-pushed-default.png` |
| Grid pushed on a tab (Compact) | 28 pt floor / 44 pt WATCH | CITED — census (`TOUCH-TARGET` lines; app < 28 fails, system < 28 WATCH) | `ChromeTouchTargetUITests.testCompactChromeTouchTargets`, state `grid`: every nav bar + tab bar control (requires Info, title menu), the five options-row controls and the action bar by identifier |
| Grid pushed on a tab (Compact) | Reduce Transparency | CITED — screenshot, full read-back asserted (`reduceTransparency=1 envReduceTransparency=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `iphone-grid-pushed-reduce-transparency.png` + `MaterialsScreenshotUITests` read-back (`reduceTransparency=1`) + `MaterialPolicyTests.reduceTransparencyIsOpaque` |
| Grid pushed on a tab (Compact) | Increase Contrast | CITED — screenshot, full read-back asserted (`darkerSystemColors=1 envIncreasedContrast=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `iphone-grid-pushed-increase-contrast.png` + `MaterialsScreenshotUITests` read-back (`darkerSystemColors=1`) + `MaterialPolicyTests.increaseContrastStrokes` |
| Inspector sheet (Compact) | No glass on glass | CITED — gate leg | no-custom-glass-grep; the sheet content draws no material (grep of `Grid/InspectorView.swift`: 0 material fills); screenshot `iphone-inspector-sheet-default.png` |
| Inspector sheet (Compact) | Tint only for meaning | CITED — audit | audit T1–T6 (every chrome tint is a mark/state tint); screenshot `iphone-inspector-sheet-default.png` |
| Inspector sheet (Compact) | 28 pt floor / 44 pt WATCH | CITED — matrix census (default mode; `TOUCH-TARGET` lines and `touch-targets-iphone-matrix` attachment; app < 28 fails, system < 28 WATCH, every bar on screen must hold a counted control) | `MaterialsScreenshotUITests.testCompactMaterialsMatrix`, state `inspector-sheet`: every bar plus the sheet's Info/Stats segment (Stats required) |
| Inspector sheet (Compact) | Reduce Transparency | CITED — screenshot, full read-back asserted (`reduceTransparency=1 envReduceTransparency=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `iphone-inspector-sheet-reduce-transparency.png` + `MaterialsScreenshotUITests` read-back (`reduceTransparency=1`) + `MaterialPolicyTests.reduceTransparencyIsOpaque` |
| Inspector sheet (Compact) | Increase Contrast | CITED — screenshot, full read-back asserted (`darkerSystemColors=1 envIncreasedContrast=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `iphone-inspector-sheet-increase-contrast.png` + `MaterialsScreenshotUITests` read-back (`darkerSystemColors=1`) + `MaterialPolicyTests.increaseContrastStrokes` |
| Shoot Summary sheet (Compact) | No glass on glass | CITED — gate leg | no-custom-glass-grep; `Summary/` draws no material (0 material fills); screenshot `iphone-summary-sheet-default.png` |
| Shoot Summary sheet (Compact) | Tint only for meaning | CITED — audit | audit T1–T6 (every chrome tint is a mark/state tint); screenshot `iphone-summary-sheet-default.png` |
| Shoot Summary sheet (Compact) | 28 pt floor / 44 pt WATCH | CITED — matrix census (default mode; `TOUCH-TARGET` lines and `touch-targets-iphone-matrix` attachment; app < 28 fails, system < 28 WATCH, every bar on screen must hold a counted control) | `MaterialsScreenshotUITests.testCompactMaterialsMatrix`, state `summary-sheet`: every bar, Done required |
| Shoot Summary sheet (Compact) | Reduce Transparency | CITED — screenshot, full read-back asserted (`reduceTransparency=1 envReduceTransparency=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `iphone-summary-sheet-reduce-transparency.png` + `MaterialsScreenshotUITests` read-back (`reduceTransparency=1`) + `MaterialPolicyTests.reduceTransparencyIsOpaque` |
| Shoot Summary sheet (Compact) | Increase Contrast | CITED — screenshot, full read-back asserted (`darkerSystemColors=1 envIncreasedContrast=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `iphone-summary-sheet-increase-contrast.png` + `MaterialsScreenshotUITests` read-back (`darkerSystemColors=1`) + `MaterialPolicyTests.increaseContrastStrokes` |
| Regular-3, inspector collapsed | No glass on glass | CITED — gate leg | no-custom-glass-grep; audit G1 (sidebar capsule opaque); options/mode rows are content, not bar; screenshot `ipad-regular3-collapsed-default.png` |
| Regular-3, inspector collapsed | Tint only for meaning | CITED — audit | audit T1–T6 (every chrome tint is a mark/state tint); screenshot `ipad-regular3-collapsed-default.png` |
| Regular-3, inspector collapsed | 28 pt floor / 44 pt WATCH | CITED — census (`TOUCH-TARGET` lines; app < 28 fails, system < 28 WATCH) | `ChromeTouchTargetUITests.testRegularChromeTouchTargets`: census of every nav bar / toolbar control (the six, Account, View, title menu, system items) + the action bar by identifier |
| Regular-3, inspector collapsed | Reduce Transparency | CITED — screenshot, full read-back asserted (`reduceTransparency=1 envReduceTransparency=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `ipad-regular3-collapsed-reduce-transparency.png` + `MaterialsScreenshotUITests` read-back (`reduceTransparency=1`) + `MaterialPolicyTests.reduceTransparencyIsOpaque` |
| Regular-3, inspector collapsed | Increase Contrast | CITED — screenshot, full read-back asserted (`darkerSystemColors=1 envIncreasedContrast=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `ipad-regular3-collapsed-increase-contrast.png` + `MaterialsScreenshotUITests` read-back (`darkerSystemColors=1`) + `MaterialPolicyTests.increaseContrastStrokes` |
| Regular-3, inspector shown | No glass on glass | CITED — gate leg | no-custom-glass-grep; the system `.inspector` column draws no app material; screenshot `ipad-regular3-inspector-default.png` |
| Regular-3, inspector shown | Tint only for meaning | CITED — audit | audit T1–T6 (every chrome tint is a mark/state tint); screenshot `ipad-regular3-inspector-default.png` |
| Regular-3, inspector shown | 28 pt floor / 44 pt WATCH | CITED — matrix census (default mode; `TOUCH-TARGET` lines and `touch-targets-ipad-matrix` attachment; app < 28 fails, system < 28 WATCH, every bar on screen must hold a counted control) | `MaterialsScreenshotUITests.testRegularMaterialsMatrix`, state `regular3-inspector`: every bar, Info required |
| Regular-3, inspector shown | Reduce Transparency | CITED — screenshot, full read-back asserted (`reduceTransparency=1 envReduceTransparency=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `ipad-regular3-inspector-reduce-transparency.png` + `MaterialsScreenshotUITests` read-back (`reduceTransparency=1`) + `MaterialPolicyTests.reduceTransparencyIsOpaque` |
| Regular-3, inspector shown | Increase Contrast | CITED — screenshot, full read-back asserted (`darkerSystemColors=1 envIncreasedContrast=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `ipad-regular3-inspector-increase-contrast.png` + `MaterialsScreenshotUITests` read-back (`darkerSystemColors=1`) + `MaterialPolicyTests.increaseContrastStrokes` |
| Regular-2 grid beside the sidebar | No glass on glass | CITED — gate leg | no-custom-glass-grep; audit G1; screenshot `ipad-regular2-grid-default.png` |
| Regular-2 grid beside the sidebar | Tint only for meaning | CITED — audit | audit T1–T6 (every chrome tint is a mark/state tint); screenshot `ipad-regular2-grid-default.png` |
| Regular-2 grid beside the sidebar | 28 pt floor / 44 pt WATCH | CITED — matrix census (default mode; `TOUCH-TARGET` lines and `touch-targets-ipad-matrix` attachment; app < 28 fails, system < 28 WATCH, every bar on screen must hold a counted control) | `MaterialsScreenshotUITests.testRegularMaterialsMatrix`, state `regular2-grid`: every bar, Info required, plus the five view options and the action bar by id (as the Compact grid state) (skips with the capture when the destination cannot reach Regular-2) |
| Regular-2 grid beside the sidebar | Reduce Transparency | CITED — screenshot, full read-back asserted (`reduceTransparency=1 envReduceTransparency=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `ipad-regular2-grid-reduce-transparency.png` + `MaterialsScreenshotUITests` read-back (`reduceTransparency=1`) + `MaterialPolicyTests.reduceTransparencyIsOpaque` |
| Regular-2 grid beside the sidebar | Increase Contrast | CITED — screenshot, full read-back asserted (`darkerSystemColors=1 envIncreasedContrast=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `ipad-regular2-grid-increase-contrast.png` + `MaterialsScreenshotUITests` read-back (`darkerSystemColors=1`) + `MaterialPolicyTests.increaseContrastStrokes` |
| Regular toolbar search active | No glass on glass | CITED — gate leg | no-custom-glass-grep; no app-drawn fill on this surface; screenshot `ipad-search-active-default.png` |
| Regular toolbar search active | Tint only for meaning | CITED — audit | audit T1–T6 (every chrome tint is a mark/state tint); screenshot `ipad-search-active-default.png` |
| Regular toolbar search active | 28 pt floor / 44 pt WATCH | CITED — matrix census (default mode; `TOUCH-TARGET` lines and `touch-targets-ipad-matrix` attachment; app < 28 fails, system < 28 WATCH, every bar on screen must hold a counted control) | `MaterialsScreenshotUITests.testRegularMaterialsMatrix`, state `search-active`: every bar plus the search field (required) |
| Regular toolbar search active | Reduce Transparency | CITED — screenshot, full read-back asserted (`reduceTransparency=1 envReduceTransparency=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `ipad-search-active-reduce-transparency.png` + `MaterialsScreenshotUITests` read-back (`reduceTransparency=1`) + `MaterialPolicyTests.reduceTransparencyIsOpaque` |
| Regular toolbar search active | Increase Contrast | CITED — screenshot, full read-back asserted (`darkerSystemColors=1 envIncreasedContrast=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `ipad-search-active-increase-contrast.png` + `MaterialsScreenshotUITests` read-back (`darkerSystemColors=1`) + `MaterialPolicyTests.increaseContrastStrokes` |
| Shoot Summary form sheet (Regular) | No glass on glass | CITED — gate leg | no-custom-glass-grep; `Summary/` draws no material (0 material fills); screenshot `ipad-summary-sheet-default.png` |
| Shoot Summary form sheet (Regular) | Tint only for meaning | CITED — audit | audit T1–T6 (every chrome tint is a mark/state tint); screenshot `ipad-summary-sheet-default.png` |
| Shoot Summary form sheet (Regular) | 28 pt floor / 44 pt WATCH | CITED — matrix census (default mode; `TOUCH-TARGET` lines and `touch-targets-ipad-matrix` attachment; app < 28 fails, system < 28 WATCH, every bar on screen must hold a counted control) | `MaterialsScreenshotUITests.testRegularMaterialsMatrix`, state `summary-sheet`: every bar, Done required |
| Shoot Summary form sheet (Regular) | Reduce Transparency | CITED — screenshot, full read-back asserted (`reduceTransparency=1 envReduceTransparency=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `ipad-summary-sheet-reduce-transparency.png` + `MaterialsScreenshotUITests` read-back (`reduceTransparency=1`) + `MaterialPolicyTests.reduceTransparencyIsOpaque` |
| Shoot Summary form sheet (Regular) | Increase Contrast | CITED — screenshot, full read-back asserted (`darkerSystemColors=1 envIncreasedContrast=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `ipad-summary-sheet-increase-contrast.png` + `MaterialsScreenshotUITests` read-back (`darkerSystemColors=1`) + `MaterialPolicyTests.increaseContrastStrokes` |
| Select mode bar (Regular-3) | No glass on glass | CITED — gate leg | no-custom-glass-grep; the select row's `.thinMaterial` sits in the content column under the bar, not in it (audit G3); screenshot `ipad-select-bar-default.png` |
| Select mode bar (Regular-3) | Tint only for meaning | CITED — audit | audit T1–T6 (every chrome tint is a mark/state tint); screenshot `ipad-select-bar-default.png` |
| Select mode bar (Regular-3) | 28 pt floor / 44 pt WATCH | CITED — matrix census (default mode; `TOUCH-TARGET` lines and `touch-targets-ipad-matrix` attachment; app < 28 fails, system < 28 WATCH, every bar on screen must hold a counted control) | `MaterialsScreenshotUITests.testRegularMaterialsMatrix`, state `select-bar`: every bar plus the select bar's Done by its id `selectModeDone` (required). The gate on bd47740 measured it 40.5 × 20.5 pt (FAIL, the text alone); fold round 3 puts the 44 pt frame and a hit shape on its label, and the gate on 35ba839 (queue-lane-m-004049) measured it 44 × 44 pt (OK) |
| Select mode bar (Regular-3) | Reduce Transparency | CITED — screenshot, full read-back asserted (`reduceTransparency=1 envReduceTransparency=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `ipad-select-bar-reduce-transparency.png` + `MaterialsScreenshotUITests` read-back (`reduceTransparency=1`) + `MaterialPolicyTests.reduceTransparencyIsOpaque` |
| Select mode bar (Regular-3) | Increase Contrast | CITED — screenshot, full read-back asserted (`darkerSystemColors=1 envIncreasedContrast=1`, read back on the gate on 35ba839 (queue-lane-m-004049)) | `ipad-select-bar-increase-contrast.png` + `MaterialsScreenshotUITests` read-back (`darkerSystemColors=1`) + `MaterialPolicyTests.increaseContrastStrokes` |
