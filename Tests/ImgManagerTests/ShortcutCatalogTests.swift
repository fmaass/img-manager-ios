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
    ]
    let actual = Set(ShortcutCatalog.entries.map(\.id))
    #expect(actual == expected)
    #expect(ShortcutCatalog.entries.count == 15)
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
    let combinations = AppCommands.declarations.compactMap { declaration in
      declaration.key.map { "\($0.character)|\(declaration.modifiers.rawValue)" }
    }
    #expect(Set(combinations).count == combinations.count)
    #expect(combinations.count == AppCommands.declarations.count)
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
      let reserved: [(Character, EventModifiers)] = [
        (" ", .command), ("\t", .command), ("h", .command), ("d", [.command, .option]),
        ("3", [.command, .shift]), ("4", [.command, .shift]), (" ", [.command, .control]),
        ("g", .command),
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
  @Test(
    "No declaration binds C, and none binds A yet — with a positive control proving P IS bound (LSN-0033)"
  )
  func noEntryDeclaresCAndNoEntryDeclaresAYet() {
    let bound = AppCommands.declarations.compactMap { $0.key.map { String($0.character) } }
    // `C` (compare) is cancelled outright (Amendment 7); `A` (auto-advance) is WP13 P8's and
    // must not exist present-and-dead before its own surface does.
    #expect(!bound.contains { $0.lowercased() == "c" })
    #expect(!bound.contains { $0.lowercased() == "a" })
    #expect(!ShortcutID.allCases.contains { $0.rawValue.uppercased() == "A" })
    // POSITIVE CONTROL, same invocation: a 0-hit above proves the scan ran only if a term
    // known to be present is found by the same scan.
    #expect(bound.contains { $0.lowercased() == "p" })
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
    let titles = AppCommands.viewMenuGroups.flatMap(\.items).map(\.title)
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
