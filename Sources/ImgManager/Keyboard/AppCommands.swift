import SwiftUI

/// One key equivalent (or one plain menu entry) this app declares, AS DATA. The `Commands`
/// body below renders exactly this table and carries no second, hand-written list — which is
/// what makes the catalog↔menu correspondence a TEST rather than a comment: deleting a menu
/// entry means deleting a row here, and `ShortcutCatalogTests` reads the same rows. Since
/// IMGMGR-463 the table is rendered by two hosts split by `presentation`: the menu rows by that
/// body, a command's silent second key by `SilentKeyCommandHost` — still one list.
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
  /// Which focused value activating it dispatches into, and what it does there.
  let target: Target
  /// Whether the binding draws a menu row. IMGMGR-463 (p4128 D10): one row per command — a
  /// command's second key is still declared HERE, so every reconciliation test still sees it,
  /// but it is handled silently by `SilentKeyCommandHost` rather than drawn as a twin row.
  let presentation: Presentation

  /// How a declaration reaches the keyboard (IMGMGR-463).
  enum Presentation {
    /// A row of the Grid or View menu, rendered by `AppCommands.menuContent(_:)`.
    case menuRow
    /// Bound, enabled and dispatched exactly like its menu row, but drawn nowhere: a command's
    /// secondary key (Space, bare A, `?`), rendered by `SilentKeyCommandHost`.
    case silent
  }

  /// The focused value an entry acts on. IMGMGR-495 adds the second case: ⌘0 acts on the
  /// mounted viewer's zoom (`ViewerZoomCommand`), which the scene publishes while Compare is open
  /// — when `GridKeyboardActions` is deliberately nil (WP30 P3 plan decision 7) — and does not
  /// publish on the bare grid.
  enum Target {
    /// The menu entry and the on-screen control it mirrors call the same `GridStore` method
    /// through this closure, so a shortcut and its button cannot drift apart.
    case grid((GridKeyboardActions) -> Void)
    /// The viewer's own zoom toggle (IMGMGR-495).
    case viewerZoom((ViewerZoomCommand) -> Void)
  }

  /// A grid-actions entry — every row WP8 and WP13 declared, spelled exactly as they were.
  init(
    id: String, shortcut: ShortcutID?, title: String, key: KeyEquivalent?,
    modifiers: EventModifiers, run: @escaping (GridKeyboardActions) -> Void
  ) {
    self.init(
      id: id, shortcut: shortcut, title: title, key: key, modifiers: modifiers,
      target: .grid(run))
  }

  /// A viewer-zoom entry (IMGMGR-495).
  init(
    id: String, shortcut: ShortcutID?, title: String, key: KeyEquivalent?,
    modifiers: EventModifiers, viewerZoom: @escaping (ViewerZoomCommand) -> Void
  ) {
    self.init(
      id: id, shortcut: shortcut, title: title, key: key, modifiers: modifiers,
      target: .viewerZoom(viewerZoom))
  }

  private init(
    id: String, shortcut: ShortcutID?, title: String, key: KeyEquivalent?,
    modifiers: EventModifiers, target: Target, presentation: Presentation = .menuRow
  ) {
    self.id = id
    self.shortcut = shortcut
    self.title = title
    self.key = key
    self.modifiers = modifiers
    self.target = target
    self.presentation = presentation
  }

  /// This command's secondary key, handled silently (IMGMGR-463). Everything but the id and the
  /// key is COPIED from the menu row — catalog entry, title and target — so the silent binding
  /// cannot dispatch, enable or be catalogued differently from the row it stands behind, and the
  /// command's title is spelled once in this file.
  func silentTwin(
    id: String, key: KeyEquivalent, modifiers: EventModifiers
  ) -> MenuCommandDeclaration {
    MenuCommandDeclaration(
      id: id, shortcut: shortcut, title: title, key: key, modifiers: modifiers, target: target,
      presentation: .silent)
  }

  /// What activating it does, given the focused grid actions — a no-op on a viewer-zoom entry,
  /// which the grid's actions cannot reach. Kept as the grid entries' single call shape, so the
  /// tests that invoke a declaration "exactly as `AppCommands.entry(_:)`'s Button does" still do.
  func run(_ actions: GridKeyboardActions) {
    perform(grid: actions, viewerZoom: nil)
  }

  /// Whether the entry is live: the focused value it dispatches into is published. A grid entry
  /// follows the grid's actions (nil while Compare is open, decision 7); the ⌘0 entry follows the
  /// mounted viewer, so it is disabled on the bare grid and live in the loupe and in Compare.
  func isEnabled(grid: GridKeyboardActions?, viewerZoom: ViewerZoomCommand?) -> Bool {
    switch target {
    case .grid: return grid != nil
    case .viewerZoom: return viewerZoom != nil
    }
  }

  /// Activates the entry against whichever focused values are published — the ONE dispatch the
  /// menu's Button calls, so the enabled state and the action read the same value.
  func perform(grid: GridKeyboardActions?, viewerZoom: ViewerZoomCommand?) {
    switch target {
    case .grid(let run):
      if let grid { run(grid) }
    case .viewerZoom(let run):
      if let viewerZoom { run(viewerZoom) }
    }
  }
}

/// The menu bar's "Open in New Window" entry, AS DATA. WP16 P4 (IMGMGR-297), the plan's B8 fold.
///
/// The same discipline `MenuCommandDeclaration` applies to every keyed command, for the same
/// reason: the `Commands` body renders exactly this value and decides nothing of its own, so what
/// the entry says, whether it is enabled and what it opens are a TEST (`ShootWindowEntryTests`)
/// rather than a comment. It is deliberately NOT a `MenuCommandDeclaration` — every row of that
/// table is a key equivalent dispatched into a focused value (`GridKeyboardActions`, or since
/// IMGMGR-495 the viewer's `ViewerZoomCommand`), and this entry claims no key.
struct ShootWindowMenuEntry {
  let title: String
  let isEnabled: Bool
  /// Closes over the ONE opening path (`ShootWindowAction.open`, reached through the focused
  /// command's own `run()`), so the menu bar and the grid's More row cannot open different things.
  let action: @MainActor () -> Void
}

/// A run of declarations rendered together, separated from its neighbours by one `Divider`.
struct MenuCommandGroup: Identifiable {
  let id: String
  /// Every binding of the group, silent ones included — what the reconciliation tests read.
  let items: [MenuCommandDeclaration]

  /// What the menu draws: one row per command (IMGMGR-463).
  var menuRows: [MenuCommandDeclaration] {
    items.filter { $0.presentation == .menuRow }
  }
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
  /// IMGMGR-495: the mounted viewer's zoom toggle, published by `LoupeView` and `CompareView`.
  /// Absent on the bare grid, which is what disables the ⌘0 entry there.
  @FocusedValue(\.viewerZoomCommand) private var viewerZoom

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

  /// NOT a `MenuCommandDeclaration`: every row of that table is a KEY EQUIVALENT dispatched into a
  /// focused value (`ShortcutCatalogTests.everyMenuDeclarationIsKeyedAndCatalogued`
  /// enforces that every declaration is keyed and catalogued), and this entry deliberately claims
  /// no key — it opens an OS window, which is not a culling accelerator and has no place in the
  /// shortcut inventory. It also dispatches into the window command rather than the grid actions,
  /// for the reason recorded on `ShootWindowCommand`.
  ///
  /// WP16 P4 (IMGMGR-297) B8: the body is ONE `let` and ONE `Button` BY CONSTRUCTION. Every
  /// decision the entry makes — its words (`ShootWindowCopy`, the same constant the grid's More
  /// row renders, so the two cannot be spelled differently), whether it is enabled, and what it
  /// opens — is made by `makeOpenInNewWindowEntry(command:)`, which the test drives directly.
  /// ViewInspector is not a dependency of this project, so nothing automated proves this Button
  /// renders `entry.title` and calls `entry.action`; a Button that bypasses the factory is a
  /// diff-gate blocker, and the one-liner is what keeps that visible in review.
  @ViewBuilder private var openInNewWindowEntry: some View {
    let entry = Self.makeOpenInNewWindowEntry(command: shootWindow)
    Button(entry.title) { entry.action() }
      .disabled(!entry.isEnabled)
  }

  @ViewBuilder
  private func menuContent(_ groups: [MenuCommandGroup]) -> some View {
    let lastGroupID = groups.last?.id
    ForEach(groups) { group in
      ForEach(group.menuRows) { item in
        entry(item)
      }
      if group.id != lastGroupID {
        Divider()
      }
    }
  }

  @ViewBuilder
  private func entry(_ item: MenuCommandDeclaration) -> some View {
    // Copied into locals so the Button's action reads the values this render saw, the same
    // values `isEnabled` decided on.
    let grid = actions
    let zoom = viewerZoom
    let button = Button(item.title) {
      item.perform(grid: grid, viewerZoom: zoom)
    }
    .disabled(!item.isEnabled(grid: grid, viewerZoom: zoom))
    if let key = item.key {
      button.keyboardShortcut(key, modifiers: item.modifiers)
    } else {
      button
    }
  }
}

extension AppCommands {
  /// The menu-bar "Open in New Window" entry, built from the focused command and from nothing
  /// else — the SAME factory `openInNewWindowEntry` renders, which is what lets a test stand in
  /// for the UI leg that platform cannot give this entry (no key equivalent to send, and the
  /// system menu bar is not XCUITest-openable).
  ///
  /// `isEnabled` is the command's own predicate (`ShootSceneValue.from(query:) != nil`) and the
  /// action delegates to `ShootWindowCommand.run()`, i.e. the shared `ShootWindowAction.open`:
  /// no second predicate and no second opening path. With no workspace scene focused the
  /// `@FocusedValue` is nil, and the entry is then disabled with an action that opens nothing.
  static func makeOpenInNewWindowEntry(command: ShootWindowCommand?) -> ShootWindowMenuEntry {
    ShootWindowMenuEntry(
      title: ShootWindowCopy.title,
      isEnabled: command?.isEnabled == true,
      action: { command?.run() })
  }

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
    // SAME `open()` call. IMGMGR-463: Return is the menu row, Space its silent twin.
    MenuCommandGroup(
      id: "grid.open",
      items: [
        openRow,
        openRow.silentTwin(id: "grid.open.space", key: .space, modifiers: []),
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
    // IMGMGR-495 (owner ruling, comment 10230): "⌘0 alone toggles Fit/100% in the loupe and in
    // Compare; ⌘1 stays the grid's first zoom step; no second key." ONE row, beside the grid's
    // zoom steps because both answer "how big is the photograph", dispatched into the mounted
    // viewer's own toggle — the loupe's `LoupeZoomState.toggle()`, Compare's
    // `CompareZoomSync.toggleAll()` — and disabled on the bare grid, where nothing publishes it.
    MenuCommandGroup(
      id: "view.viewerZoom",
      items: [
        MenuCommandDeclaration(
          id: "view.viewerZoom.toggle", shortcut: .viewerZoomToggle, title: "Zoom: Fit / 100%",
          key: KeyEquivalent("0"), modifiers: [.command], viewerZoom: { $0.toggle() })
      ]),
    // WP13 P8 (IMGMGR-214): advance-on-mark, in the View menu because that menu is the
    // discovery surface for what the app does with a keypress (p3220 §3.1) — and in BOTH forms,
    // decision 9's "the web set verbatim as the fast path AND Command-equivalents for
    // discovery": bare `A` is the web's own key, ⌘⇧A is its discovery twin. Two declarations,
    // one action, exactly the shape `Open` and `Keyboard Shortcuts` already use. IMGMGR-463:
    // ⌘⇧A is the menu row, bare A its silent twin.
    //
    // Plain ⌘A is deliberately NOT used — it is the established "Select All" and this app has a
    // Select mode of its own, the same argument `sceneToggle` records for ⌘G. The
    // reserved-combination test asserts it, with its own positive control.
    MenuCommandGroup(
      id: "view.autoAdvance",
      items: [
        autoAdvanceRow,
        autoAdvanceRow.silentTwin(
          id: "view.autoAdvance.bare", key: KeyEquivalent("a"), modifiers: []),
      ]),
    // `?` is the web set's own key and ⌘/ is its Command-equivalent — decision 9's "both,
    // never one replacing the other". Two declarations, one action, exactly like Open above;
    // IMGMGR-463: ⌘/ is the menu row, `?` its silent twin.
    MenuCommandGroup(
      id: "view.help",
      items: [
        helpRow,
        helpRow.silentTwin(id: "view.help.question", key: KeyEquivalent("?"), modifiers: []),
      ]),
  ]

  /// IMGMGR-463 (p4128 D10): the menu rows of the three commands bound to two keys. Each is
  /// declared once, here, and its group pairs it with a `silentTwin` for the secondary key — so
  /// the row and the silent binding share one title, one catalog entry and one action BY
  /// CONSTRUCTION. The row carries the menu-bar key (Return, ⌘⇧A, ⌘/); the twin, the web's.
  @MainActor static let openRow = MenuCommandDeclaration(
    id: "grid.open.return", shortcut: .openSpaceEnter, title: "Open", key: .return,
    modifiers: [], run: { $0.open() })

  @MainActor static let autoAdvanceRow = MenuCommandDeclaration(
    id: "view.autoAdvance.command", shortcut: .autoAdvance, title: "Advance After Marking",
    key: KeyEquivalent("a"), modifiers: [.command, .shift],
    run: { $0.toggleAutoAdvanceOnMark() })

  @MainActor static let helpRow = MenuCommandDeclaration(
    id: "view.help.command", shortcut: .help, title: "Keyboard Shortcuts",
    key: KeyEquivalent("/"), modifiers: [.command], run: { $0.showShortcutHelp() })

  /// Every declaration in every menu, flattened — the set `ShortcutCatalogTests` reconciles
  /// against `ShortcutCatalog` in both directions.
  @MainActor static var declarations: [MenuCommandDeclaration] {
    (gridMenuGroups + viewMenuGroups).flatMap(\.items)
  }

  /// The bindings `SilentKeyCommandHost` renders — every declaration the menus do not draw
  /// (IMGMGR-463). Derived from `declarations`, never listed a second time.
  @MainActor static var silentDeclarations: [MenuCommandDeclaration] {
    declarations.filter { $0.presentation == .silent }
  }
}
