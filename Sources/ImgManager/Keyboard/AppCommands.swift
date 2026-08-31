import SwiftUI

/// One key equivalent (or one plain menu entry) this app declares, AS DATA. The `Commands`
/// body below renders exactly this table and carries no second, hand-written list — which is
/// what makes the catalog↔menu correspondence a TEST rather than a comment: deleting a menu
/// entry means deleting a row here, and `ShortcutCatalogTests` reads the same rows.
struct MenuCommandDeclaration: Identifiable {
  /// Stable and unique — the menu `ForEach`'s identity. Never an index (IMGMGR-210).
  let id: String
  /// The catalog entry this declaration realizes. Optional ONLY so that
  /// `ShortcutCatalogTests.everyMenuDeclarationIsKeyedAndCatalogued` is a test that can
  /// actually fail: NO shipped declaration may leave this (or `key`) nil — design decision 9's
  /// parity rule is that every menu entry has a declared bare/⌘ equivalent in the single
  /// catalog, and the Group single-select pair shipped in violation of it (diff-gate r1
  /// blocker 1) precisely because the reconciliation filtered unkeyed rows out instead of
  /// failing on them.
  let shortcut: ShortcutID?
  let title: String
  let key: KeyEquivalent?
  let modifiers: EventModifiers
  /// What activating it does, given the focused grid actions. The menu entry and the
  /// on-screen control it mirrors call the same `GridStore` method through this closure, so a
  /// shortcut and its button cannot drift apart.
  let run: (GridKeyboardActions) -> Void
}

/// A run of declarations rendered together, separated from its neighbours by one `Divider`.
struct MenuCommandGroup: Identifiable {
  let id: String
  let items: [MenuCommandDeclaration]
}

/// The dispatcher/menu-bar infrastructure P3 fold item 1 requires: the scene-level
/// `Commands` builder every phase's chrome adds its commands into once it lands. A shortcut
/// becomes ACTIVE — declared here — only in the same commit that ships its owning phase's
/// persistent-chrome surface (`ShortcutCatalog.swift`).
///
/// WP8 P4/P5 declared the bare web set (arrows, Space/Enter, P, X, U, Shift+advance, T, Z).
/// WP13 P4 (IMGMGR-215) adds design decision 9's OTHER half — "the web set verbatim as the
/// fast path **and** Command-equivalents for discovery", both, never one replacing the other:
/// the system View menu gains Group, the six zoom steps as ⌘1…⌘6, Scene view as ⌘⇧G, and the
/// shortcut help sheet as `?` and ⌘/. No existing bare key is re-keyed or removed.
///
/// `⌘G` is deliberately NOT used for Scene: it conventionally means "Find Next" on Apple
/// platforms and HIG Keyboards warns against re-binding established system shortcuts.
struct AppCommands: Commands {
  @FocusedValue(\.gridKeyboardActions) private var actions
  /// WP13 P11 (IMGMGR-220): the window command, published by `RootView` (see its own
  /// `.focusedSceneValue` call) because `openWindow` is a SCENE capability no `GridStore` can
  /// hold. Absent — like `actions` — whenever no workspace scene is focused.
  @FocusedValue(\.shootWindowCommand) private var shootWindow

  var body: some Commands {
    CommandMenu("Grid") {
      menuContent(Self.gridMenuGroups)
    }
    // NOT `CommandMenu("View")`, which the plan proposed: probed live on the iPad Pro 13" (M5)
    // simulator, iOS 26.5, 2026-08-30 — iPadOS 26 already provides `View` in the system menu
    // bar (observed: `img-manager · File · Edit · View · Grid · Window · Help`, with this app's
    // own `CommandMenu("Grid")` sitting between View and Window). `CommandMenu` always ADDS a
    // menu rather than merging by name, so declaring one called "View" would have put a second
    // View beside the system's. `CommandGroup(after: .sidebar)` inserts into the real one.
    CommandGroup(after: .sidebar) {
      menuContent(Self.viewMenuGroups)
      Divider()
      openInNewWindowEntry
    }
  }

  /// NOT a `MenuCommandDeclaration`: every row of that table is a KEY EQUIVALENT dispatched into
  /// `GridKeyboardActions` (`ShortcutCatalogTests.everyMenuDeclarationIsKeyedAndCatalogued`
  /// enforces that every declaration is keyed and catalogued), and this entry deliberately claims
  /// no key — it opens an OS window, which is not a culling accelerator and has no place in the
  /// shortcut inventory. It also dispatches into the window command rather than the grid actions,
  /// for the reason recorded on `ShootWindowCommand`.
  ///
  /// Its title comes from `ShootWindowCopy`, the same constant the grid's More menu row renders,
  /// so the two entry points cannot be spelled differently.
  @ViewBuilder private var openInNewWindowEntry: some View {
    Button(ShootWindowCopy.title) {
      shootWindow?.run()
    }
    .disabled(shootWindow?.isEnabled != true)
  }

  @ViewBuilder
  private func menuContent(_ groups: [MenuCommandGroup]) -> some View {
    let lastGroupID = groups.last?.id
    ForEach(groups) { group in
      ForEach(group.items) { item in
        entry(item)
      }
      if group.id != lastGroupID {
        Divider()
      }
    }
  }

  @ViewBuilder
  private func entry(_ item: MenuCommandDeclaration) -> some View {
    let button = Button(item.title) {
      if let actions { item.run(actions) }
    }
    .disabled(actions == nil)
    if let key = item.key {
      button.keyboardShortcut(key, modifiers: item.modifiers)
    } else {
      button
    }
  }
}

extension AppCommands {
  /// The "Grid" menu: WP8's bare web set, unchanged by WP13 P4.
  @MainActor static let gridMenuGroups: [MenuCommandGroup] = [
    MenuCommandGroup(
      id: "grid.focus",
      items: [
        MenuCommandDeclaration(
          id: "grid.focus.up", shortcut: .arrowUp, title: "Focus Up", key: .upArrow,
          modifiers: [], run: { $0.moveFocus(.up) }),
        MenuCommandDeclaration(
          id: "grid.focus.down", shortcut: .arrowDown, title: "Focus Down", key: .downArrow,
          modifiers: [], run: { $0.moveFocus(.down) }),
        MenuCommandDeclaration(
          id: "grid.focus.left", shortcut: .arrowLeft, title: "Focus Left", key: .leftArrow,
          modifiers: [], run: { $0.moveFocus(.left) }),
        MenuCommandDeclaration(
          id: "grid.focus.right", shortcut: .arrowRight, title: "Focus Right", key: .rightArrow,
          modifiers: [], run: { $0.moveFocus(.right) }),
      ]),
    // Space and Enter are ONE catalog entry (`ShortcutID.openSpaceEnter` — "Space and Enter
    // both mean 'open' on the web... one catalog entry, not two") but SwiftUI has no way to
    // bind two physical keys to a single `Button`, so this is two declarations dispatching the
    // SAME `open()` call.
    MenuCommandGroup(
      id: "grid.open",
      items: [
        MenuCommandDeclaration(
          id: "grid.open.return", shortcut: .openSpaceEnter, title: "Open", key: .return,
          modifiers: [], run: { $0.open() }),
        MenuCommandDeclaration(
          id: "grid.open.space", shortcut: .openSpaceEnter, title: "Open", key: .space,
          modifiers: [], run: { $0.open() }),
      ]),
    // Clear's chrome surface is the LOUPE's own mark bar (`ShortcutCatalog`'s own doc comment:
    // "P4's own bar has no Clear button") — the keyboard shortcut itself is scene-level, so it
    // fires from the grid too, same as every other entry here.
    MenuCommandGroup(
      id: "grid.marks",
      items: [
        MenuCommandDeclaration(
          id: "grid.mark.pick", shortcut: .pick, title: "Pick", key: KeyEquivalent("p"),
          modifiers: [], run: { $0.pick(false) }),
        MenuCommandDeclaration(
          id: "grid.mark.pickAdvance", shortcut: .shiftAdvance, title: "Pick and Advance",
          key: KeyEquivalent("p"), modifiers: [.shift], run: { $0.pick(true) }),
        MenuCommandDeclaration(
          id: "grid.mark.dislike", shortcut: .dislike, title: "Dislike",
          key: KeyEquivalent("x"), modifiers: [], run: { $0.dislike(false) }),
        MenuCommandDeclaration(
          id: "grid.mark.dislikeAdvance", shortcut: .shiftAdvance, title: "Dislike and Advance",
          key: KeyEquivalent("x"), modifiers: [.shift], run: { $0.dislike(true) }),
        MenuCommandDeclaration(
          id: "grid.mark.clear", shortcut: .clear, title: "Clear", key: KeyEquivalent("u"),
          modifiers: [], run: { $0.clear(false) }),
        MenuCommandDeclaration(
          id: "grid.mark.clearAdvance", shortcut: .shiftAdvance, title: "Clear and Advance",
          key: KeyEquivalent("u"), modifiers: [.shift], run: { $0.clear(true) }),
      ]),
    MenuCommandGroup(
      id: "grid.tagUndo",
      items: [
        MenuCommandDeclaration(
          id: "grid.tag", shortcut: .tag, title: "Add Tag…", key: KeyEquivalent("t"),
          modifiers: [], run: { $0.tag() }),
        MenuCommandDeclaration(
          id: "grid.undo", shortcut: .undo, title: "Undo", key: KeyEquivalent("z"),
          modifiers: [], run: { $0.undo() }),
      ]),
  ]

  /// The six zoom steps, keyed ⌘1…⌘6 in `GridRowHeight.allCases` order. Built by zipping the
  /// enum's own case list with the digits, so a seventh step cannot silently lose its key —
  /// `ShortcutCatalogTests` asserts the two counts are equal rather than trusting the zip.
  @MainActor static let zoomDeclarations: [MenuCommandDeclaration] =
    zip(GridRowHeight.allCases, "123456").map { step, digit in
      MenuCommandDeclaration(
        id: "view.zoom.\(Int(step.rawValue))", shortcut: .zoomStep,
        title: "\(Int(step.rawValue)) pt", key: KeyEquivalent(digit), modifiers: [.command],
        run: { $0.setRowHeight(step) })
    }

  /// What goes INTO the system View menu: p3220 §3.1's own discovery surface — "the menu
  /// bar… the discovery surface for shortcuts and for View options". Group's pair NAMES the two
  /// arrangements (AC: "a View menu naming them"); the ⌘⇧G entry is the on/off accelerator.
  /// Scene is a MODE, not a `group_by` wire value (ADR-0005 decision 6) — which is why the
  /// pair is single-select and `GROUP_KEYS` never gains a Scene entry.
  ///
  /// The pair carries ⌃⌘1 / ⌃⌘2 (diff-gate r1 blocker 1 — it shipped unkeyed, violating
  /// decision 9's parity rule). The assignment and its collision argument are recorded on
  /// `ShortcutID.groupMode`, the single inventory: the arrangement pair takes the zoom digits
  /// one modifier up, no iPadOS system default binds ⌃⌘digit, and `ShortcutCatalogTests`
  /// asserts both — no reserved combination is bound, and every (key, modifiers) pair in the
  /// app is unique.
  /// WP13 P5b (IMGMGR-221 part 2): the six offered sort keys, keyed ⌥⌘1…⌥⌘6 in
  /// `SortGroupOptions.sortKeys` order. Built by zipping the declared subset with the digits —
  /// the same shape `zoomDeclarations` uses, and for the same reason: a seventh offered key
  /// cannot silently lose its equivalent, because `ShortcutCatalogTests` asserts the two counts
  /// are equal rather than trusting the zip.
  ///
  /// ⌥⌘digit sits one modifier across from the zoom steps' ⌘digit and the arrangement pair's
  /// ⌃⌘digit; it collides with no iPadOS system default (the reserved set is ⌘Space, ⌘Tab, ⌘H,
  /// ⌘⌥D, ⌘⇧3/⌘⇧4, ⌃⌘Space, plus the ⌘G "Find Next" convention) and with nothing else in this
  /// app — both asserted, not claimed.
  @MainActor static let sortDeclarations: [MenuCommandDeclaration] =
    zip(SortGroupOptions.sortKeys, "123456").map { key, digit in
      MenuCommandDeclaration(
        id: "view.sort.\(key.rawValue)", shortcut: .sortKey,
        title: "Sort: \(key.title)", key: KeyEquivalent(digit), modifiers: [.command, .option],
        run: { $0.setSortKey(key) })
    }

  @MainActor static let viewMenuGroups: [MenuCommandGroup] = [
    MenuCommandGroup(
      id: "view.group",
      items: [
        MenuCommandDeclaration(
          id: "view.group.none", shortcut: .groupMode, title: "Group: None",
          key: KeyEquivalent("1"), modifiers: [.command, .control],
          run: { $0.selectGrouping(.none) }),
        MenuCommandDeclaration(
          id: "view.group.scene", shortcut: .groupMode, title: "Group: Scene",
          key: KeyEquivalent("2"), modifiers: [.command, .control],
          run: { $0.selectGrouping(.scene) }),
        MenuCommandDeclaration(
          id: "view.group.toggleScene", shortcut: .sceneToggle, title: "Toggle Scene View",
          key: KeyEquivalent("g"), modifiers: [.command, .shift], run: { $0.toggleSceneMode() }),
      ]),
    // WP13 P5b: Sort — the six offered keys plus the direction toggle. It sits directly after
    // Group because the two together are "how is this stream arranged", the question the View
    // menu is the discovery surface for (p3220 §3.1).
    MenuCommandGroup(
      id: "view.sort",
      items: AppCommands.sortDeclarations + [
        MenuCommandDeclaration(
          id: "view.sort.reverse", shortcut: .sortDirection, title: "Reverse Sort Direction",
          key: KeyEquivalent("r"), modifiers: [.command, .option],
          run: { $0.toggleSortDirection() })
      ]),
    MenuCommandGroup(id: "view.zoom", items: AppCommands.zoomDeclarations),
    // WP13 P8 (IMGMGR-214): advance-on-mark, in the View menu because that menu is the
    // discovery surface for what the app does with a keypress (p3220 §3.1) — and in BOTH forms,
    // decision 9's "the web set verbatim as the fast path AND Command-equivalents for
    // discovery": bare `A` is the web's own key, ⌘⇧A is its discovery twin. Two declarations,
    // one action, exactly the shape `Open` and `Keyboard Shortcuts` already use.
    //
    // Plain ⌘A is deliberately NOT used — it is the established "Select All" and this app has a
    // Select mode of its own, the same argument `sceneToggle` records for ⌘G. The
    // reserved-combination test asserts it, with its own positive control.
    MenuCommandGroup(
      id: "view.autoAdvance",
      items: [
        MenuCommandDeclaration(
          id: "view.autoAdvance.command", shortcut: .autoAdvance, title: "Advance After Marking",
          key: KeyEquivalent("a"), modifiers: [.command, .shift],
          run: { $0.toggleAutoAdvanceOnMark() }),
        MenuCommandDeclaration(
          id: "view.autoAdvance.bare", shortcut: .autoAdvance, title: "Advance After Marking",
          key: KeyEquivalent("a"), modifiers: [], run: { $0.toggleAutoAdvanceOnMark() }),
      ]),
    // `?` is the web set's own key and ⌘/ is its Command-equivalent — decision 9's "both,
    // never one replacing the other". Two declarations, one action, exactly like Open above.
    MenuCommandGroup(
      id: "view.help",
      items: [
        MenuCommandDeclaration(
          id: "view.help.command", shortcut: .help, title: "Keyboard Shortcuts",
          key: KeyEquivalent("/"), modifiers: [.command], run: { $0.showShortcutHelp() }),
        MenuCommandDeclaration(
          id: "view.help.question", shortcut: .help, title: "Keyboard Shortcuts",
          key: KeyEquivalent("?"), modifiers: [], run: { $0.showShortcutHelp() }),
      ]),
  ]

  /// Every declaration in every menu, flattened — the set `ShortcutCatalogTests` reconciles
  /// against `ShortcutCatalog` in both directions.
  @MainActor static var declarations: [MenuCommandDeclaration] {
    (gridMenuGroups + viewMenuGroups).flatMap(\.items)
  }
}
