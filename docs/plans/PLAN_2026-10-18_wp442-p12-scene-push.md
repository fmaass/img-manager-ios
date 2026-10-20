# PLAN 2026-10-18 r6 — WP442 P12 (IMGMGR-540): a scene card pushes a scene screen with a count pill

**r6 ACCEPTED — owner ruling 2026-10-19 (IMGMGR-540 comment 12171), no further plan round.** Approved for Stage B.
**r6** answers plan gate r5 (20261019T060156Z-7160be, REVISE, 1 BLOCKING: the retry record
outlives a same-id resolution), §0r6; nothing else moves. r5 ran as the owner-authorised 5th round.
**r5** answers plan gate r4 (20261019T054240Z-fca604, REVISE, 1 BLOCKING: B1 failed candidate
read), §0r5; nothing else moves. r4 backup: `scratchpad/backup-r5/docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md`.
r4 ran as the owner-authorised 4th round (IMGMGR-540 comment 12079).

Stage B worktree `/home/fabian/projects/img-manager-ios-lane/.worktrees/wp442-p12`, branch
`feature/wp442-r3-p12-scene-push-r4` (based on main dcaab0e). Stage A drafted in
`.worktrees/wp442-p12-scene-push` on `feature/wp442-r3-p12-scene-push` (origin/main 58f2b10,
rebased onto main dcaab0e and re-anchored there, §0r4.1).
**r4** (the authorised 4th round) answers plan gate r3 (20261018T112010Z-74aaaf,
REVISE, 2 BLOCKING). r3 backup: `scratchpad/backup-540-r4/docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md`.
**r3** (FINAL plan round) answered plan gate r2 (20261018T110915Z-db8714, REVISE, 3 BLOCKING).
**r2** answered gate r1 (20261018T105213Z-29cd01). Backups: r1 at
`scratchpad/backup-540-r2/docs/plans/PLAN_r1.md`, r2 at
`scratchpad/backup-540-r3/docs/plans/PLAN_2026-10-18_wp442-p12-scene-push.md`. All line anchors
are at main dcaab0e (`dcaab0ec`, P9 + P11a + IMGMGR-558 + P11b on top of 58f2b10).

## Owner decision (granted: round 4, comment 12079)

- **Rounds 1–3 of the plan gate were REVISE**: r1 `20261018T105213Z-29cd01` (5 blocking),
  r2 `20261018T110915Z-db8714` (3 blocking), r3 `20261018T112010Z-74aaaf` (2 blocking). The
  round cap was reached. The owner authorised ONE 4th round on r4 (IMGMGR-540 comment 12079);
  this re-anchored r4 is what goes to it.
- **What r4 changes** (two blockers, one advisory; nothing else moves):
  1. B1: after a topology edit, the coordinator FETCHES the destination's members before it
     retargets (the survivor of a merge; the split part that holds the anchor). It re-checks
     ownership `(enteredStackID, sceneRevision)` after every await. When ownership has moved,
     it restores the scene entered NOW, so the reload's cache clear never leaves it empty
     (§2.3a). The held-edit tests now assert the displayed members, not only `enteredSceneID`
     (U13, U13b–U13g).
  2. B2: `.stream` keeps the existing display-mode branch. Flat renders `images`, and Scene
     renders cards plus loose photos (`GridStore.swift:137`, `:201`; `GridView.swift:482-487`).
     New U28 (store) and T12 (view, Flat rendering and Scene→Flat) (§2.4).
  3. Advisory T8/M46: new deterministic U27 starts with every presentation flag TRUE, then leaves.
     M46 must fail that assertion. T8 no longer claims M46 (§4).
- **Alternative kept on record (not the round-4 subject): simplify the scope.** Ship the push on
  **Regular only** first. Regular already rebuilds one `GridView` per scope (§2.4), and it needs
  no Compact path projection (§2.2, R1–R11) and no second live instance (T8, W1/W6 gates).
  Move the **Compact push** to a follow-up ticket, with the in-place swap left on Compact until
  then. The topology fix (B1) and the Flat branch (B2) are needed in both variants. The
  reduced variant drops T8, T10, T11 and R1–R9, and needs a new plan round of its own.

## 0r6. What changed since r5 (per finding)

| finding | r6 answer | where |
|---|---|---|
| r5-B1 a successful Retry that resolves to the CURRENT entry leaves `sceneDestinationRetry` set, because the same-id retarget is a no-op and only a real `transitionScene` cleared it (split 5 → [5, 9], anchor in 5: 5 fails, 9 loads without the anchor → 4b; Retry loads 5 with the anchor → no-op retarget, record kept; a later foreground revalidation keeps resolving the old candidates and follows the anchor into 9 after a remote merge 5 → 9, instead of leaving on 5's 404) | step 5 clears `sceneDestinationRetry` on EVERY owned commit (leave, retarget, or same-id no-op), before the install, so the record lives only between a 4b and the next owned resolution; the "every real `transitionScene` clears it" rule stays for Back/enter/scope. U13h gains the same-id variant; new mutant M57 (clear only on a real transition) | §2.3a step 4b, step 5, §4 U13h |

## 0r5. What changed since r4 (per finding)

| finding | r5 answer | where |
|---|---|---|
| B1 a failed candidate read can silently select the wrong split part (split 5 → [5, 9], anchor in 9: 5 loads, 9 fails → r4 chose 5 by the first-id fallback, installed 5's members, no failure state) | step 4 now tells an UNRESOLVED destination (a candidate read failed and no loaded candidate holds the anchor) from an ESTABLISHED one (a loaded candidate holds the anchor; a single candidate; or EVERY candidate loaded and none holds it, the only case the `result.stackIds[0]` fallback is taken). Unresolved: no retarget and no member install; `sceneDestinationRetry` holds the candidates, `sceneLoadFailed` gets the entered id, so the screen is `.failed` with Retry, and Retry re-runs destination resolution (never `revalidateEnteredScene` on the old part). New U13h; mutants M55 (fallback on failure) and M56 (Retry revalidates the old part) | §2.3a step 4b, §4 U13h |

## 0r4.1 Re-anchored to main dcaab0e

The branch was rebased from 58f2b10 onto main dcaab0e (P9 Settings 5d4c28d, IMGMGR-558 bd7f56a,
P11a grid chrome 51dd9ce, P11b no-search dcaab0e). Every `path:line` citation and quoted code
premise below was re-read on dcaab0e. The BookStack copies (`r3-design-4336.md`,
`r3-plan-4337.md`, `r3-plan-phases.md` = 4337's § Phase 8 to § Phase 19) were re-fetched; their
cited lines (`:71-76`, `:154-160`, `:80`, `:32-36`) hold unchanged.

**Pure line shifts (95 citations, no premise change)**: GridStore +20 after `:1012` (+5/+7/+11
between `:241` and `:1012`), the premises unchanged; GridView +2 to +37 (gutter, canvas, probe
inserts); RootView +3 to +31; CompactShell −11; WorkspaceContent −3/−7; SceneCardView +2 after
`:108`; ScenePicksInGroupsTests +1; GridMoreMenuTests +42. Unchanged files keep their anchors:
SceneRows, GridService, SceneChrome, SelectBar, LoupeView, GridKeyboardActions, DebugProbe,
GridStubTransport, WorkspaceNavigation's cited lines, and DebugStubTransport `:408-500`. Six
bare `:N` cites now name their file (no number change). Main added no `toggleSceneExpanded`,
`sceneExpanded`, `isExpanded:`, `bandLeadMembers`, `gridScrollAnchor` or `sceneRows` use in
`Sources/` or `Tests/` (per-file counts identical), so §5's mapping and the §9 greps stand.

| old cite (58f2b10) | new cite (dcaab0e) | what changed | plan consequence |
|---|---|---|---|
| `CompactShell.swift:16-26,59-80`, `:41-48` | `CompactShell.swift:15-23,48-69` | P11b: the Search tab, `search: FolderSearchModel`, `searchRoot` and the `SearchRoot` generic are gone; `CompactShell<Shoots, Library, Destination>` (`:15`) has two stacks | the `(WorkspaceRoute) -> Destination` edit lands on a 3-generic struct; risk 7 closed. R1–R11 already use `.shoots`/`.library` only. No design change |
| `RootView.swift:165-174`, `:128` | `RootView.swift:167-176`, `:130-132`, `:651-653` | P9/P11b: the erasure handler no longer captures or ends `folderSearch`; the store is built by `Self.makeGridStore(service:settings:)` straight into `_gridStore` | §2.2: the `weak gridStore` capture needs a local bound from `makeGridStore` first (text added) |
| `RootView.swift:758-764`, `:1011-1018` | `RootView.swift:790-795`, `:1029-1039` | P11b: `CompactShell(...)` lost `search:`/`searchRoot:`; `WorkspaceContent(...)` lost `folderSearch:` | the new `enteredSceneID`/`onScenePopped` args go into the shorter calls. No design change |
| `GridStore.swift:755-773` (`selectShoot`) | `GridStore.swift:756-784` | IMGMGR-548 (P9): a new init closure `startsWithTapToPick` (`:242-246`, `:737-743`); on a REAL shoot change `pickLock.exit()` is followed by `if startsWithTapToPick() { pickLock.forceLatch(.pick) }` (`:769-773`). UI-test launches reset settings unless `-UITestKeepSettings` (`DebugStubTransport.swift:987`, `ImgManagerApp.swift:11`) | §2.3 row annotated: the transition never touches the latch, so `leaveScene(.scopeChanged)`'s place among the resets is order-free. A row tap (`openShoot`) to a DIFFERENT shoot may now land latched by the reader's setting; the same-shoot path is unchanged. T2/T5 start unlatched. No design change |
| (none: the Regular principal) | `WorkspaceContent.swift:178-214`, `GridBreadcrumb.swift:46-66` | P11a (R3-11): the Regular principal breadcrumb draws `GridBreadcrumb.subtitle`, the FOLDER's counts ("184 photos · 23 picks · 12 edited"), under the title (`:193-195`) | §2.5 + §3: inside a scene the breadcrumb is `(title: <scene title>, subtitle: nil)`. **Design consequence D1** |
| `WorkspaceContent.swift:44-112`, `:106` | `WorkspaceContent.swift:41-105`, `:99` | P11b: the grid branch lost `.modifier(RegularFolderSearch(...))` and the struct is deleted | the W6 `.inspector` gate is unchanged; the grid branch has one modifier fewer. No design change |
| `GridView.swift:136-176` (W7) | `GridView.swift:138-200` | P11a (IMGMGR-539): `debugProbeElement` also renders `debugProbe.gridChrome` (`:178-198`); the scroll content gains a black canvas, `GridGutter` spacing and per-tile `overlays:` (`:271-327`, `:372-375`, `:506-508`) | the W7 active-only gate covers the new probe too (GridChromeWiringUITests never enters a scene). The scene instance is the same `GridView`, so canvas, gutter and overlays carry inside. No design change |
| `SceneCardView.swift:40-215` | `SceneCardView.swift:40-217` | P11a (R3-15): the cover load is `.task(id: TileLoadKey.make(...))` + `store.proxyData(identity:)` (`:109-118`); badges and counts untouched | the §2.5 card edits (pill, bottom cluster, focusable) sit around the unchanged load. No design change |

**Design consequences**
- **D1 (P11a subtitle)**: r4 said only "the principal breadcrumb shows the scene title". On
  dcaab0e that slot also shows the folder's counts. r4.1 sets the scene's subtitle to nil (the
  title already states the count). This is the one design element a premise change forced; the
  alternative (keep the folder counts under the scene title) is the reviewer's to prefer.
- B1 (`loadCandidateMembers`, the ownership re-check), B2 (`displayRows(for:)`, the Flat/Scene
  branch) and the U27/M46 fix are re-anchored only. No sibling phase touched `runSceneEdit`
  (`GridStore.swift:1968`), the coordinator (`:2047-2085`), `fetchSceneMembers` (`:1654-1681`),
  `clearSceneWindow` (`:1265-1274`), `GridView.displayRows` (`GridView.swift:482-487`) or the
  presentation flags (`GridStore.swift:211`, `:224`, `:1781`, `:1810`, `:1815`), so none is wrong or
  redundant.

**Found on the walk, unchanged by main (not fixed here; for the round-4 reviewer)**
- F1: T8's `sceneMergePicker` / `sceneAbsorbPicker` identifiers exist on neither 58f2b10 nor
  dcaab0e. The sheets (`GridView.swift:1213-1222`) host `SceneMergePicker`
  (`SceneEditChrome.swift:14`), whose rows are `sceneMergeTarget-<id>` / `sceneAbsorbTarget-<id>`
  (`:53-54`). Stage B either adds one root identifier per kind, or T8 counts those rows.
- F2: U27 "sets … a `sceneEditError`", but it is `private(set)` (`GridStore.swift:1781`, also on
  58f2b10); `@testable` does not lift a private setter. Stage B reaches it through a failing edit
  (a stubbed 409 or busy answer) as the existing scene-edit tests do.

## 0r4. What changed since r3 (per finding)

| finding | r4 answer | where |
|---|---|---|
| B1 topology completion does not load its destination and can empty a newer scene | (a) candidates = `result.stackIds`. Each one is loaded through a new cache-bypassing `loadCandidateMembers(stackID:)`, which walks `service.stackMembers` to the completion cap and never writes `sceneMembers`. The destination is the first candidate whose members hold the anchor, else the first id (merge: the survivor; split: the part with the anchor). (b) ownership is re-checked after EVERY await (reload, ensure loop, each candidate load). The commit (`transitionScene(.retarget)` + installing the loaded members + cursor) is synchronous after the last check. (c) when ownership has moved, the scene entered NOW is left if dissolved; otherwise, if its members are empty and no fetch is in flight, it is revalidated (`revalidateEnteredScene`, §2.3). (d) tests assert `displayRows(for: .scene(id))` | §2.3a, §4 U13–U13g |
| B2 `.stream` dropped the Flat grid | `GridStore.displayRows(for: GridScope)`: `.stream` → `switch displayMode { .flat: images.map(.image); .scene: sceneDisplayRows }` (the existing branch at `GridView.swift:482-487`, moved unchanged); `.scene(id)` → `enteredSceneRows`. GridView calls it. U28 + UI T12 | §2.4, §4 |
| A T8 cannot show M46 | U27 `theTransitionClosesEveryGridPresentation`: all four flags plus `sceneEditError` set TRUE, then `leaveScene` → all false/nil. M46 makes it red. T8 keeps M24/M25 only | §4 |

## 0r3. What changed since r2 (per finding)

| finding | r3 answer | where |
|---|---|---|
| B1 scene overwrites the stream anchor | anchors are PER SCOPE. `gridScrollAnchor` becomes the stream's own slot, written only by a `.stream` instance. The scene has its own slot `sceneScrollAnchor`, cleared by every transition, so each scene opens at the top. A GridView instance's `scope` is now a CONSTANT (never "follow `activeScope`"), so a late report from an outgoing instance can only write its own slot. Entering or leaving never reads, consumes or writes the stream slot. Tests U18a (store) and T9 (scroll inside, Back, stream restored, probe + frame) | §2.4 W2, C3 |
| B2 topology completion undoes a newer Back | monotonic `sceneRevision`, bumped by every real `transitionScene`. `runSceneEdit` captures `SceneEditOwner(stackID: enteredSceneID, revision: sceneRevision)` BEFORE the POST. Retarget (or leave) only if `owner.stackID != nil`, `enteredSceneID == owner.stackID` and `sceneRevision == owner.revision` at completion. Data updates (reload, ensure rows, member completion, prune) apply regardless. A stream-initiated edit has `owner.stackID == nil`, so it never pushes (C5 by construction). Tests U13b-e | §2.3a |
| B3 card focus vs mark target | ONE store point `cardDidTakeFocus(_:)` sets `focusedImageID = nil`, called from ONE view bridge when a card gains real focus. The bridge also drops card focus when `focusedImageID` becomes non-nil. Cards are focusable only in browse, so while a card has focus `markTargetImageIDs == []` and P is a no-op. T3 now starts from a FOCUSED LOOSE PHOTO, moves real focus to the card, presses P, asserts the request log; positive control kept. M18 defined; it must fail on the request-log assertion after the `uiFocus=card-5000` precondition holds. U24 pins the store point | §2.6, §4 T3, U24 |
| A presentation setters | the setter writes only from the active instance; the transition closes store presentations. Pure `PresentationGate`, U25; handover in T8 | §2.4 W6 |
| A Compact retarget integration | NEW T11 (iPhone): split inside the scene, the displayed destination's scope equals the store entry, one Back reaches the stream | §4 T11 |
| A lookup failure state | the failure set is `sceneLoadFailed`, written by the member-fetch catch AND the revalidation stack-row catch; Retry reruns the revalidation | §2.3, §2.5 |
| A queued crossings vs "pruned while waiting is reported" | the transition-time removal and `PendingCrossing.gridScope` are CUT. A queued crossing whose photograph is not actionable in the new scope is dropped at drain by `capturePriorSnapshots` and REPORTED through `recordDroppedWrites`, which is exactly what GridStoreSceneTests:188 asserts (unchanged) | §2.4 |

**Cut in r3 (risk down, no AC lost)**: transition step 5 + `PendingCrossing.gridScope` (the
existing actionable fence already drops and reports); W3 pointer-drag `from:` (a covered instance
cannot be hit, Compact has no pointer, Regular has one instance); `GridView(scope: nil)` "follows
`activeScope`" (scope is always explicit); the `-UITestFocusSceneCard` launch `defaultFocus`
(replaced by a DEBUG focus button so T3 can focus a photo first); W2's `activeScope` refusal
(replaced by per-scope slots).

## 0. What changed in r2 since r1 (per finding; superseded where §0r3 says so)

| finding | r2 answer | where |
|---|---|---|
| B1 P on a focused card | the card gets REAL SwiftUI focus (`.focusable` + `@FocusState`, read back through a probe). P goes through the real key path. The assertion runs on an append-only request log. Positive controls on a loose photo and on member 601. Card BODY tap tests, plain and latched | §2.6, §4 T3-T6 |
| B2 second mutable membership | `sceneExpanded` becomes a COMPUTED read of `sceneEntry`. ONE writer, `transitionScene(_:)`, with a grep gate that allows one assignment | §2.1, §9 |
| B3 reload + nav sync rules | the store is the only truth. The Compact path is a PURE projection of it, and the binding setter is read only for user pops. There is an explicit table of which reload clears or keeps the scene. Reconciliation tests for each event | §2.2, §2.3, §4 R1-R11 |
| B4 inactive-grid writes | every shared writer is named (W1-W8). The racing writes carry their instance's scope, and the store refuses them from an inactive scope. Presentations and probes are rendered only by the active instance. Rules for pending work on a handover. A Compact two-instance UI test | §2.4, §4 T8 |
| B5 absence ≠ gone | the scene is left only on authoritative evidence: an HTTP 404 on the stack-row or member read, or an empty membership. Absence from page 1 triggers a stack-row reread and a splice of the card. Regression test for a scene beyond page 1 | §2.3, §4 U14-U17 |
| A C2/C3 | C2: an effective query change leaves the scene. C3: Back restores the stream position frozen at push, the same rule in both layouts, with a test | §2.3, §2.4, §7 |
| A request log | DEBUG `markRequests` is append-only and independent of fixture state. Fixture marks are derived from seeded per-image state plus real transitions | §2.7 |
| A loading/failure/retry | `SceneScreenState` defines loading, failed and loaded states, with Retry and Back behaviour for each | §2.5 |
| A test mapping | one row per rewritten test: old assertion → new assertion | §5 |
| A conformances | `GridScope: Hashable, Sendable` | §2.4 |
| A long folder title | a long title is covered on both layouts | §2.5, §4 T7 |
| C1 | kept: `chromeFill(.thinMaterial, in: Capsule())`, never `.glassEffect` | §2.5 |

## 1. Requirements, quoted

- Plan § Phase 12 (`r3-plan-phases.md:32-36`): "`WorkspaceRoute` gains `.scene(stackID)` and
  `.group(key, value)`; card tap pushes "Scene · N photos", Back names the folder, Filter/Arrange/latch
  carried and restored; loupe filmstrip = the scene; long-press keeps merge/split/extract; ⧉N glass
  pill, ✓N/✎N moved to the bottom edge (R3-8); the in-place swap (`SceneRows.swift:144-151`) removed."
  Do NOT: "make a card a mark target (ADR-0005)". Pivot: "Regular split-view navigation state → drive
  grid state instead of the stack".
- AC: "UI test: push, mark a member, Back, the card's ✓ count increments; latch engaged before push
  is still engaged after Back; P on a focused card produces no mark request (request log
  assertion); gate exit 0."
- R3-8 (`r3-design-4336.md:71-76`): "a glass pill "⧉ 12" = the count of what a tap opens; ✓N / ✎N move
  to the bottom edge. A scene card is never a mark target: it carries no image id".
- R3-20 (`r3-design-4336.md:154-160`): "a tap pushes the scene as its own grid ("Scene · 7 photos",
  Back names the folder); Filter, Arrange and the latch carry through; long-press keeps merge / split
  / extract; the loupe filmstrip is the scene. Group headers are enterable too." COST: "this is the
  WP34 Focus build; remaining gaps stay with WP34." Decision 6 (`r3-plan-4337.md:80`): ABSORB.
- Constraints: `.group(key, value)` for P13 with no Group-by UI; no re-vendor or contract edit;
  minimal, separated edits in the sibling files; swift-format strict, ≤100 columns.

IMGMGR-480 gaps: (1) membership = the per-scene `sceneMembers` pager (unfiltered, capture order,
tombstones). (2) n/a. (3) one transition clears the scene state (§2.1). (4) No relaunch restoration
(WP34). (5) n/a. ADR-0005 lives at BookStack /link/3275 and is cited through `SceneRows.swift:4-27`.

## 2. Design

### 2.1 One truth, one transition (B2)

- `GridStore` holds `private(set) var sceneEntry: SceneEntry?` with
  `struct SceneEntry: Equatable, Sendable { let stackID: Int }` (one field now; a struct so P13 can
  add `.group` without a second variable). `var enteredSceneID: Int? { sceneEntry?.stackID }`.
- `sceneExpanded` (`GridStore.swift:146`) becomes **computed**:
  `var sceneExpanded: Set<Int> { enteredSceneID.map { [$0] } ?? [] }`. Its four writers are deleted:
  `:1268` (clearSceneWindow), `:1376` (refresh), `:1610` and `:1622` (toggle). Every existing
  reader then derives from the entry automatically: edit subject `:1817-1821`, coordinator
  `:2051,:2076`, member paging fences `:1647,:1667`, inline-pick fences `:1702,:1715`, and filmstrip
  `:188`. So the edit subject cannot name a scene the display has left.
- **The only writer** is `private func transitionScene(to next: SceneEntry?, reason: SceneTransitionReason)`.
  `enum SceneTransitionReason { userOpen, userBack, scopeChanged, shootOpened, retarget, sceneGone, sessionEnded }`.
  It is a no-op when `next == sceneEntry`. Otherwise it runs these steps in this order,
  synchronously, before any await:
  1. `selection.reset(.sceneTransition)` (a new reason that maps to browse).
  2. `focusedImageID = nil`, then `closeLoupe()` if open.
  3. `conflictRecovery = nil`.
  4. `dragSession = DragPaintSession()`.
  5. `dismissGridPresentations()`: tag entry, status, merge picker, absorb picker and
     `sceneEditAlert` flags → false. They belong to the scope being left (§2.4 W6). (r3: the r2
     crossing removal that sat here is CUT, see §2.4.)
  6. `rows = []` and `sceneScrollAnchor = nil` (each scene opens at the top, §2.4 W2).
  7. `sceneEntry = next`, then `sceneRevision &+= 1` (r3, B2; `@ObservationIgnored
     private(set) var sceneRevision = 0`, read only by the topology owner check, §2.3a).
  It KEEPS `pickLock`, `undo`, Filter/Arrange (`query`), the STREAM anchor `gridScrollAnchor`
  (never read or written here) and the `sceneMembers` cache. For `.retarget` (topology result) it
  skips steps 1 and 2, because the coordinator restores focus by rule afterwards (`:2081-2084`).
- Public entry points route through it, and nothing else may assign `sceneEntry`:
  - `enterScene(_ id:) async`: guard `displayMode == .scene`. A card that is not in `sceneRows`
    is refused. Calls `transitionScene(to: .init(stackID: id), .userOpen)` and fetches page 1 if
    `sceneMembers[id] == nil` (single-flight `:1655`). It replaces `toggleSceneExpanded` (`:1606-1624`).
  - `leaveScene(_ reason: SceneTransitionReason = .userBack)` calls `transitionScene(to: nil, reason)`.
  - `openShoot(folderID:sourceTier:) async` (NEW, the row-tap path, §2.3) calls
    `leaveScene(.shootOpened)` and then `selectShoot`.
- `tapCell(.stack(id))` (`:2205-2206`) calls `enterScene(id)` in every mode, latched or not.
  It never marks (ADR-0005). `longPressCell(.stack)` (`:2215-2218`) stays a no-op.
- Enforcement: the §9 grep gate. `sceneEntry =` and `sceneRevision &+=` each appear exactly once
  in `Sources/` (both inside `transitionScene`), and `sceneExpanded` has no assignment or
  `insert`/`remove`.

### 2.2 Compact path = a pure projection of the store (B3)

The r1 two-way `ScenePushSync` modifier is **dropped**.
- `WorkspaceNavigation` (`Shell/WorkspaceNavigation.swift`) keeps storing BASE paths only
  (`[.workspace]` or `[]`). It never stores `.scene`. New pure functions:
  - `presentedPath(for tab:, entered: Int?) -> [WorkspaceRoute]` returns `path(for: tab)`, plus
    `[.scene(id)]` iff `tab == gridHost`, the base path is `[.workspace]` and `entered != nil`.
  - `applyStackWrite(_ newPath:, for tab:, entered: Int?) -> StackWriteEffect`
    (`struct StackWriteEffect: Equatable { var leavesScene: Bool; var popsHost: Bool }`). The cases:
    - `newPath == presentedPath` → no effect (an echo).
    - The presented path held `.scene` and `newPath` lacks it → `leavesScene = true`.
    - `newPath` is empty → `popsHost` (and `leavesScene` if a scene is entered).
    - The stored base path is always `newPath` with `.scene`/`.group` elements removed, through the
      existing `setPath` (`:34-41`).
    - A `.scene` that `newPath` carries while `entered == nil` is ignored, because the store wins.
- `CompactShell.path(for:)` (`CompactShell.swift:59-69`):
  - The getter is `navigation.presentedPath(for: tab, entered: enteredSceneID)`, where
    `enteredSceneID` is a new `let` that RootView passes from `gridStore.enteredSceneID`.
  - The setter calls `applyStackWrite`, then `onScenePopped()` (new closure →
    `gridStore.leaveScene(.userBack)`) if `leavesScene`, then the existing `onHostPopped()` if
    `popsHost`.
  - SwiftUI calls the setter only for user-initiated stack writes (Back tap, edge swipe, pop to
    root). Getter changes never call it. So a **programmatic rebuild is never read as a user Back**:
    - `showSelectedShoot` (`WorkspaceNavigation.swift:56-63`) only rewrites the BASE, and the projection re-adds `.scene`
      while the store is entered.
    - `applyLayoutChange` (`WorkspaceNavigation.swift:69-77`) behaves the same way.
- The rules that follow:
  - **Host replacement by a row tap**: RootView's `selectShoot` closure (`RootView.swift:677-682`)
    calls `store.openShoot`, which leaves the scene even for the same shoot. A row tap always lands
    on the folder's stream.
  - **Programmatic `showSelectedShoot`** (DEBUG auto-select `:361`, restore `:337,:898`,
    Regular→Compact `:547`) does not touch the store. It shows the entered scene if there is one.
  - **Regular→Compact**: the projection pushes the entered scene in Library.
  - **Compact→Regular**: there is no navigation write. Regular builds
    `GridView(scope: store.activeScope).id(store.activeScope)` from the store (§2.4) and shows
    `sceneBackButton`.
  - **Session end**: `navigation.endSession()` (`WorkspaceNavigation.swift:83-87`) clears the host, so the projection is
    empty. The erasure handler (`RootView.swift:167-176`) also calls
    `gridStore.leaveScene(.sessionEnded)` (one line, plus a weak capture). r4.1: the store is
    built by P9's `Self.makeGridStore(service:settings:)` straight into `_gridStore`
    (`RootView.swift:132`, factory `:651-653`), so the capture needs a local
    `let gridStore = Self.makeGridStore(...)` bound first, as `queueStore` and `navigation` are.
- Topology retarget: the route changes from `.scene(old)` to `.scene(new)` with no intermediate
  `[.workspace]`, so it is never a pop. SwiftUI replaces the top screen (see choice C8).

### 2.3 Which reload clears the scene and which keeps it (B3, B5, C2)

| site | scene rule |
|---|---|
| `selectShoot`, a different folder or tier (`GridStore.swift:756-784`) | `leaveScene(.scopeChanged)` beside the resets at `:767-782`, before `await reloadFirstPage()`. r4.1: those resets now hold IMGMGR-548's `pickLock.exit()` then the optional `forceLatch(.pick)` (`:769-773`); the transition never touches the latch, so where `leaveScene` sits among them changes nothing |
| `selectShoot`, the same folder and tier → `authoritativeRefresh` (`:757-766`) | **KEEP**, then revalidate (below) |
| `openShoot` (a row tap from any shell) | leave (`.shootOpened`), then `selectShoot` |
| `applyFilterChange`, after its `guard next != query` (`:790`) | leave (`.scopeChanged`). Every Filter and Arrange QUERY path ends here: facets `:1165-1175`, sort key/direction/toggle `:907-921` through `applyFlatPresentation`, and Filter popover rows. A sort that only changes the suspended presentation (Scene mode, `:916-921`) does not change `query`, so it keeps the scene |
| thumbnail size (`rowHeight`) and other non-query Arrange settings | KEEP. They apply inside and carry |
| `setDisplayMode` (`:836-859`) | leave (`.scopeChanged`). The existing `pickLock.exit()` there is unchanged |
| `fullReload` (`:1178-1182`, foreground and notice Retry), the cursor-invalid fallbacks `:1513,:1565` | KEEP, then revalidate |
| `performAuthoritativeRefresh` → `refreshScenePage` (`:1336-1380`, foreground, 409 recovery, same-shoot re-entry) | KEEP, then revalidate |
| `reloadAfterTopologyEdit` (`:2047-2085`) | KEEP through the whole await chain (`reloadFirstPage(revalidatesEntry: false)`). r4: the destination's members are loaded BEFORE an owned retarget, ownership is re-checked after every await, and a scene entered by a newer transition is restored (§2.3a) |
| session end | leave (`.sessionEnded`) |

- `clearSceneWindow` (`:1265-1274`) no longer touches the entry, since that is computed. It still
  drops the members cache, so the screen shows its loading state (§2.5) while a KEEP reload runs.
- **Revalidation** (B5), `revalidateEnteredScene(generation:)`. It is called at the end of
  `reloadFirstPage`'s scene branch (one site covers fullReload and the fallbacks), and from
  `refreshScenePage` in place of the `survivingScenes` filter (`:1342-1347`). Let `id` be the
  entered scene:
  1. The page holds `id` → refetch members page 1. An `items == []` with no cursor → `.sceneGone`.
  2. The page lacks `id` → `service.stackRow(stackID: id, query:)`:
     - `.ok` → splice the row at `SceneEditPlanner.insertionIndex(for:in:)` (the precedent is the
       coordinator's ensure-loop `:2065-2071`) and refetch members. The scene STAYS.
     - `GridServiceError.notFound` → `.sceneGone`.
     - Any other error → no leave, and `sceneLoadFailed.insert(id)` (r3: the SAME set the
       member-fetch catch writes, so `SceneScreenState` sees a lookup failure exactly like a
       member failure). `refreshScenePage` keeps its contract "a failure anywhere leaves the
       window untouched" and returns false (the members cache is untouched there, so the screen
       stays `.loaded`). On the reload path the cache was dropped by `clearSceneWindow`, so the
       screen shows `.failed` with Retry (§2.5). Every attempt (revalidation or member fetch)
       first removes `id` from the set.
  3. Fences after every await: `generation == loadGeneration` AND `enteredSceneID == id`. A Back or
     a different enter during the awaits wins (the IMGMGR-481 rule, `:1360-1375`, collapses to this
     one check).
- `GridService.stackRow` (`GridService.swift:238-250`) and `stackMembers` (`:208-227`) map an
  undocumented **404 → `GridServiceError.notFound`** (a new case). This is not a contract edit: the
  contract declares only 200 and 422 for both paths, and the mapping lives in our wrapper. Their
  existing `try?` callers (`GridStore.swift:1710,:1759,:2067`) are unaffected. `fetchSceneMembers`' catch
  (`GridStore.swift:1677-1680`) routes `.notFound` on the entered scene to `.sceneGone` and does not set
  `lastPageLoadError`.

### 2.3a Topology completion: who may navigate, and what it loads (r3 B2, r4 B1)

- `struct SceneEditOwner: Equatable, Sendable { let stackID: Int?; let revision: Int }`.
  `runSceneEdit` (`GridStore.swift:1968`) captures
  `let owner = SceneEditOwner(stackID: enteredSceneID, revision: sceneRevision)` as its FIRST
  statement after the in-flight guard, before `performSceneEdit`'s POST, and passes it to
  `reloadAfterTopologyEdit(_:request:owner:)`.
- `func ownsNavigation(_ owner: SceneEditOwner) -> Bool` (r4: a private helper, evaluated
  after EVERY await of the coordinator, never once at the end) =
  `owner.stackID != nil && enteredSceneID == owner.stackID && sceneRevision == owner.revision`.
  Any Back, swipe-back, row tap (`openShoot`), Filter/Arrange/mode change, session end, or a leave
  plus re-enter of the SAME stack bumps `sceneRevision` through `transitionScene`, so the captured
  revision no longer matches.
- **Why r3 was wrong** (gate r3 B1): `reloadFirstPage` → `clearSceneWindow` (`:1265-1274`) drops
  every `sceneMembers` entry, and `fetchSceneMembers` (`:1654-1681`) splices only into a scene that
  is entered (`:1667`). So "the result stack whose members hold the anchor" read an EMPTY cache,
  a merge retarget to survivor 6 had no members and no fetch, and a scene entered during the
  hold was left with no members.
- **The coordinator, in this order (r4)** (`reloadAfterTopologyEdit(_:request:owner:)`,
  replacing `:2047-2085`). `G` = `loadGeneration` after step 1. Every `guard G == loadGeneration
  else { return }` is the existing "a different folder wins" rule:
  1. `await reloadFirstPage(revalidatesEntry: false)`. Then `G`.
  2. The ensure loop `:2065-2071` for each `result.stackIds` missing from `sceneRows` (data,
     unchanged, with its generation guard after each await).
  3. If `!ownsNavigation(owner)` → step 6.
  4. **Destination, owned only.** `result.stackIds` empty → skip to step 5 with `target = nil`.
     Otherwise, for each `id` in `result.stackIds` in order:
     `let loaded = await loadCandidateMembers(stackID: id)`; `guard G == loadGeneration`;
     `guard ownsNavigation(owner) else` → step 6. Keep `loaded` in a local
     `[Int: CandidateMembers]` (successful loads only) and every nil result in a local
     `failed: Set<Int>`. Stop at the first `id` whose `loaded.items` contain
     `request.anchorImageID`. r5 (gate r4 B1), the destination is then ESTABLISHED or UNRESOLVED:
     - Established: (a) a loaded candidate holds the anchor → `target` = that id (a failed read
       of ANOTHER candidate does not matter); (b) `result.stackIds.count == 1` → `target` = that
       id (nothing to choose; a failed load is step 5's `.failed` on the known target, as in r4);
       (c) `failed` is empty and no loaded candidate holds the anchor → `target =
       result.stackIds[0]`. (c) is the ONLY use of the first-id fallback.
     - Unresolved: `failed` is non-empty and no loaded candidate holds the anchor (the anchor may
       sit in a part that was not read) → step 4b, never step 5.
     - Merge 5 → [6]: one load, `target = 6` (the survivor), with its members in hand.
     - Split 5 → [5, 9] with the anchor in 9: loads 5 (no anchor), then 9 (anchor), `target = 9`.
     - Split 5 → [5, 9], anchor in 9, 5 loads and 9 FAILS: unresolved (step 4b), never 5.
     - `loadCandidateMembers(stackID:) async -> CandidateMembers?` (NEW, private): walks
       `service.stackMembers(stackID:cursor:limit: sceneMemberPageLimit)` from `cursor: nil` for
       at most 1 + `sceneMemberCompletionPageCap` pages (so the r3 coordinator's step 3, "complete
       the edited scene", is kept). It returns `CandidateMembers(items:, cursor:
       SceneMemberCursor)`, or nil on any error. It NEVER writes `sceneMembers`,
       `sceneMemberCursors` or `sceneMembersInFlight`, so it cannot race the single-flight
       pager. `struct CandidateMembers: Sendable` sits in `SceneScreen.swift`.
  4b. **Unresolved, owned only, synchronous** (r5): no `transitionScene` (the entry stays
     `owner.stackID`, `sceneRevision` unchanged) and no install, so the entered id keeps the
     empty members cache the reload left. Set `sceneDestinationRetry = SceneDestinationRetry(owner:
     owner, candidates: result.stackIds, anchorImageID: request.anchorImageID)` (NEW
     `private(set) var sceneDestinationRetry: SceneDestinationRetry?`; the `Sendable` struct sits
     in `SceneScreen.swift`) and `sceneLoadFailed.insert(owner.stackID)`: `SceneScreenState` is
     `.failed` with Retry (§2.5), never another part's members. No focus restore; then
     `pruneSelectionOutside(actionableImages)`. Done.
     - Retry: `retryEnteredScene()` checks `sceneDestinationRetry` FIRST. When it is set and
       `ownsNavigation(retry.owner)`, it removes the entered id from `sceneLoadFailed` and re-runs
       steps 4 to 5 (or 4b again) over `retry.candidates` with fresh `loadCandidateMembers` reads
       and the same per-await ownership checks; otherwise it is r4's `revalidateEnteredScene`.
     - While `sceneDestinationRetry` names the entered scene, `revalidateEnteredScene` (a KEEP
       reload) defers to that same resolution instead of reading the old part's members, so a
       foreground refresh cannot install part 5 either.
     - Every real `transitionScene` clears `sceneDestinationRetry` (beside §2.1 step 7), so a
       Back, an enter or a scope change drops it, and a Retry after one is r4's revalidation.
     - r6 (gate r5): every owned commit in step 5 also clears it, including a same-id no-op
       retarget, so a resolution that lands on the entered id leaves no record behind.
  5. **Commit, owned only, synchronous** (no await between the last check and here):
     - First (r6, gate r5): `sceneDestinationRetry = nil`, whatever the branch below (leave,
       retarget, or a same-id no-op). A later revalidation of the entered id is r4's ordinary
       `revalidateEnteredScene`.
     - `target == nil` → `leaveScene(.sceneGone)`.
     - else `transitionScene(to: .init(stackID: target), .retarget)` (a no-op if it equals the
       entry), then install `sceneMembers[target] = loaded[target].items` and
       `sceneMemberCursors[target] = loaded[target].cursor`. If `target` has no successful load,
       `sceneLoadFailed.insert(target)`: the screen shows `.failed` with Retry (§2.5), never an
       empty grid.
     - Focus restore (`SceneEditPlanner.restoredFocus`, `:2081-2084`) now reads the installed
       members. Then `pruneSelectionOutside(actionableImages)`. Done.
  6. **Not owned: restore what is entered NOW.** `let now = enteredSceneID`.
     - `now == nil` → nothing to restore (the stream rows come from step 1).
     - `now ∈ result.dissolvedStackIds` → `leaveScene(.sceneGone)` (B5: server evidence).
     - else, if `sceneMembers[now] == nil` and `now ∉ sceneMembersInFlight` →
       `await revalidateEnteredScene(generation: G)` (§2.3). It refetches page 1, or looks up the
       row when page 1 lacks it, behind its own `enteredSceneID == now` fence. It never navigates
       except `.sceneGone` on authoritative evidence. Its failure path sets `sceneLoadFailed`.
     - `pruneSelectionOutside(actionableImages)`. No focus restore: the newer transition already
       reset focus, and it is not overwritten.
- The dissolved rule runs ONLY in step 6. In the owned path, the entered scene (5 in a merge)
  is the dissolved one by design, and step 5 has already moved to the survivor. Running the rule
  before step 5 would leave the scene instead of following the merge.
- **C5 by construction**: an absorb (or any edit) started from the stream has
  `owner.stackID == nil`, so it never pushes; the card's counts update through the data path.
- The existing `scenesToReopen(previouslyExpanded:)` call (`:2050-2051`) and the reopen loop
  (`:2072-2074`) are deleted; `target` replaces them.

### 2.4 Grid instances and shared writers (B4, C3)

- `enum GridScope: Hashable, Sendable { case stream; case scene(Int) }`.
  `GridStore.activeScope: GridScope` is `enteredSceneID.map(GridScope.scene) ?? .stream`.
- `GridView(scope: GridScope)` (r3: REQUIRED and CONSTANT for the instance's lifetime; the r2
  optional "nil follows `activeScope`" is cut). `isActive` is `scope == store.activeScope`.
  - Compact: `.stream` for the `.workspace` route, `.scene(id)` for `.scene(id)`.
  - Regular: `GridView(scope: store.activeScope).id(store.activeScope)`, so enter and leave build a
    fresh instance (and a fresh ScrollView and one-shot), exactly as a Compact push already does.
  - `displayRows` (`GridView.swift:482-487`) switches on the INSTANCE scope. r4 (gate r3 B2):
    it becomes `store.displayRows(for: scope)`, a NEW `GridStore` function that is the ONE
    definition of "what an instance renders":
    ```swift
    func displayRows(for scope: GridScope) -> [SceneDisplayRow] {
      switch scope {
      case .stream:
        switch displayMode {  // the existing branch, moved from GridView.swift:483-486 unchanged
        case .flat: return images.map(SceneDisplayRow.image)
        case .scene: return sceneDisplayRows
        }
      case .scene(let id):
        return SceneRowBuilder.enteredSceneRows(members: sceneMembers[id] ?? [])
      }
    }
    ```
    `.stream` is also the scope whenever no scene is entered, which includes all of Flat mode. So
    Flat keeps rendering `images`, the slice `actionableImages` reads in Flat (`GridStore.swift:137`
    "`images` stays EMPTY while Scene mode is on", `:198-203`). Scene mode renders cards plus loose
    photos. An instance only ever renders, frames and reports its own scope's display ids.
    `setDisplayMode` leaves the scene (§2.3), so a `.scene(id)` instance never exists in Flat mode.
- **Every shared writer, and its owner**:
  - W1 `store.rows`: `publishRows` (`GridView.swift:524-525`, triggered `:53-61,:100-107`) →
    `store.publishRows(_:from: scope)`. The store refuses it unless `from == activeScope`.
  - W2 scroll anchor (r3, B1): **one slot per scope**.
    - `gridScrollAnchor` (`GridStore.swift:992`) stays, and is now the STREAM slot only.
    - NEW `@ObservationIgnored var sceneScrollAnchor: GridDisplayID?`, cleared by every
      transition (§2.1 step 6), so every scene opens at the top.
    - `func scrollAnchor(for scope: GridScope) -> GridDisplayID?` and
      `func recordScrollAnchor(_ id: GridDisplayID, for scope: GridScope)`: `.stream` reads and
      writes `gridScrollAnchor`; `.scene(id)` reads and writes `sceneScrollAnchor`, and the write
      is dropped unless `enteredSceneID == id`.
    - GridView's three sites (`:234` restore, `:249` record, `:263` repack) call these with the
      instance's own constant `scope`. No call site passes `activeScope`.
    - So nothing inside a scene can write the stream slot, and entering or leaving neither reads
      nor consumes nor overwrites it. The existing stream resets `GridStore.swift:782,:804,:858` (folder, query,
      mode changes) are unchanged.
  - W3 pointer drag (r3: the r2 `from:` refusal is CUT). `tileFrames` is per-instance `@State`
    (`GridView.swift:20,:339`). A covered Compact instance cannot be hit, Compact (iPhone) has no pointer, and
    Regular has one instance. The transition resets the drag session; any stale crossing names a
    photograph of the old scope, which the actionable fence drops and reports (below).
  - W4 paging: `.task(id:) { page(from:) }` (`:308`, body `:469-477`) has a view-side
    `guard isActive`.
  - W5 inline-pick reads (`:402-404`) render only on cards, which the scene scope never renders.
  - W6 store-bound presentations:
    - `ActionBarView` sheets and alert (`GridView.swift:1197-1223`): tag entry, status, merge picker, absorb
      picker, `sceneEditAlert`. A new `presentsSheets: Bool` init parameter (= `isActive`), and each
      binding is built by the pure helper
      `PresentationGate.binding(_ flag: Binding<Bool>, active: Bool) -> Binding<Bool>`:
      get = `active && flag`; **set = writes `flag` only when `active`** (r3). An outgoing
      instance's dismissal write is dropped, so it can never clear the active instance's
      presentation.
    - The flags themselves are closed by the transition (§2.1 step 5), so a presentation never
      survives into the other scope and cannot reappear when the old instance is active again.
    - `WorkspaceContent .inspector(isPresented:)` (`WorkspaceContent.swift:99`) gets
      `.constant(false)` when inactive.
  - W7 `debugProbeElement` (`GridView.swift:138-200`) renders only when active, so its identifiers are never
    duplicated. r4.1: since P11a it also renders `debugProbe.gridChrome` (`:178-198`, IMGMGR-539),
    which the same gate covers; GridChromeWiringUITests never enters a scene, so it is unaffected.
  - W8 tap and long-press (`GridView.swift:304-307`): a covered instance cannot be hit, and Regular has one
    instance. No gate.
  - NOT per-instance (single, at RootView): `gridKeyboardActions` (`RootView.swift:505`),
    `SilentKeyCommandHost` (`:428,:478,:508`), loupe and Triage covers (`:412,:437`).
- **Pending work on a handover**:
  - A drag session is reset by the transition.
  - **Queued latched crossings (r3, advisory)**: the r2 transition-time removal and
    `PendingCrossing.gridScope` are CUT. The drain (`GridStore.swift:2336-2355`) is unchanged: its
    query fence (`:2344`) discards crossings from a LEFT QUERY silently (an enter or Back never
    changes `query`, so it does not fire), and `capturePriorSnapshots` resolves the batch against
    `actionableImages`, which after a transition is the NEW scope's photographs. A crossing queued
    on a stream photo and drained inside the scene (or on a member and drained after Back) is
    therefore NOT written and IS reported by `recordDroppedWrites` (`droppedWriteIDs` + the
    `.droppedWrites` notice). That is exactly GridStoreSceneTests:188's assertion, which stays
    as written (only toggle → E/L).
  - An in-flight member page for a left scene is dropped by the derived fence `GridStore.swift:1667`.
  - An in-flight stream page lands in `sceneRows`. That is stream data, published when the stream
    is active again.
  - `.onChange(of: store.activeScope) { publishRows() }` REPLACES `GridView.swift:55`, so the count stays the
    same (type-check budget, `:46-50`).
- **C3, one return rule for both layouts**: Back shows the stream at the stream slot's position.
  Only `.stream` instances write that slot (W2), so it holds the position at push.
  - Regular: leave builds a fresh `.stream` instance whose one-shot (`GridView.swift:226-250`) restores from
    `scrollAnchor(for: .stream)`.
  - Compact: the retained stream's `.onDisappear` (`:337`) re-armed the same one-shot at push, so
    it restores from the same slot on return. While covered it can only report its own rows.
  - The r1 `.stack(id)` anchor write and M6 are dropped.

### 2.5 The scene screen

- **The swap is removed**: `SceneRowBuilder.displayRows` (`SceneRows.swift:130-155`) always emits
  cards plus loose photos. The new `enteredSceneRows(members:)` returns `members.map(.image)`.
  `actionableImages` (`GridStore.swift:198-203`) = the ACTIVE scope's photographs: loose photos in
  the stream, the entered members inside. `.stack` keeps no image id (ADR-0005).
- **The filmstrip is the scene**: `openSceneMembers` (`:185-189`) reads the derived set, and the
  loupe is unchanged (`LoupeView.swift:902`).
- **Long-press**: a member inside the scene → Select → Scene ▸ merge/split/extract
  (`SelectBar.swift:123-170`). The subject comes from the derived set.
- **`SceneScreenState`** (pure, in `SceneScreen.swift`) is computed from (members[id], inFlight,
  failed):
  - `.loading`: no members yet and a fetch in flight. A centred `ProgressView`, id
    `sceneLoading`. It replaces the card-while-loading fallback `SceneRows.swift:129-133`. The
    "No photographs" overlay (`GridView.swift:108-113`) is suppressed.
  - `.failed`: no members, no fetch, and `id ∈ sceneLoadFailed` (new `private(set) Set<Int>`).
    r3: TWO writers, both catches: `fetchSceneMembers`' catch AND the revalidation stack-row
    lookup's non-404 catch (§2.3); every attempt first removes `id`. A
    `ContentUnavailableView("Couldn't load this scene")` with a `Retry` button, id `sceneRetry`
    → `retryEnteredScene()`, which reruns `revalidateEnteredScene` for the entered id (the
    stack-row lookup when the card is absent from `sceneRows`, then the single-flight members
    page 1). The page-load notice and its fullReload Retry still work, because fullReload keeps
    the scene and revalidates.
  - `.loaded`: the members.
  - An empty membership is never shown; it is `.sceneGone` (§2.3).
  - Back works in every state, and is never disabled. A late page after Back is dropped by the fence.
- **Card (R3-8)**, in `SceneCardView.swift:40-217`:
  - The pill "⧉ N" (`square.on.square`, `member_count`, id `sceneMemberCount`) sits top-leading,
    drawn as `chromeFill(.thinMaterial, in: Capsule())` (**C1 kept**; `.glassEffect` is forbidden
    by ADR-N1).
  - The ✓N/✎N cluster moves to bottom-leading, with its ids kept.
  - The open stroke and `openingIndicator` are removed. The hint reads "Double tap to open this
    scene".
  - `SceneExpandHandle` (`SceneChrome.swift`) keeps id `sceneHandle-<id>`, is labelled
    "Open scene", uses `chevron.right` and has no value.
  - Inline picks (Regular only) move to top-trailing.
  - The card gets `.focusable(interactions: .activate)` bound to GridView's `@FocusState focusedCard`
    (§2.6).
- **Titles and Back**:
  - The title is "Scene · 1 photo" or "Scene · N photos", from the card's `member_count` (falling
    back to the loaded count).
  - Compact: `.navigationTitle` on the `.scene` destination, plus `.navigationSubtitle(folderTitle)`.
    Back is the SYSTEM Back, so swipe-back is kept, and its label is the previous title, the folder.
    With a long title the system may shorten the label to "Back" or to the chevron alone. The
    subtitle still names the folder (§4 T7).
  - Regular: the principal breadcrumb shows the scene title. r4.1: since P11a the principal also
    draws `GridBreadcrumb.subtitle` (the FOLDER's counts, R3-11; `WorkspaceContent.swift:193-195`,
    `GridBreadcrumb.swift:46-66`). Inside a scene the breadcrumb is
    `GridBreadcrumb(title: <scene title>, subtitle: nil)`: the folder's "184 photos · 23 picks"
    under "Scene · 7 photos" would describe a screen that is not shown (§0r4.1, design
    consequence D1). A leading `ToolbarItem` `sceneBackButton`
    reads "‹ <folder>" with `lineLimit(1)` and `.truncationMode(.middle)`. Its accessibility label
    is the FULL folder title, and it calls `leaveScene(.userBack)`.
- **`.group(key: String, value: String)`**: a route case only, for P13. `presentedPath` never
  emits it, and the Compact destination renders the stream for it.

### 2.6 The focused-card condition (B1 r1, B3 r2)

There are three independent fences against a mark on a card, and the tests pin each one:
(a) a card never has an image id: `.stack` in `displayRows`, `markTargetImageIDs` `GridStore.swift:2555-2561`.
(b) `capturePriorSnapshots` resolves only against `actionableImages`, so a stray
`focusedImageID` = cover id writes nothing.
(c) (r3) **card focus and photo focus are mutually exclusive**, so while a card holds real
focus there is no mark target at all, and P is a no-op.

- **The real UI focus**: the card is `.focusable(store.selection.mode == .browse,
  interactions: .activate)` and bound through `.focused($focusedCard, equals: stackID)`
  (`@FocusState private var focusedCard: Int?` in GridView). A keyboard or FKA user reaches it
  with Tab. Scope added: the opening control has to be focusable, and it adds no mark path.
  Cards are NOT focusable in Select mode (entering Select drops any card focus), so the
  selection-mode target can never coexist with card focus.
- **The single defined point (r3)**: `GridStore.cardDidTakeFocus(_ stackID: Int)` sets
  `focusedImageID = nil` (and nothing else; it never touches selection, latch or loupe). It is
  the ONLY store entry for card focus, and it is called from ONE place: the view bridge below.
- **The bridge**: a small `ViewModifier` `SceneCardFocusBridge` (one modifier in GridView, so the
  `.onChange` count in the type-checked body grows by one modifier call, not two closures):
  - `.onChange(of: focusedCard)`: new value `id != nil` → `store.cardDidTakeFocus(id)`.
  - `.onChange(of: store.focusedImageID)`: new value non-nil → `focusedCard = nil` (an arrow, a
    tap on a photo, the loupe or a restore takes photo focus, and the card lets go).
  - No loop: each branch writes only on a non-nil new value of the OTHER source, and the write it
    makes is a nil.
- **Shortcut targeting while a card has focus**: browse mode (fence c) and
  `focusedImageID == nil` → `markTargetImageIDs == []` (`GridStore.swift:2555-2561`) → `handleMarkShortcut`'s
  existing empty-target guard returns before any request. P, X, U and Shift+P are no-ops.
- DEBUG (`-UITestStubGrid` only): a 1×1 button `debugFocusSceneCard`, rendered with the active
  stream instance's probe, assigns `focusedCard = <first card id>` through the real `@FocusState`
  (the r2 launch-time `defaultFocus` is cut, because T3 must first focus a photo). DEBUG probe
  `debugProbe.focus` reports `uiFocus=card-<id>|none;focusedImageID=<id>|none`. If the simulator
  cannot hold the card focus, T3's precondition fails loudly → STOP-and-report, never a weakened
  test.
- P travels the real path: `typeKey("p")` → AppCommands/`gridKeyboardActions` (`RootView.swift:505`,
  `GridKeyboardActions.swift:68`) → `handlePickShortcut` (`GridStore.swift:2407`).
- **M18 (defined)**: the bridge's card branch is removed (no `cardDidTakeFocus` call).
  M18s: `cardDidTakeFocus`'s body is emptied. Under either, after a loose photo was focused the
  card takes UI focus, `focusedImageID` still names the photo, and P sends `pick:<photo>`.

### 2.7 Request log and fixture state (advisory)

- `DebugProbe.markRequests: [String]` is APPEND-ONLY. One entry `"<state>:<ids,>"` per
  `SetMarkState` body (decoded the way `tagEditRecord` `:408-418` is), appended BEFORE the
  response and whether or not it changes state. It is exposed on `debugProbe.markRequests`.
  `markWrites` is left as is.
- Fixture marks: actor state `markState: [Int: MarkStateValue]`, seeded from
  `fixtureStackMemberImages()` (`DebugStubTransport.swift:445-462`). `SetMarkState` applies real
  transitions, so a repeated pick is a no-op, and answers `applied`/`revisions` for the changed ids
  only. `fixtureStackRow` (`:485-500`), the stack page and the member pages derive `pickedCount`
  and per-member marks from that state. The ✓ count therefore comes from both the stack reread and
  the member read, and T1 asserts that the two agree.
- Unit tests use the existing append-only `GridStubTransport.recordedWire` (`:631,:775`), filtered
  to `SetMarkStateApiMarksStatePost`. NEW `markStackGone(_:)` makes `GET /api/stacks/{id}` and
  `/members` answer 404.

## 3. Files to touch

| file | change |
|---|---|
| `Shell/WorkspaceNavigation.swift:5-7,27-77` | route `.scene(Int)`, `.group(key:value:)`; `presentedPath`, `applyStackWrite`, `StackWriteEffect` |
| `Shell/CompactShell.swift:15-23,48-69` | `enteredSceneID`, `onScenePopped`; destination `(WorkspaceRoute) -> Destination`; projected binding |
| `RootView.swift:167-176,677-682,790-795,1029-1039` | erasure `leaveScene`; closure → `openShoot`; CompactShell args; `contentColumn(scope:)` (Regular passes `store.activeScope` + `.id`) |
| `Grid/GridStore.swift` | §2.1 entry/transition + `sceneRevision` + `dismissGridPresentations`; computed `sceneExpanded` `:146`; `activeScope`; §2.3 sites; revalidate; §2.3a owner in `runSceneEdit` `:1968` and the coordinator `:2047-2085` rewritten as six steps (r4: `ownsNavigation(_:)`, `loadCandidateMembers(stackID:)`, not-owned restore); `displayRows(for:)` (r4, B2); W1 `from:`; W2 `sceneScrollAnchor` beside `:992` + `scrollAnchor(for:)`/`recordScrollAnchor(_:for:)`; `cardDidTakeFocus`; `tapCell` `:2205`; `retryEnteredScene`, `sceneLoadFailed`. (r3: `PendingCrossing` `:2286` and the drain are NOT touched) |
| `Grid/GridService.swift:208-250,777-790` | 404 → `.notFound` |
| `Grid/SceneRows.swift:89-200` | no swap; `enteredSceneRows`; drop `bandLeadMembers`; `.stack` loses `isExpanded` (C4) |
| `Grid/GridView.swift` | required constant `scope`, `isActive`; `displayRows` `:482-487` → `store.displayRows(for: scope)` (r4: the Flat/Scene branch moves into the store unchanged); W1, W2 (`:234,:249,:263`), W4, W6, W7 gates; `:55` swap; `@FocusState focusedCard` + `SceneCardFocusBridge`; scene states; drop `bandHandle` `:408-424` |
| `Grid/SceneCardView.swift`, `Grid/SceneChrome.swift` | §2.5 card |
| `Shell/WorkspaceContent.swift:41-105` | `scope`; titles/subtitle; `sceneBackButton`; inspector gate; r4.1: the scene breadcrumb with `subtitle: nil` fed to `GridBreadcrumbTitle` (`:178-214`) |
| NEW `Grid/SceneScreen.swift` | `GridScope`, `SceneEntry`, `SceneTransitionReason`, `SceneEditOwner`, `CandidateMembers` (r4), `SceneScreenState`, `SceneScreenTitle`, `SceneBackButton`, `PresentationGate`, `SceneCardFocusBridge` |
| `Grid/DebugStubTransport.swift`, `Grid/DebugProbe.swift`, `DebugStubLaunch` (DEBUG) | §2.7; `debugFocusSceneCard` button; probe `focus`, `scroll` (`streamAnchor=`), `scope` (`instance=…;entered=…`); `-UITestLongFolderTitle`; `-UITestSplitCreatesScene` (split of 5000 answers `stackIds [5000, 5001]`, and `/api/stacks/5001` + members serve the tail from the split point, for T11) |
| `Tests/ImgManagerTests/Support/GridStubTransport.swift` | `markStackGone` |

## 4. Tests (each red without the change)

A test that calls a new API cannot be red on main dcaab0e, because it would not compile (VOID). Each one
is proven red by a COMPILING mutant on the P12 code, and the build must succeed before a red counts.

**UI, NEW `Tests/ImgManagerUITests/ScenePushUITests.swift`** (`-UITestStubGrid -UITestEnterSceneMode`,
scene 5000, iPhone + iPad):

| id | test | red by |
|---|---|---|
| T1 | `testPushMarkBackIncrementsTheCardsPickCount`: Pick lock → tap the card BODY (centre, off the handle) → title "Scene · 41 photos" → tap `gridTile-601` → `markRequests == ["pick:601"]` → Back → card "… 3 picked"; the member read shows 601 picked | M5; on dcaab0e there is no push |
| T2 | `testLatchEngagedBeforePushIsEngagedAfterBack` | M4 (the transition calls `pickLock.exit()`) |
| T3 | `testPOnAFocusedCardSendsNoMarkRequest` (r3). Setup: → arrow → probe `focusedImageID=<L>` (a loose photo) and `uiFocus=none`; snapshot `markRequests`. Tap `debugFocusSceneCard` → **precondition: probe `uiFocus=card-5000`** (only this; `focusedImageID` is NOT part of the precondition). P → **primary: `markRequests` == the snapshot** (unchanged); secondary: probe `focusedImageID=none`. **Positive control**, same launch: → arrow → probe `uiFocus=none;focusedImageID=<L'>` → P → exactly one `pick:<L'>` appended; then push, tap 601, P → `pick:601` appended | **M18** (and M18s): precondition holds, the primary assertion goes red with `pick:<L>` appended. A run where the precondition fails is a STOP, never a caught mutant |
| T4 | `testCardBodyTapPushesTheScene` (handle untouched) | M19a: the body `onTapGesture` routes `.stack` nowhere |
| T5 | `testLatchedCardBodyTapPushesAndMarksNothing`: latch → body tap → pushed, `markRequests == []`, latch still engaged inside | M19: a latched `tapCell(.stack)` marks the representative |
| T6 | `testHandleTapPushesTheScene` (`sceneHandle-5000`) | M19b |
| T7 | `testBackNamesALongFolderTitle` (`-UITestLongFolderTitle`, 80 characters). Regular: `sceneBackButton` label == the full title and the button lies inside the nav bar's frame. Compact: Back is hittable and its label ∈ {full title, "Back", ""}, the subtitle == the full title, and a tap returns to the stream | M23: subtitle and label dropped |
| T8 | `testCompactSceneOwnsRowsPresentationsAndProbes` (iPhone, both instances alive): tap 601 → ↓ → `focusedImageID` = the member one row down (stream rows give `moveFocus` no up/down step, `GridStore.swift:2137-2146`). Open Select ▸ Scene ▸ Merge → exactly ONE `sceneMergePicker`, still presented after a 1 s settle (no inactive instance's write dismissed it); dismiss → back in the scene, probe `entered=5000`. **Handover (r3)**: open the picker again → system Back is covered, so Cancel → Back to the stream → the picker does NOT reappear, and opening the stream's own absorb picker shows exactly ONE `sceneAbsorbPicker`. `debugProbe` matches exactly 1 throughout | M24: drop the W1 refusal; M25: drop the W6 getter gate. r4: M46 is NOT claimed here: Cancel already cleared the flag before Back, so the handover cannot show it. M46's deterministic red is U27. The setter gate's deterministic red is U25 (M42) |
| T9 | `testBackReturnsToThePushedFromPosition` (r3, both destinations, deterministic). Scroll the stream (bounded loop, ≤6 swipes) until card 5000 is hittable AND probe `streamAnchor=<A>` with A ≠ the first photograph (precondition); record `gridTile-A` minY (or the card's). Push. Scroll INSIDE the scene (if the scene does not scroll at this width, step thumbnail size up first: non-query Arrange, stays inside) until probe `sceneAnchor` ≠ the first member (precondition). Probe `streamAnchor=<A>` (unchanged while inside). Back → probe `streamAnchor=<A>` and the recorded element's minY within one row height. Push again → probe `sceneAnchor=none` before any scroll (each scene opens at the top) | M27: one shared slot (scene records into the stream slot); M27b: the transition writes `gridScrollAnchor` |
| T10 | `testSwipeBackLeavesTheScene` (iPhone, an edge drag) → stream, and a following P writes nothing | M28: setter ignores `leavesScene` |
| T11 | `testSplitInsideTheSceneShowsTheRetargetedScene` (r3, iPhone, `-UITestSplitCreatesScene`): push 5000 → focus member 621 (in the tail) → Select ▸ Scene ▸ Split here → title "Scene · <tail count> photos" AND probe `instance=scene-5001;entered=5001` (the probe renders only from the ACTIVE instance, i.e. the displayed destination's constant scope equals the store entry; a stale destination renders no probe) → one system Back → the stream (card 5000 visible, probe `entered=none`), so the replace did not stack two screens | M43: the projection keeps the push-time id (route `.scene(5000)` while the store holds 5001 → no probe); M12 |
| T12 | `testFlatRendersPhotosAndSceneToFlatRestoresThem` (r4, B2, view-level, both destinations; `-UITestStubGrid` WITHOUT `-UITestEnterSceneMode`): `gridTile-<first flat id>` exists and no `sceneHandle-*` exists (Flat renders `images`). Then `gridArrangeControl` → `arrange.group.scene` → `arrangeDone` → `sceneHandle-5000` visible. Then `gridArrangeControl` → `arrange.group.none` → `arrangeDone` → `gridTile-<first flat id>` exists again and no `sceneHandle-*` | M54 (Flat shows an empty grid) |

**Unit, NEW `Tests/ImgManagerTests/Grid/ScenePushTests.swift`** (swift-testing):

| id | test | mutant |
|---|---|---|
| U1 | `enteringMakesOnlyItsMembersActionable` | M1 `actionableImages` returns the stream when entered |
| U2 | `aCardIsNeverActionableInsideOrOutside` + `pOnALeakedCoverFocusWritesNothing` (`focusedImageID` = cover id → P → no SetMarkState in `recordedWire`; control: a loose id → one request) | M2 the builder emits the representative as `.image` |
| U3 | `theActionableFenceRefusesAnUnlistedID` | M17 `capturePriorSnapshots` falls back to every loaded summary |
| U4 | `aCardTapEntersInEveryModeAndWritesNothing` (browse, latched Pick, latched Dislike, Select) | M19 |
| U5 | `theTransitionClearsSelectionFocusLoupeRecoveryKeepsLatchUndoQueryAnchor` | M3 keeps focus; M4; M29 resets the anchor |
| U6 | `aMarkInsideIsOnTheCardAfterBack` | M5 |
| U7 | `theEditSubjectFollowsTheEntry` (enter 5, leave → `sceneEditSubject == nil`; enter 6 → subject names 6) | M30 a stored `sceneExpanded` that leave forgets |
| U8 | `aFilterChangeInsideLeavesWithTheNewQueryAndKeepsTheLatch`, `aSortChangeInsideLeaves`, `aSuspendedSortChangeKeepsTheScene`, `aThumbnailSizeChangeStaysInside`, `switchingToFlatLeaves` | M7 no leave at the site / M31 leave on every sort |
| U9 | `enteringInFlatModeIsANoOp`, `enteringAnUnlistedStackIsRefused` | M8 |
| U10 | `aSecondEnterWhileLoadingAsksOnce`, `aLatePageAfterBackIsNotActionable` | M9 |
| U11 | `theFilmstripIsTheEnteredScene` | M10 |
| U12 | `theStreamNeverSwapsACardForItsMembers` | M11 restore the swap |
| U13 | r4, displayed membership asserted everywhere as `store.displayRows(for: .scene(id)).map(\.id)`. `mergeInsideFollowsTheSurvivor`: enter 5, merge into survivor 6, whose members span TWO pages → entered 6, displayed == all of 6's members (both pages), `GET /api/stacks/6/members` in `recordedWire`. `splitInsideRetargetsToTheAnchorsPart`: enter 5, split [5, 9] with the anchor in 9 → entered 9, displayed == 9's members, `focusedImageID` == the anchor. `aDissolvingEditLeaves` (empty `stackIds`). `theEntryIsNeverNilDuringATopologyReload` (read at a held `stackRow`/members call) | M12: the coordinator leaves then re-enters; **M49**: no candidate load, retarget only (the r3 behaviour) → displayed `[]` for 6; **M50**: the anchor is looked up in the cache, not in the loaded candidates → split stays on 5 |
| U13b | `aBackDuringAHeldTopologyEditIsNotUndone` (r3): enter 5, split held (`holdStackEditRequests`), L, release → `enteredSceneID == nil`, `focusedImageID` not restored; displayed: `displayRows(for: .stream)` holds cards 5 and 9 and no member of either | M40: retarget unconditionally (r2 behaviour) |
| U13c | `leavingAndReenteringDuringTheHoldIsNotRetargeted`: enter 5, split held, L, E 5, release (result [5, 9], anchor in 9) → entered stays 5; `sceneRevision` unchanged by the completion; r4: displayed `displayRows(for: .scene(5))` == 5's post-split members (non-empty; the reload had cleared them) | M39: the owner check compares the stack id only; **M51**: step 6 does not restore (displayed `[]`) |
| U13d | `aFolderRowTapDuringTheHoldLandsOnTheStream`: enter 5, split held, `openShoot` (same folder) → release → entered nil; displayed `displayRows(for: .stream)` == the reloaded stream rows | M40 |
| U13e | `anAbsorbFromTheStreamNeverPushes` (`owner.stackID == nil`) + `anEditWhoseEnteredSceneDissolvedLeaves` (re-entered 5 during the hold, result dissolves 5 → `.sceneGone`) + `anOwnedMergeIsNotLeftForItsOwnDissolvedScene` (r4: owned merge 5 → 6, `dissolvedStackIds == [5]` → entered 6, not left) | M41: retarget when `owner.stackID == nil`; M47: drop the dissolved check; **M53**: the dissolved rule runs before step 5 (owned merge leaves) |
| U13f | `enteringAnotherSceneDuringTheHoldKeepsItsMembers` (r4): enter 5, split held, L, E 7 (page 1 loaded), release → entered 7, displayed `displayRows(for: .scene(7))` == 7's members, no `GET /api/stacks/5/members` or `/9/members` after the release (not owned → no candidate load) | M51; M40 |
| U13g | `aBackDuringTheCandidateLoadWins` (r4): enter 5, merge into 6; `holdStackMembersRequests(true)` after 5's page 1 has loaded; release the edit → the coordinator waits on `GET /api/stacks/6/members`; L; `releaseStackMembers()` → entered nil, `sceneRevision` unchanged by the completion, displayed stream rows hold card 6. Variant: L then E 7 during the held load → entered 7 with 7's members | **M52**: ownership checked once, before the candidate loads only (retargets to 6 after the Back) |
| U13h | `aFailedCandidateReadNeverResolvesToTheFirstPart` (r5, gate r4 B1): enter 5, split 5 → [5, 9] with the anchor in 9; `GET /api/stacks/5/members` answers 200, `GET /api/stacks/9/members` fails (unreachable; NEW `GridStubTransport.failStackMembers(_:)`, beside `markStackGone`) → `enteredSceneID == 5` with `sceneRevision` unchanged by the completion (no retarget), `displayRows(for: .scene(5))` == `[]` (5's members NOT installed), `SceneScreenState == .failed`, `sceneLoadFailed == [5]`, `sceneDestinationRetry != nil`, `focusedImageID` not restored. Then 9 answers 200 and `retryEnteredScene()` → entered 9, displayed == 9's members, `focusedImageID` == the anchor, `sceneDestinationRetry == nil`. Control `everyCandidateLoadedWithoutTheAnchorFallsBackToTheFirst`: both parts 200, neither holds the anchor → entered 5 with 5's members (fallback (c)). Variant `aRetryThatResolvesToTheEnteredSceneDropsTheRecord` (r6, gate r5): split 5 → [5, 9], anchor in 5; 5 fails, 9 answers 200 without the anchor → 4b (`sceneDestinationRetry != nil`); 5 answers 200 and `retryEnteredScene()` → entered 5 (same id, `sceneRevision` unchanged), displayed == 5's members, `sceneDestinationRetry == nil`; then `markStackGone(5)` and a foreground KEEP revalidation → `GET /api/stacks/5` in the wire, no `GET /api/stacks/9/members`, the scene is left (`.sceneGone`) | **M55**: the first-id fallback also on a failed read (r4 text) → entered 5 with 5's members displayed, state `.loaded`: the primary assertions go red; **M56**: Retry ignores `sceneDestinationRetry` and revalidates 5 → after Retry 5's members are displayed, not 9's; **M57** (r6): the record is cleared only by a real `transitionScene` → the variant's `sceneDestinationRetry == nil` goes red and the revalidation reads `/9/members` |
| U14 | **`aSceneOpenedBeyondPageOneSurvivesARefresh`** (page 2 holds 30; enter 30; `authoritativeRefresh`; page 1 lacks 30; stackRow 200 → still entered, members refetched, card spliced, `GET /api/stacks/30` in the wire) | M20 leave when the page lacks the stack |
| U15 | `aSceneGoneOnTheServerIsLeft` (stackRow 404), `anEmptyMembershipLeaves` | M21 404 treated as unreachable |
| U16 | `aFailedLookupKeepsTheSceneAndTheWindow` (stackRow unreachable → refresh false, entry and rows untouched) | M22 leave on any error |
| U17 | `aForegroundFullReloadKeepsTheScene`, `aBackDuringRevalidationWins` | M32 the reload clears the entry / M33 no `enteredSceneID == id` fence |
| U18a | `aSceneScrollNeverWritesTheStreamAnchor` (r3): record A for `.stream`; E 5; record 601 for `.scene(5)`, record 999 for `.scene(6)` (dropped); `scrollAnchor(for: .stream) == A`; L → still A; E 5 → `scrollAnchor(for: .scene(5)) == nil` | M27 / M27b / M44: the transition leaves `sceneScrollAnchor` set |
| U18b | `rowsFromTheInactiveScopeAreRefused` (W1, both scopes called) | M24 |
| U19 | `aCrossingQueuedInTheStreamIsDroppedAndReportedInsideTheScene` (r3, mirror of GridStoreSceneTests:188): latch, crossing on loose 10 held, a second on loose 11 queued, E 5, release → ONE request for 10, `droppedWriteIDs == [11]`, `.droppedWrites(count: 1)` notice | M1; M45: the transition removes pending crossings silently (the cut r2 step 5) |
| U20 | `aFailedSceneLoadRetriesInPlace`, `sceneScreenStateCoversLoadingFailedLoaded` | M36 retry calls fullReload / state mapping off |
| U21 | `aRowTapLeavesTheSceneEvenForTheSameShoot` (`openShoot`) | M37 |
| U22 | `sceneScreenTitleCountsPhotos` | M13 |
| U23 | `notFoundIsMappedOnlyFor404` (GridService over `GridStubTransport`) | M38 |
| U24 | `cardFocusClearsThePhotoFocusAndPIsANoOp` (r3): focus loose 10, `cardDidTakeFocus(5)`, `handlePickShortcut` → no `SetMarkState` in `recordedWire`, `markTargetImageIDs == []`; control: focus 10 again → P → one request | M18s |
| U25 | `presentationGateDropsAnInactiveDismissal` (r3, pure): flag true; `binding(flag, active: false).wrappedValue = false` → flag still true; active → false is written; getter `active && flag` | M42: the setter writes when inactive |
| U26 | `aStackRowLookupFailureShowsFailedAndRetryReruns` (r3): enter 30 (beyond page 1), `fullReload` with stackRow unreachable → entered 30, `sceneLoadFailed == [30]`, `SceneScreenState == .failed`; `retryEnteredScene` with stackRow 200 → `GET /api/stacks/30` again, `.loaded` | M48: the lookup catch does not insert; M36 |
| U27 | `theTransitionClosesEveryGridPresentation` (r4, deterministic, gate r3 advisory): enter 5; set `isTagEntryPresented`, `isStatusPresented`, `isSceneMergePickerPresented`, `isSceneAbsorbPickerPresented` = true and a `sceneEditError` (precondition: all five read back TRUE / non-nil); `leaveScene()` → all four false and `sceneEditError == nil`. Same again for `enterScene(6)` from the stream | **M46**: drop `dismissGridPresentations` from the transition → the primary assertion is red (the precondition still holds) |
| U28 | `theStreamScopeRendersTheFlatGridInFlatMode` (r4, B2): Flat, page loaded → `displayRows(for: .stream)` == `images.map(.image)` (non-empty, no `.stack`); `setDisplayMode(.scene)` → cards + loose photos; `setDisplayMode(.flat)` → `images` again, equal to the first read | **M54**: `.stream` returns `sceneDisplayRows` unconditionally (the r3 text) → Flat reads `[]` |

**Reconciliation, `Tests/ImgManagerTests/Shell/WorkspaceNavigationTests.swift`** (pure, plus a store):
- R1 `systemBackFromTheSceneLeavesIt` ([W,S5] → write [W] → leaves, no host pop).
- R2 `anEdgeSwipeIsTheSameWrite` (the binding level; T10 covers the real gesture).
- R3 `popToRootLeavesAndUnhosts`.
- R4 `anEchoIsANoOp`.
- R5 `aStaleSceneWriteAfterTheStoreLeftIsIgnored`.
- R6 `programmaticHostReplacementIsNotABack` (`showSelectedShoot(in: .shoots)` while entered 5 →
  `presentedPath(.shoots) == [W,S5]`, `.library == []`, no effect produced).
- R7 `regularToCompactPresentsTheEnteredScene`.
- R8 `compactToRegularWritesNothing` (paths and entry unchanged).
- R9 `aTopologyRetargetIsNotAPop` (projection [W,S5] → [W,S9] with no [W] in between; the echo is
  a no-op).
- R10 `endSessionDropsTheScene`.
- R11 `groupRouteIsHashableAndNeverProjected`.
- Mutants: M14 (`showSelectedShoot` writes `.scene` into the base), M15 (`applyStackWrite`
  ignores the echo), M16 (the projection ignores `gridHost`).
- Layout transitions cannot be driven in XCUITest (there is no Compact↔Regular resize on the
  simulator), so R7 and R8 are their proof.

## 5. Existing tests: assertion mapping

Notation: E = `enterScene`, L = `leaveScene()`. The orchestrator's line numbers are where each
test starts.

| test (file:line) | old assertion → new assertion |
|---|---|
| GridStoreSceneTests:95 `sceneRowsAreKindDiscriminated` | drop `!isExpanded` (C4); kind checks kept |
| :128 `collapsedCardIsNotActionable` | `sceneExpanded.contains(5)` → `enteredSceneID == 5`; the 2nd tap → `L`, `== nil`; not-actionable checks kept both ways |
| :188 `aQueuedCrossingPrunedWhileItWaitedIsReported` | toggle/toggle → E/L; ALL assertions kept verbatim (one write for 10, `droppedWriteIDs == [501]`, the notice). r3: reported by the unchanged drain + actionable fence, no `gridScope` (§2.4) |
| :314 `leavingSceneModeRestoresFlatPaging…` | `sceneExpanded.isEmpty` → `enteredSceneID == nil` |
| :342 `expandingSplicesMembers…` → `enteringRendersMembersInCaptureOrder` | "in the card's place" → `enteredSceneRows` == members incl. tombstones AND the stream still holds the card |
| :385 `membershipPagesFurther` | "card never moves" → stream rows identical across member paging |
| :409 `membershipIsSingleFlight` | open/close/open → E/L/E; ONE members GET kept |
| :431 `collapsingPrunesTheSelection` → `leavingClearsTheSelection` | prune → empty (gap 3, stronger) |
| :455/:495 refresh prune/keep selection, :517 `markingAnExpandedMemberWorks`, :586 | toggle → E; assertions kept |
| :544 `coverRefreshMergesOnlyTheFourFields` | `sceneExpanded.contains(5)` → `enteredSceneID == 5` |
| :677/:685/:697/:705 builder tests | collapsed card alone (kept); expanded → `enteredSceneRows` actionable; unloaded → `SceneScreenState.loading` (no card fallback); id collision kept |
| SceneBandTests:101 | → U12 + `enteredSceneRows` == members |
| :137 `expandedButUnloadedSceneKeepsItsCard` | → stream keeps the card AND screen state `.loading` |
| :171/:202 pick count server/optimistic | toggle → E; counts kept |
| :257/:271 `bandLeadMembers` | deleted with the API; replaced by U12 (no band) |
| :327 handle label/value | label "Open scene", no value |
| :363/:388/:409 card sentences | drop `isExpanded:`; digit/clause/count assertions kept |
| SceneOpenDuringRefreshTests:53 | → `anEnterMadeMidRefreshSurvivesIt` (entered 6, refresh held, L+E 5 → after: 5 with its members) |
| :72 | → `aBackMadeMidRefreshSurvivesIt` (after: nil) |
| :87 `…DroppedIsNotResurrected` | split: 404 → left (U15); 200 → kept (U14). The old "absent ⇒ dropped" is retired on purpose (B5) |
| LoupeFilmstripTests:125, :291, :400, :460, :687 | toggle → E; strip == the entered scene kept |
| :588 flat whole sequence | unchanged inputs (derived set) |
| :605 | expanded → entered |
| :619 / :642 `aClosedScenesCachedMembersAreNotABand` | after L the cached members are no strip (kept; the fence is now derived) |
| ScenePicksInGroupsTests:159 | E → no summary read (fence `GridStore.swift:1702` derived) |
| :183 | toggle×4 → E, L, E, L; invalidation assertions kept |
| GridStoreSceneEditTests:133 | the 2nd toggle → L; subject nil after L (U7) |
| :192, :475, :614 | → E |
| :270 `splitOpensTheNewSceneAndFocusFollows` | `sceneExpanded == [5,9]` → `enteredSceneID == ` the part holding the anchor; focus kept |
| :309 merge | `== [6]` → entered 6 |
| :353 `onlyTheEditedSceneIsCompleted…` | r4 (re-read at :353-400): toggle×3 → E 6 only (focus 7 = subject 6); merge 6 into survivor 5 → entered 5, `sceneMembers[5] == [1, 2, 7, 8]` (both pages, now loaded by `loadCandidateMembers`) and focus 7, both KEPT verbatim; `sceneExpanded.contains(11)` → retired (one entry); "11 not completed" → no request for cursor `eleven-2` in the wire |
| :413 `aResultStackBeyondPageOneIsStillEnsured` | `contains(30)&&contains(31)` → entered ∈ {30,31} by anchor, and BOTH rows ensured in `sceneRows` r4: entered == the part whose LOADED members hold the anchor, and its members are displayed |
| :556 extraction | `== [5,9]` → entered = the anchor's part |
| :640 typed conflict | `== [5]` → entered 5 |
| GridStoreAbsorbTests:114 | → E |
| :274 | `== [6]` → C5: NO push; the photo is in card 6's count, focus cleared, `enteredSceneID == nil` (C5 intentional change) |
| :306 | ensure-fetch kept; `== [6]` → row 6 present in `sceneRows`, not entered |
| SceneSelectionAgreementTests:74 helper, :111, :320, :351 | E; `isSuperset([5,6])` → entered 6 + merge target 5 listed |
| SceneMarkScrollAnchorTests:80, GridStoreCompoundMarkTests:63, GridMoreMenuTests:576 | → E; assertions kept |
| HoverEffectInstallerTests:81 | drop `isExpanded:` |
| UI: SceneBandScreenshotUITests | badges/handle/band → pill/bottom cluster/push screenshots |
| UI: SceneMarkScrollPosition, LoupeFilmstripScope, SelectBarScene, SceneAbsorb | the handle tap now pushes; same tile ids; assertions kept inside the pushed screen |

FolderTreeSectionTests (`FolderTreePresentation.isExpanded`) is unrelated and untouched.

## 6. Risks / compile-risk spots

- (r4) Wire counts after a split rise. Every candidate up to the anchor's part is loaded to the
  completion cap, so a split with the anchor in the second part loads both parts. Only
  `result.stackIds` are ever loaded, so "only the edited scenes are completed" still holds.
  Existing assertions on the number of member requests are re-read in Stage B against this rule.
- (r4) `loadCandidateMembers` shares the stub's member pages with `fetchSceneMembers`. It writes
  no cache and no in-flight set, so a held candidate load (U13g) cannot block a user's enter.

1. GridView type-check budget: the `.onChange` count does not change (`GridView.swift:55` swapped); the two
   focus `.onChange`s live inside `SceneCardFocusBridge` (one modifier call in the body). The new
   gates are plain `if`/ternaries.
1b. Regular `.id(store.activeScope)` on the whole GridView resets `paneWidth` (`GridView.swift:19`) to 0 for
   the first layout of a fresh instance, the same as every Compact push and tab switch today.
   T9 (iPad) observes the restore after it, so a one-frame blank cannot hide a regression.
2. Swift 6:
   - `GridScope`, `SceneEntry`, `SceneEditOwner` and `StackWriteEffect` are Sendable value
     types. `sceneRevision` and `sceneScrollAnchor` are `@ObservationIgnored` main-actor state.
   - The CompactShell closures are `@MainActor` and non-`@Sendable`, like `onHostPopped`.
   - `navigationDestination` switches on the route inside a `@ViewBuilder`.
3. `.focusable(_:interactions:)` and a programmatic `@FocusState` write on iOS 26: if the probe
   shows no card focus on the simulator, T3's precondition fails → STOP and report (no fallback is
   invented).
4. SwiftUI replaces the screen on a topology retarget (C8). The outgoing instance draws empty for
   one animation.
5. Stub fixture state: existing UI tests that read ✓ without marking first are unchanged, because
   the seed equals today's static values.
6. A hardware `typeKey` on iPhone (precedent `SilentKeysUITests:49`). The IMGMGR-404 flake class →
   re-run, never weaken.
7. Sibling rebase: DONE in r4.1 (§0r4.1). P9 (RootView), P11a (GridView/GridStore/TileView/
   SceneCardView/GridBreadcrumb) and P11b (CompactShell lost the Search tab, the `search` model
   and the `SearchRoot` generic: it is `CompactShell<Shoots, Library, Destination>` at `:15`; our
   edit is at `:15-23,:48-69`) are in the base, and every anchor here is at dcaab0e.
7b. T11 adds one DEBUG stub branch (`-UITestSplitCreatesScene`); without the flag the split answer
   is today's (`stackIds [fixtureStackID]`), so SelectBarSceneUITests is unchanged.
8. 404 mapping: `GridServiceContractProbeTests` asserts no 404 for these two endpoints (grep:
   only proxy 404s at `:157,:462`).

## 7. Choices

| choice | decision |
|---|---|
| C1 | `chromeFill(.thinMaterial, in: Capsule())`. **Decided** |
| C2 | an effective query change pops to the stream with the new query; non-query Arrange stays inside. **Decided**, tests U8 |
| C3 | Back restores the stream position; per-scope anchor slots, the stream slot written only by `.stream` instances, each scene opens at the top. **Decided** (r3), tests T9/U18a |
| C4 | remove `isExpanded`. **Decided** |
| C5 | an absorb from the stream does not push: `owner.stackID == nil` never navigates (§2.3a). **Decided**, U13e + §5 |
| C6 | Esc/⌘[ as Back: not in P12 |
| C7 | relaunch restoration: not in P12 (WP34) |
| **C8 (new)** | a topology retarget inside the scene REPLACES the Compact screen (the route carries the current stack id, per the ticket). The alternative is a stable route id (the tapped stack) with the content read from the store: no replace animation, but the route id and the shown scene would differ after a split. **Default: replace** |

## 8. Planned pre-gate cases (Stage B ledger)

1. boundary: r4: a merge survivor whose members span two pages (U13), an empty `stackIds` (U13). A 1-member scene ("1 photo"), `enteredSceneRows` with an empty or 1-item page, a
   scene at the last row of page 2 (U14).
2. literal-in-string: the §9 greps must not count `sceneEntry =` / `sceneRevision &+=` inside
   comments or doc strings (anchored to code: `^\s*[^/]*`). Test with a planted comment. Also the
   probe parser: a folder title containing `;` or `=` (T7's long title) must not break the
   `key=value;` probe split — the title is never put in a probe string.
3. swallowed refusal: a `try?` on the revalidation stackRow would swallow 404 AND the failure
   state. Revalidation uses `do/catch` with an explicit `.notFound` branch (U15 red under M21) and
   a catch-all that inserts into `sceneLoadFailed` (U26 red under M48). The setter gate must not
   swallow an ACTIVE dismissal (U25 control).
4. scope label: the transition must not touch `pickLock`, `query`, `undo` or the STREAM anchor
   (U5, U18a). Workspace navigation for non-host tabs stays empty (R6). A scene-slot write for a
   scene that is not entered is dropped (U18a).
5. concurrency: a Back during revalidation (U17), an enter mid-refresh (§5 :53), a second enter
   while loading (U10), a crossing queued across a handover (U19), a Back / leave+re-enter / row
   tap during a held topology edit (U13b-d); r4: an enter of ANOTHER scene during the hold (U13f) and a Back during the held candidate load (U13g).

## 9. Gate greps (re-runnable, Stage B)

- `grep -nE '^\s*[^/]*\bsceneEntry = ' Sources/ImgManager -r` → exactly 1 line (in `transitionScene`).
- `grep -nE 'sceneExpanded(\s*=[^=]|\.insert|\.remove)' Sources/ImgManager -r` → 0 lines.
- `grep -rn 'glassEffect' Sources/ImgManager/Grid/SceneCardView.swift` → 0 lines.
- `grep -n 'toggleSceneExpanded' -r Sources Tests` → 0 lines.
- `grep -nE '^\s*[^/]*\bsceneRevision &\+= ' Sources/ImgManager -r` → exactly 1 line (r3).
- `grep -nE '^\s*[^/]*\bgridScrollAnchor = [^n]' Sources/ImgManager -r` → exactly 1 line, inside
  `recordScrollAnchor` (r3: GridView no longer assigns it; the `= nil` resets `GridStore.swift:782,:804,:858` are
  excluded by `[^n]`).
- `grep -nE '^\s*[^/]*\bcardDidTakeFocus\(' Sources/ImgManager -r` → exactly 2 lines (the
  definition and the bridge call) (r3).
- `grep -n 'gridScope' -r Sources/ImgManager` → 0 lines (r3: the cut stays cut).

## Stage B deviations

Recorded by the Stage B implementer (2026-10-19); each is forced by the code as it stands.

1. **U8 `aSuspendedSortChangeKeepsTheScene`.** No Scene-mode sort only changes a suspended
   presentation: every `setSortKey` in Scene mode goes through `applyFlatPresentation` to Flat
   (and so leaves). The test pins the same guard order with a query write that changes nothing
   (`applyFilterChange { _ in }` keeps the entry), which is what M31 breaks.
2. **U5.** `conflictRecovery` is `private(set)` and has no deterministic seed from a test; U5
   asserts it nil after the transition and covers selection, focus, loupe, latch, undo, query
   and the stream anchor as planned.
3. **U13h.** Step 4b leaves the focus alone, and `markTargetImageIDs` in browse is the focus id
   whether or not it is actionable, so the "no mark target" check is: nothing is actionable and
   a P reaches no server (`markRequests == 0`).
4. **U27.** `sceneEditError` is `private(set)`; it is set through a real failing edit (a 409 on
   extract inside the scene; a 409 on absorb from the stream).
5. **T9.** The scene scroll slot records its first visible member on arrival, so "each scene
   opens at the top" reads `sceneAnchor=<first member>` (3), not `none`. The stream is made
   scrollable with the non-query Arrange size 400 first (five rows on the fixture).
6. **T8.** The fixture has one scene, so the merge row is disabled there; T8 launches with
   `-UITestSplitCreatesScene`, splits at 621 first, then opens Merge inside 5001. "Exactly one
   picker" is counted on the `sceneMergeTarget-5000` / `sceneAbsorbTarget-5000` rows.
7. **T2/T5.** There is no Pick-latch launch hook; the latch is entered with the shipped
   `-UITestLatchDislikeLock` (same `lockFromMenu` path) and read from `lockModeCaption`. T1 marks
   with P on a focused member instead of a latched tap.
8. **T3.** When bare keys do not reach the app at all (the → produces no photo focus), the test
   throws `XCTSkip` with the probe value, as `CompareUITests` does; a failed card-focus
   precondition after that is still a failure.
9. **Retired / changed existing assertions** (§5): SceneSelectionAgreementTests R4-B1 drops its
   unguarded "mutant" half (a single entry makes the two-scene state unreachable);
   SceneOpenDuringRefreshTests `:87` is retired to U14/U15; GridStoreSceneEditTests beyond-page-one
   drops `sceneMembers[30]` (only the destination's members are installed); the absorb test C5
   asserts the stream-initiated absorb pushes nothing.
10. **Mutants named without a definition** (M5, M8, M9, M10, M13) are stated in the tests by
    their inferred mutation: M5 the card row is not re-read after a mark inside; M8 the
    Scene-mode / listed-card guards on enter; M9 the members single-flight and late-page fence;
    M10 the strip walks the stream; M13 the title counts or pluralises wrongly.
11. A failed first-page reload marks the entered scene failed, and the inline picks sit
    top-trailing on the card (layout only).
12. `SceneRows.swift` doc comment named `toggleSceneExpanded`; reworded to `leaveScene` so the
    §9 grep reads 0.
13. **Fixture hooks (T2/T5/T7).** `setDisplayMode` exits the latch, so the RootView fixture now
    applies `-UITestLatchDislikeLock` after `-UITestEnterSceneMode` (no other test passes both).
    The Compact shell names the shoot from the summary path's last component ("stub"), so
    `-UITestLongFolderTitle` lengthens that path as well as the tree node's name.
14. **R1–R11** are pure `WorkspaceNavigation` tests (no store): the store half of each event is
    covered by the U tests (leave on Back is `leaveScene`, a retarget is U13).
15. **T9 on iPad.** At size 400 the iPad stream (five rows) fits its viewport and cannot scroll,
    so the precondition "A ≠ the first photograph" is relaxed there to "A recorded and the card
    hittable"; A = 1 is still overwritten by M27 (scene scroll) and M27b (the transition).
16. **T3 on iPad.** Run 104801 read `uiFocus=none` after the `debugFocusSceneCard` tap (the
    precondition), then a later key reached the scene. The probe button is now `.focusable(false)`.
17. **T3 driver (orchestrator ruling 2026-10-19, one cycle).** Diagnosis without a new run:
    Regular shows ONE grid instance before the push (the probe, button and card share the
    active `.stream` instance's `@FocusState`), so (1) is excluded. In run 132312 the probe read
    `focusedImageID=none` right after the tap, so the card had taken focus (the bridge cleared
    the photo) and then lost it. The assignment ran in the button's own touch turn, and on iPad
    the focus engine resets on touch. That is (3), with (2) as the truthful alternative. Only the
    driver changed; the precondition and the primary assertion are verbatim. Regular now walks
    the system focus with Tab first (the FKA path, no touch). The DEBUG probe button defers its
    assignment 400 ms past the touch. The positive control's photo focus falls back to a tap on
    loose 1 when → is consumed by the engaged focus engine.
18. **T3 skipped on iPad (owner ruling 2026-10-20, IMGMGR-540 comment 12298).** The card is not
    reachable by keyboard focus on iPad (Tab never reaches it; the probe tap pushes the scene).
    P12 ships without that fix: T3 throws `XCTSkip("IMGMGR-574: …")` on the iPad idiom only and
    runs unchanged on iPhone. No other test is skipped or weakened. IMGMGR-574 re-enables it.
