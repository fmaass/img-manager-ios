import SwiftUI
import Testing

@testable import ImgManager

/// P3 fold item 1's three assertions, verbatim: the exact target inventory minus `C`; no
/// `C` anywhere; zero active shortcuts without a chrome surface. WP13 P4 (IMGMGR-215) adds the
/// reconciliation the file only ever CLAIMED in a comment before: `ShortcutCatalog` and
/// `AppCommands.declarations` are now checked against each other in BOTH directions.
@Suite("Shortcut catalog (P3 fold item 1; WP13 P4 view options)")
struct ShortcutCatalogTests {

  @Test("Catalog is exactly the target inventory, minus C")
  func exactTargetInventoryMinusC() {
    let expected: Set<ShortcutID> = [
      .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
      .openSpaceEnter,
      .pick, .dislike, .clear, .shiftAdvance,
      .tag, .undo, .help,
      // WP13 P4 (IMGMGR-215) — decision 9's ⌘ discovery half. `groupMode` joined them in the
      // diff-gate r1 fix round: the Group single-select pair was declared in the View menu with
      // no key equivalent and no catalog entry at all, which is the parity violation this file
      // exists to catch.
      .zoomStep, .sceneToggle, .groupMode,
      // WP13 P5b (IMGMGR-221 part 2): the Sort control and the View menu's Sort group ship in
      // the same commit these two activate in — the six offered keys as ⌥⌘1…⌥⌘6 and the
      // direction toggle as ⌥⌘R.
      .sortKey, .sortDirection,
      // WP13 P8 (IMGMGR-214): `A` was EXCLUDED from the target inventory until its own surface
      // existed — that surface (the account-sheet row) ships in the
      // same commit this entry does, which is the catalog's own rule, not an exception to it.
      .autoAdvance,
      // IMGMGR-495 (owner ruling, comment 10230): ⌘0, Fit ⟷ 100 % in the loupe and in Compare.
      .viewerZoomToggle,
    ]
    let actual = Set(ShortcutCatalog.entries.map(\.id))
    #expect(actual == expected)
    #expect(ShortcutCatalog.entries.count == 19)
  }

  @Test("No C anywhere in the catalog")
  func noCAnywhere() {
    for entry in ShortcutCatalog.entries {
      #expect(entry.id.rawValue.uppercased() != "C")
    }
    // A structural guarantee, not just a per-entry scan over the current data: no case
    // in the enum itself is named for the letter C or "compare" — ShortcutID's own case
    // list is the thing a future edit would have to touch to reintroduce it, and this
    // assertion covers that list directly, independent of what ShortcutCatalog.entries
    // happens to contain.
    let allRawValues = ShortcutID.allCases.map { $0.rawValue.uppercased() }
    #expect(!allRawValues.contains("C"))
    #expect(!allRawValues.contains("COMPARE"))
  }

  @Test("No entry is active without a chrome surface (isActive implies hasChromeSurface)")
  func noEntryActiveWithoutChromeSurface() {
    // Trivially true by construction (isActive IS hasChromeSurface) but asserted directly so
    // a future edit that decouples the two still has a test catching the drift.
    #expect(ShortcutCatalog.entries.allSatisfy { !$0.isActive || $0.hasChromeSurface })
  }

  @Test(
    "P4's OWN entries (owningPhase == .p4) are all active — scoped by owner, durable across later phases"
  )
  func p4OwnEntriesAreActive() {
    // Plan §Phase 4 fold item 3 + Amendment: "P4 activates: arrows, P, X, Shift+advance, T,
    // Z(Undo)." Scoped to `owningPhase == .p4` (rather than the raw global active set) so a
    // LATER phase activating its OWN entries — P5's `openSpaceEnter`/`clear` below — cannot
    // make this assertion stale; the original (pre-P5) single-set assertion did exactly that
    // and had to be split when P5 shipped.
    let p4Owned = ShortcutCatalog.entries.filter { $0.owningPhase == .p4 }
    let expectedP4Active: Set<ShortcutID> = [
      .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .openSpaceEnter,
      .pick, .dislike, .shiftAdvance, .tag, .undo,
    ]
    #expect(Set(p4Owned.map(\.id)) == expectedP4Active)
    #expect(p4Owned.allSatisfy { $0.isActive })
  }

  @Test(
    "WP8 P5: Space/Enter (open) and U (Clear) are now active — the loupe destination and its mark bar both ship"
  )
  func p5ActivatesOpenAndClear() {
    let open = ShortcutCatalog.entries.first { $0.id == .openSpaceEnter }
    #expect(open?.hasChromeSurface == true)
    #expect(open?.isActive == true)

    let clear = ShortcutCatalog.entries.first { $0.id == .clear }
    #expect(clear?.owningPhase == .p5)
    #expect(clear?.hasChromeSurface == true)
    #expect(clear?.isActive == true)
  }

  @Test("WP13 P4's OWN entries (zoom steps, Scene toggle) are active — their chrome ships here")
  func wp13P4OwnEntriesAreActive() {
    let owned = ShortcutCatalog.entries.filter { $0.owningPhase == .wp13p4 }
    #expect(Set(owned.map(\.id)) == [.zoomStep, .sceneToggle, .groupMode])
    #expect(owned.allSatisfy { $0.isActive })
  }

  @MainActor
  @Test(
    "`?` (help) is ACTIVE only because WP13 P4 ships its surface — the sheet plus its two declarations"
  )
  func helpIsActiveOnlyBecauseItsSurfaceExists() {
    let help = ShortcutCatalog.entries.first { $0.id == .help }
    #expect(help?.owningPhase == .p3)
    #expect(help?.hasChromeSurface == true)
    #expect(help?.isActive == true)

    // The surface, in the same commit: two declarations (`?` and ⌘/) that open it...
    let helpDeclarations = AppCommands.declarations.filter { $0.shortcut == .help }
    #expect(helpDeclarations.count == 2)
    #expect(helpDeclarations.allSatisfy { $0.key != nil })
    #expect(
      Set(helpDeclarations.compactMap { $0.key.map { String($0.character) } }) == ["?", "/"])

    // ...and a sheet that actually lists it. Take `ShortcutHelpSheet` away and this row goes
    // with it, which is what makes "active" mean "reachable" rather than "declared".
    #expect(ShortcutHelpModel.rows.contains { $0.id == ShortcutID.help.rawValue })

    // Nothing is left PLANNED after this phase: `help` was the last inactive entry.
    // Closure form, not `allSatisfy(\.isActive)`: inside `#expect` the macro re-emits the
    // predicate as a generic function value, and a key path passed to a `rethrows` call
    // there is treated as throwing ("call can throw, but it is not marked with 'try'").
    #expect(ShortcutCatalog.entries.allSatisfy { $0.isActive })
  }

  @MainActor
  @Test(
    "Every ACTIVE catalog entry has a key equivalent declared in AppCommands, and every declared key equivalent names an active entry"
  )
  func everyActiveEntryHasAKeyEquivalentDeclaredInAppCommands() {
    let active = Set(ShortcutCatalog.activeEntries.map(\.id))
    // EVERY declaration, with NO exclusion list (diff-gate r1 blocker 1: this line used to be
    // `.filter { $0.key != nil }`, which silently exempted the two unkeyed Group entries from
    // the parity rule they were violating — the filter made the test pass BECAUSE of the bug).
    let declared = Set(AppCommands.declarations.compactMap(\.shortcut))

    // BIDIRECTIONAL: an entry active in the catalog but bound nowhere, or bound in the menus
    // but not active in the catalog, fails this one assertion either way.
    #expect(declared == active)

    // Menu ids are the `ForEach` identity that renders them: unique, never index-derived
    // (IMGMGR-210).
    let ids = AppCommands.declarations.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @MainActor
  @Test(
    "EVERY menu declaration carries a key equivalent AND names a catalog entry — no unkeyed menu entry, no exclusion list"
  )
  func everyMenuDeclarationIsKeyedAndCatalogued() {
    // Design decision 9's parity rule, asserted directly rather than left implicit in the
    // reconciliation above: a menu entry with `key: nil` (as `Group: None` and `Group: Scene`
    // shipped) is an app action with no declared bare/⌘ equivalent, and a declaration with
    // `shortcut: nil` is a second, uncatalogued inventory. Both are failures here, by id, so
    // the message names the offender instead of just the count.
    let unkeyed = AppCommands.declarations.filter { $0.key == nil }.map(\.id)
    #expect(unkeyed.isEmpty, "menu declarations with no key equivalent: \(unkeyed)")
    let uncatalogued = AppCommands.declarations.filter { $0.shortcut == nil }.map(\.id)
    #expect(uncatalogued.isEmpty, "menu declarations naming no catalog entry: \(uncatalogued)")
    // POSITIVE CONTROL, same invocation (LSN-0033): the two 0-hit filters above prove absence
    // only if the same scan finds something known to be there.
    #expect(AppCommands.declarations.count >= 14)
  }

  @MainActor
  @Test("No two declarations bind the SAME key with the same modifiers — an in-app collision")
  func noTwoDeclarationsBindTheSameCombination() {
    // The Group pair's ⌃⌘1/⌃⌘2 sit one modifier above the zoom steps' ⌘1/⌘2, so "does anything
    // else already use it" has to be a test, not a reading of the file.
    func combinations(_ declarations: [MenuCommandDeclaration]) -> [String] {
      declarations.compactMap { declaration in
        declaration.key.map { "\($0.character)|\(declaration.modifiers.rawValue)" }
      }
    }
    func isCollisionFree(_ declarations: [MenuCommandDeclaration]) -> Bool {
      let swept = combinations(declarations)
      return Set(swept).count == swept.count
    }
    let bound = combinations(AppCommands.declarations)
    #expect(isCollisionFree(AppCommands.declarations))
    #expect(bound.count == AppCommands.declarations.count)

    // IMGMGR-495: ⌘0 is IN the swept set — the sweep above covers it rather than passing because
    // it was never declared — and it is bound exactly once.
    let commandZero = "0|\(EventModifiers.command.rawValue)"
    #expect(bound.filter { $0 == commandZero }.count == 1)

    // POSITIVE CONTROL, same invocation (LSN-0033): the same predicate says NO the moment a
    // second command claims ⌘0, so the pass above is a sweep that can fail, not a vacuous one.
    let rival = MenuCommandDeclaration(
      id: "test.rival.commandZero", shortcut: .zoomStep, title: "Rival", key: KeyEquivalent("0"),
      modifiers: [.command], run: { _ in })
    #expect(!isCollisionFree(AppCommands.declarations + [rival]))
  }

  @MainActor
  @Test("IMGMGR-495: ⌘0 is ONE row, uniquely titled — and ⌘1 stays the grid's first zoom step")
  func commandZeroIsOneUniquelyTitledRowAndCommandOneIsUnchanged() {
    let toggle = AppCommands.declarations.filter { $0.shortcut == .viewerZoomToggle }
    #expect(toggle.count == 1)
    let row = toggle.first
    #expect(row?.id == "view.viewerZoom.toggle")
    #expect(row?.key == KeyEquivalent("0"))
    #expect(row?.modifiers == EventModifiers.command)
    #expect(row?.title == "Zoom: Fit / 100%")
    #expect(ShortcutID.viewerZoomToggle.keyLabel == "⌘0")

    // No other declaration carries its title — a menu row the reader cannot tell apart from
    // another is a second command under one name.
    let titles = AppCommands.declarations.map(\.title)
    #expect(titles.filter { $0 == "Zoom: Fit / 100%" }.count == 1)

    // It sits in the View menu, the discovery surface (p3220 §3.1), beside the zoom steps.
    let viewMenuIDs = AppCommands.viewMenuGroups.flatMap(\.items).map(\.id)
    #expect(viewMenuIDs.contains("view.viewerZoom.toggle"))

    let entry = ShortcutCatalog.entries.first { $0.id == .viewerZoomToggle }
    #expect(entry?.owningPhase == .wp32p0)
    #expect(entry?.isActive == true)

    // The owner's other half: "⌘1 stays the grid's first zoom step; no second key."
    let commandOne = AppCommands.declarations.filter {
      $0.key == KeyEquivalent("1") && $0.modifiers == EventModifiers.command
    }
    let firstStep = GridRowHeight.allCases[0]
    #expect(commandOne.map(\.id) == ["view.zoom.\(Int(firstStep.rawValue))"])
    #expect(commandOne.first?.shortcut == .zoomStep)
  }

  @MainActor
  @Test(
    "No declaration binds a combination iPadOS itself reserves — with the predicate's own positive control"
  )
  func noDeclarationBindsASystemReservedCombination() {
    // Apple Support, "Keyboard shortcuts for iPad": ⌘Space (Search), ⌘Tab (app switcher),
    // ⌘H (Home), ⌘⌥D (Dock), ⌘⇧3 / ⌘⇧4 (screenshot), ⌃⌘Space (emoji). Plus ⌘G, which HIG
    // Keyboards warns about as the established "Find Next" — the reason Scene is ⌘⇧G.
    // This is what "verify no collision with iPadOS system defaults" looks like as a check
    // rather than a claim; ⌃⌘1/⌃⌘2 (the Group pair) appear in none of them.
    func isReserved(_ character: Character, _ modifiers: EventModifiers) -> Bool {
      // WP13 P8 (IMGMGR-214) adds ⌘A on the same footing as ⌘G: not an iPadOS-reserved
      // combination but an established system-wide convention (Select All, and this app has a
      // Select mode), which is why auto-advance takes ⌘⇧A instead.
      let reserved: [(Character, EventModifiers)] = [
        (" ", .command), ("\t", .command), ("h", .command), ("d", [.command, .option]),
        ("3", [.command, .shift]), ("4", [.command, .shift]), (" ", [.command, .control]),
        ("g", .command), ("a", .command),
      ]
      return reserved.contains { $0.0 == character && $0.1 == modifiers }
    }
    // POSITIVE + NEGATIVE control on the predicate itself, in the same invocation: a 0-hit
    // sweep below proves nothing unless the predicate can say yes.
    #expect(isReserved("h", .command))
    #expect(!isReserved("1", [.command, .control]))

    let offenders = AppCommands.declarations.filter { declaration in
      declaration.key.map { isReserved($0.character, declaration.modifiers) } ?? false
    }
    let offenderIDs = offenders.map(\.id)
    #expect(offenders.isEmpty, "declarations on system-reserved combinations: \(offenderIDs)")
  }

  @MainActor
  @Test("WP13 P5b's OWN entries (sort keys, sort direction) are active — their chrome ships here")
  func wp13P5bOwnEntriesAreActive() {
    let owned = ShortcutCatalog.entries.filter { $0.owningPhase == .wp13p5b }
    #expect(Set(owned.map(\.id)) == [.sortKey, .sortDirection])
    #expect(owned.allSatisfy { $0.isActive })
  }

  @MainActor
  @Test("Every offered sort key gets its OWN ⌥⌘ equivalent — the zip cannot silently drop one")
  func everyOfferedSortKeyHasItsOwnCommandEquivalent() {
    let sort = AppCommands.declarations.filter { $0.shortcut == .sortKey }
    #expect(sort.count == SortGroupOptions.sortKeys.count)
    #expect(sort.allSatisfy { $0.modifiers == EventModifiers([.command, .option]) })
    #expect(
      sort.compactMap { $0.key.map { String($0.character) } } == ["1", "2", "3", "4", "5", "6"])
    #expect(sort.map(\.title) == SortGroupOptions.sortKeys.map { "Sort: \($0.title)" })
    // The direction toggle is its own entry, one declaration, ⌥⌘R.
    let direction = AppCommands.declarations.filter { $0.shortcut == .sortDirection }
    #expect(direction.count == 1)
    #expect(direction.compactMap { $0.key.map { String($0.character) } } == ["r"])
    #expect(direction.map(\.modifiers) == [EventModifiers([.command, .option])])
  }

  @MainActor
  @Test("The View menu NAMES the sort keys and the direction toggle")
  func viewMenuNamesTheSortOptions() {
    // The rows the menu DRAWS (IMGMGR-463), not every binding.
    let titles = AppCommands.viewMenuGroups.flatMap(\.menuRows).map(\.title)
    for key in SortGroupOptions.sortKeys {
      #expect(titles.contains("Sort: \(key.title)"), "the View menu does not name \(key.title)")
    }
    #expect(titles.contains("Reverse Sort Direction"))
  }

  @MainActor
  @Test("The Group single-select pair is ⌃⌘1 / ⌃⌘2 — the zoom digits one modifier up")
  func groupPairIsControlCommandOneAndTwo() {
    let group = AppCommands.declarations.filter { $0.shortcut == .groupMode }
    #expect(group.count == 2)
    #expect(group.map(\.id) == ["view.group.none", "view.group.scene"])
    #expect(group.compactMap { $0.key.map { String($0.character) } } == ["1", "2"])
    #expect(group.allSatisfy { $0.modifiers == EventModifiers([.command, .control]) })
    #expect(ShortcutID.groupMode.keyLabel == "⌃⌘1 · ⌃⌘2")
  }

  @MainActor
  @Test("No declaration binds C — with a positive control proving P IS bound (LSN-0033)")
  func noEntryDeclaresC() {
    let bound = AppCommands.declarations.compactMap { $0.key.map { String($0.character) } }
    // `C` stays declared NOWHERE, never present-and-dead. Native Compare was cancelled by
    // Amendment 7, then revived by the owner on 2026-09-27 (p4128) and shipped in WP30 P3 as
    // the iPad loupe's 2-up, reached from its toolbar control only — p4128 §Keyboard reads
    // "shortcuts unchanged", so Compare ships WITHOUT a `C` key. `A` used to be asserted absent HERE for the same reason; WP13 P8
    // (IMGMGR-214) shipped its surface, so the assertion moved to
    // `aIsActiveAndDeclaredExactlyOnceInAppCommands` below rather than being deleted.
    #expect(!bound.contains { $0.lowercased() == "c" })
    #expect(!ShortcutID.allCases.contains { $0.rawValue.uppercased() == "C" })
    // POSITIVE CONTROL, same invocation: a 0-hit above proves the scan ran only if a term
    // known to be present is found by the same scan.
    #expect(bound.contains { $0.lowercased() == "p" })
  }

  @MainActor
  @Test("WP13 P8: A is ACTIVE, bound once bare and once as its ⌘⇧ twin — never plain ⌘A")
  func aIsActiveAndDeclaredExactlyOnceInAppCommands() {
    let entry = ShortcutCatalog.entries.first { $0.id == .autoAdvance }
    #expect(entry?.isActive == true)
    #expect(entry?.owningPhase == .wp13p8)

    let declared = AppCommands.declarations.filter { $0.shortcut == .autoAdvance }
    // Exactly one BARE `A` (the web's own key, decision 9's fast path) and exactly one ⌘ form
    // (its discovery twin) — never two bare declarations racing for the same press.
    let bare = declared.filter { $0.modifiers.isEmpty }
    #expect(bare.count == 1)
    #expect(bare.compactMap { $0.key.map { String($0.character) } } == ["a"])
    let discovery = declared.filter { !$0.modifiers.isEmpty }
    #expect(discovery.count == 1)
    #expect(discovery.map(\.modifiers) == [EventModifiers([.command, .shift])])
    #expect(discovery.compactMap { $0.key.map { String($0.character) } } == ["a"])
    #expect(declared.count == 2)

    // Plain ⌘A stays unbound for the same reason plain ⌘G does (see `sceneToggleIsShiftCommandG`
    // and the reserved-combination test): it is the established "Select All", and this app has a
    // Select mode of its own.
    let commandA = AppCommands.declarations.filter {
      $0.modifiers == EventModifiers.command && $0.key.map { String($0.character) } == "a"
    }
    #expect(commandA.isEmpty)

    // Both declarations belong to the View menu's group — the discovery surface p3220 §3.1
    // names — but since IMGMGR-463 (p4128 D10) only the ⌘⇧A form draws a ROW there; bare A is
    // its silent twin, still bound (above) and rendered by `SilentKeyCommandHost`.
    let viewMenuItems = AppCommands.viewMenuGroups.flatMap(\.items)
    let viewMenuIDs = Set(viewMenuItems.map(\.id))
    #expect(declared.allSatisfy { viewMenuIDs.contains($0.id) })
    let viewMenuRows = AppCommands.viewMenuGroups.flatMap(\.menuRows)
    #expect(viewMenuRows.filter { $0.shortcut == .autoAdvance }.map(\.id) == discovery.map(\.id))
    #expect(viewMenuRows.map(\.title).contains("Advance After Marking"))
    #expect(bare.allSatisfy { $0.presentation == .silent })

    // POSITIVE CONTROL, same invocation (LSN-0033): the 0-hit `commandA` filter proves absence
    // only if the same scan finds something known to be bound.
    #expect(AppCommands.declarations.contains { $0.shortcut == .pick })
  }

  @MainActor
  @Test("Every GridRowHeight step gets its own ⌘ equivalent — the zip cannot silently drop one")
  func everyZoomStepHasItsOwnCommandEquivalent() {
    let zoom = AppCommands.declarations.filter { $0.shortcut == .zoomStep }
    #expect(zoom.count == GridRowHeight.allCases.count)
    #expect(zoom.allSatisfy { $0.modifiers == EventModifiers.command })
    #expect(
      Set(zoom.compactMap { $0.key.map { String($0.character) } })
        == ["1", "2", "3", "4", "5", "6"])
    #expect(zoom.map(\.title) == GridRowHeight.allCases.map { "\(Int($0.rawValue)) pt" })
  }

  @MainActor
  @Test("Scene view is ⌘⇧G — never plain ⌘G, which conventionally means Find Next")
  func sceneToggleIsShiftCommandG() {
    let scene = AppCommands.declarations.filter { $0.shortcut == .sceneToggle }
    #expect(scene.count == 1)
    #expect(scene.compactMap { $0.key.map { String($0.character) } } == ["g"])
    #expect(scene.map(\.modifiers) == [EventModifiers([.command, .shift])])
    // Plain ⌘G stays unbound: HIG Keyboards warns against re-binding an established system
    // shortcut, and ⌘G conventionally means "Find Next".
    let commandG = AppCommands.declarations.filter {
      $0.modifiers == EventModifiers.command && $0.key.map { String($0.character) } == "g"
    }
    #expect(commandG.isEmpty)
  }

  @MainActor
  @Test("The View menu NAMES the view options the AC requires: Group, Scene, every zoom step, help")
  func viewMenuNamesGroupAndZoomAndHelp() {
    // The rows the menu DRAWS (IMGMGR-463), not every binding.
    let titles = AppCommands.viewMenuGroups.flatMap(\.menuRows).map(\.title)
    #expect(titles.contains("Group: None"))
    #expect(titles.contains("Group: Scene"))
    #expect(titles.contains("Toggle Scene View"))
    for step in GridRowHeight.allCases {
      #expect(titles.contains("\(Int(step.rawValue)) pt"))
    }
    #expect(titles.contains("Keyboard Shortcuts"))
  }

  @MainActor
  @Test("The bare web set survives WP13 P4 unchanged — no existing key is re-keyed or dropped")
  func bareWebSetIsUnchanged() {
    // D9 is "the web set verbatim as the fast path AND Command-equivalents for discovery",
    // both — so every pre-WP13 binding must still be exactly as it was, un-⌘-ed.
    let bare = AppCommands.gridMenuGroups.flatMap(\.items)
    #expect(bare.allSatisfy { !$0.modifiers.contains(.command) })
    let bareKeys = Set(bare.compactMap { $0.key.map { String($0.character) } })
    #expect(bareKeys.isSuperset(of: ["p", "x", "u", "t", "z"]))
    #expect(bare.filter { $0.modifiers == EventModifiers.shift }.count == 3)
  }
}
