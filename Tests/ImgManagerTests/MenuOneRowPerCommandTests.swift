import SwiftUI
import Testing

@testable import ImgManager

/// IMGMGR-463 (WP32 P1, p4128 D10): "one item per command, sections, no duplicate titles … one
/// row per command, the secondary key handled silently". The proof is UNIT-level over the
/// declaration data: XCUITest cannot open the system menu bar, and ⌘-key equivalents never
/// reach the gate's iPad simulator (`CompactSelectUITests`'s own note), so what the menus draw
/// and which keys stay bound are asserted on the very tables `AppCommands` and
/// `SilentKeyCommandHost` render.
@MainActor
@Suite("Menu bar: one row per command (IMGMGR-463)")
struct MenuOneRowPerCommandTests {

  // MARK: - Shortcuts unchanged

  /// One (key, modifiers) → command binding, flattened to text so a sorted array of them is a
  /// multiset that can be compared with `==`.
  nonisolated private static func binding(
    _ key: KeyEquivalent, _ modifiers: EventModifiers, _ id: String, _ shortcut: ShortcutID?
  ) -> String {
    "\(String(key.character))|\(modifiers.rawValue)|\(id)|\(shortcut?.rawValue ?? "nil")"
  }

  /// Every binding shipped at 94d82dc (IMGMGR-495's ⌘0 row included), spelled out LITERALLY —
  /// never derived from the tables under test, so dropping or re-keying any binding fails.
  private static let shipped: [String] = [
    binding(.upArrow, [], "grid.focus.up", .arrowUp),
    binding(.downArrow, [], "grid.focus.down", .arrowDown),
    binding(.leftArrow, [], "grid.focus.left", .arrowLeft),
    binding(.rightArrow, [], "grid.focus.right", .arrowRight),
    binding(.return, [], "grid.open.return", .openSpaceEnter),
    binding(.space, [], "grid.open.space", .openSpaceEnter),
    // IMGMGR-542 (R3-22): Esc, a hidden key with no menu row, closes the most recent peek band.
    binding(.escape, [], "grid.closeBand.escape", .closeBand),
    binding(KeyEquivalent("p"), [], "grid.mark.pick", .pick),
    binding(KeyEquivalent("p"), [.shift], "grid.mark.pickAdvance", .shiftAdvance),
    binding(KeyEquivalent("x"), [], "grid.mark.dislike", .dislike),
    binding(KeyEquivalent("x"), [.shift], "grid.mark.dislikeAdvance", .shiftAdvance),
    binding(KeyEquivalent("u"), [], "grid.mark.clear", .clear),
    binding(KeyEquivalent("u"), [.shift], "grid.mark.clearAdvance", .shiftAdvance),
    binding(KeyEquivalent("t"), [], "grid.tag", .tag),
    binding(KeyEquivalent("z"), [], "grid.undo", .undo),
    binding(KeyEquivalent("1"), [.command, .control], "view.group.none", .groupMode),
    binding(KeyEquivalent("2"), [.command, .control], "view.group.scene", .groupMode),
    binding(KeyEquivalent("g"), [.command, .shift], "view.group.toggleScene", .sceneToggle),
    binding(KeyEquivalent("1"), [.command, .option], "view.sort.date_taken", .sortKey),
    binding(KeyEquivalent("2"), [.command, .option], "view.sort.filename", .sortKey),
    binding(KeyEquivalent("3"), [.command, .option], "view.sort.rating", .sortKey),
    binding(KeyEquivalent("4"), [.command, .option], "view.sort.iso", .sortKey),
    binding(KeyEquivalent("5"), [.command, .option], "view.sort.camera", .sortKey),
    binding(KeyEquivalent("6"), [.command, .option], "view.sort.lens", .sortKey),
    binding(KeyEquivalent("r"), [.command, .option], "view.sort.reverse", .sortDirection),
    binding(KeyEquivalent("1"), [.command], "view.zoom.120", .zoomStep),
    binding(KeyEquivalent("2"), [.command], "view.zoom.160", .zoomStep),
    binding(KeyEquivalent("3"), [.command], "view.zoom.200", .zoomStep),
    binding(KeyEquivalent("4"), [.command], "view.zoom.260", .zoomStep),
    binding(KeyEquivalent("5"), [.command], "view.zoom.320", .zoomStep),
    binding(KeyEquivalent("6"), [.command], "view.zoom.400", .zoomStep),
    binding(KeyEquivalent("0"), [.command], "view.viewerZoom.toggle", .viewerZoomToggle),
    binding(KeyEquivalent("a"), [.command, .shift], "view.autoAdvance.command", .autoAdvance),
    binding(KeyEquivalent("a"), [], "view.autoAdvance.bare", .autoAdvance),
    binding(KeyEquivalent("/"), [.command], "view.help.command", .help),
    binding(KeyEquivalent("?"), [], "view.help.question", .help),
  ]

  /// What a table binds, in the same flattened form. An unkeyed declaration (which
  /// `ShortcutCatalogTests` already forbids) is kept as a "nil" key, so it cannot vanish here.
  private static func bound(_ declarations: [MenuCommandDeclaration]) -> [String] {
    declarations.map { declaration in
      guard let key = declaration.key else { return "nil|\(declaration.id)" }
      return binding(key, declaration.modifiers, declaration.id, declaration.shortcut)
    }
  }

  private static func bindsExactlyTheShippedSet(_ declarations: [MenuCommandDeclaration]) -> Bool {
    bound(declarations).sorted() == shipped.sorted()
  }

  @Test("Every shipped (key, modifiers) → command binding survives, none added, none re-keyed")
  func shippedBindingsAreUnchanged() {
    #expect(Self.shipped.count == 36)
    #expect(Self.bindsExactlyTheShippedSet(AppCommands.declarations))
    // Each binding is rendered by exactly one host: a menu row or the silent host.
    let rows = (AppCommands.gridMenuGroups + AppCommands.viewMenuGroups).flatMap(\.menuRows)
    #expect(rows.count + AppCommands.silentDeclarations.count == Self.shipped.count)

    // POSITIVE CONTROLS, same predicate (LSN-0033): a dropped binding and a re-keyed one both
    // fail it, so the pass above is a comparison that can fail.
    #expect(!Self.bindsExactlyTheShippedSet(Array(AppCommands.declarations.dropLast())))
    let rekeyed = AppCommands.declarations.map { declaration in
      guard declaration.id == "grid.open.space" else { return declaration }
      return AppCommands.openRow.silentTwin(
        id: "grid.open.space", key: KeyEquivalent("o"), modifiers: [])
    }
    #expect(!Self.bindsExactlyTheShippedSet(rekeyed))
  }

  // MARK: - One row per command, unique titles

  private static func hasUniqueTitles(_ titles: [String]) -> Bool {
    Set(titles).count == titles.count
  }

  /// Every title the Grid menu and this app's View-menu insertion draw, "Open in New Window"
  /// included — the runtime titles, so the interpolated zoom and sort rows count too.
  private static var menuTitles: [String] {
    (AppCommands.gridMenuGroups + AppCommands.viewMenuGroups).flatMap(\.menuRows).map(\.title)
      + [ShootWindowCopy.title]
  }

  @Test("No two menu rows share a title across the Grid and View menus")
  func menuRowTitlesAreUnique() {
    #expect(Self.hasUniqueTitles(Self.menuTitles), "duplicated menu titles: \(Self.menuTitles)")

    // POSITIVE CONTROL: the same predicate fails on a duplicated title...
    #expect(!Self.hasUniqueTitles(Self.menuTitles + ["Open"]))
    // ...and on the full binding list, silent twins included: the twins still carry their
    // command's title, so it is `menuRows` — not their absence — that keeps the menu unique.
    #expect(!Self.hasUniqueTitles(AppCommands.declarations.map(\.title)))
  }

  @Test("Open, Advance After Marking and Keyboard Shortcuts are ONE row each, on the primary key")
  func eachTwoKeyCommandDrawsOneRowOnItsPrimaryKey() {
    expectOneRow(.openSpaceEnter, title: "Open", key: .return, modifiers: [])
    expectOneRow(
      .autoAdvance, title: "Advance After Marking", key: KeyEquivalent("a"),
      modifiers: [.command, .shift])
    expectOneRow(
      .help, title: "Keyboard Shortcuts", key: KeyEquivalent("/"), modifiers: [.command])
  }

  private func expectOneRow(
    _ shortcut: ShortcutID, title: String, key: KeyEquivalent, modifiers: EventModifiers
  ) {
    let rows = (AppCommands.gridMenuGroups + AppCommands.viewMenuGroups).flatMap(\.menuRows)
    let matching = rows.filter { $0.shortcut == shortcut }
    #expect(matching.count == 1, "\(shortcut.rawValue) draws \(matching.count) rows")
    #expect(matching.first?.title == title)
    #expect(matching.first?.key == key)
    #expect(matching.first?.modifiers == modifiers)
  }

  @Test("Only Space, bare A, ? and the hidden Esc are silent — no other binding lost its row")
  func onlyTheThreeSecondaryKeysAreSilent() {
    let silent = AppCommands.silentDeclarations
    let expected = [
      "grid.closeBand.escape", "grid.open.space", "view.autoAdvance.bare", "view.help.question",
    ]
    #expect(silent.map(\.id).sorted() == expected)
    #expect(silent.allSatisfy { $0.modifiers.isEmpty })
    let keys = silent.compactMap { $0.key.map { String($0.character) } }
    #expect(keys.count == silent.count, "a silent declaration with no key renders nothing")
    #expect(
      Set(keys) == [
        String(KeyEquivalent.space.character), "a", "?", String(KeyEquivalent.escape.character),
      ])
  }

  @Test("Every group still draws a row — no orphan Divider from an all-silent group")
  func everyMenuGroupDrawsAtLeastOneRow() {
    let groups = AppCommands.gridMenuGroups + AppCommands.viewMenuGroups
    let empty = groups.filter { $0.menuRows.isEmpty }.map(\.id)
    #expect(empty.isEmpty, "groups that draw no row: \(empty)")

    // POSITIVE CONTROL: a group holding only a silent twin draws nothing.
    let twin = AppCommands.helpRow.silentTwin(id: "test.q", key: KeyEquivalent("?"), modifiers: [])
    let silentOnly = MenuCommandGroup(id: "test.silentOnly", items: [twin])
    #expect(silentOnly.menuRows.isEmpty)
  }

  // MARK: - The silent key behaves like its row

  /// Every call a declaration makes into the grid actions, in order.
  private final class DispatchLog {
    var calls: [String] = []
  }

  private func recordingActions(
    _ log: DispatchLog, canCloseBand: Bool = true
  ) -> GridKeyboardActions {
    GridKeyboardActions(
      moveFocus: { log.calls.append("moveFocus.\($0)") },
      open: { log.calls.append("open") },
      pick: { log.calls.append("pick.\($0)") },
      dislike: { log.calls.append("dislike.\($0)") },
      clear: { log.calls.append("clear.\($0)") },
      tag: { log.calls.append("tag") },
      undo: { log.calls.append("undo") },
      setRowHeight: { log.calls.append("setRowHeight.\($0)") },
      selectGrouping: { log.calls.append("selectGrouping.\($0)") },
      setSortKey: { log.calls.append("setSortKey.\($0)") },
      toggleSortDirection: { log.calls.append("toggleSortDirection") },
      toggleSceneMode: { log.calls.append("toggleSceneMode") },
      showShortcutHelp: { log.calls.append("showShortcutHelp") },
      toggleAutoAdvanceOnMark: { log.calls.append("toggleAutoAdvanceOnMark") },
      closeMostRecentBand: { log.calls.append("closeMostRecentBand") },
      canCloseBand: { canCloseBand })
  }

  private func calls(of declaration: MenuCommandDeclaration) -> [String] {
    let log = DispatchLog()
    // Exactly as `AppCommands.entry(_:)` and `SilentKeyCommandHost` call it.
    declaration.perform(grid: recordingActions(log), viewerZoom: nil)
    return log.calls
  }

  @Test("Each silent key dispatches, and is enabled, exactly like its command's menu row")
  func silentTwinsDispatchAndEnableLikeTheirMenuRows() {
    let rows = (AppCommands.gridMenuGroups + AppCommands.viewMenuGroups).flatMap(\.menuRows)
    let actions = recordingActions(DispatchLog())
    // The hidden Esc has no row by design; it is pinned by its own test below.
    let twins = AppCommands.silentDeclarations.filter { $0.id != AppCommands.closeBandKey.id }
    #expect(twins.count == 3)
    for twin in twins {
      let row = rows.filter { $0.shortcut == twin.shortcut && $0.title == twin.title }
      #expect(row.count == 1, "\(twin.id) has no single menu row standing in front of it")
      guard let row = row.first else { continue }
      #expect(!calls(of: twin).isEmpty, "\(twin.id) dispatches nothing")
      #expect(calls(of: twin) == calls(of: row), "\(twin.id) and \(row.id) do different things")
      // Disabled with no grid actions focused (e.g. Compare open), live with them — as the row.
      #expect(!twin.isEnabled(grid: nil, viewerZoom: nil))
      #expect(!row.isEnabled(grid: nil, viewerZoom: nil))
      #expect(twin.isEnabled(grid: actions, viewerZoom: nil))
      #expect(row.isEnabled(grid: actions, viewerZoom: nil))
    }

    // POSITIVE CONTROL: the dispatch comparison tells two different commands apart.
    let pick = rows.first { $0.id == "grid.mark.pick" }
    #expect(pick.map { calls(of: $0) } != calls(of: AppCommands.openRow))
  }

  /// IMGMGR-542 (R3-22): Esc draws no row, closes the most recent band, and is live ONLY while a
  /// band can close — disabled, the key falls through to whatever owns Esc (a sheet, a popover).
  @Test("Esc draws no row, closes the most recent band, and is live only while one can close")
  func escIsAHiddenKeyLiveOnlyWhileABandCanClose() {
    let esc = AppCommands.closeBandKey
    let rows = (AppCommands.gridMenuGroups + AppCommands.viewMenuGroups).flatMap(\.menuRows)
    #expect(!rows.contains { $0.shortcut == .closeBand })
    #expect(AppCommands.declarations.filter { $0.shortcut == .closeBand }.count == 1)
    #expect(esc.key == .escape)
    #expect(esc.modifiers.isEmpty)
    #expect(calls(of: esc) == ["closeMostRecentBand"])

    let live = recordingActions(DispatchLog(), canCloseBand: true)
    let deadLog = DispatchLog()
    let dead = recordingActions(deadLog, canCloseBand: false)
    #expect(esc.isEnabled(grid: live, viewerZoom: nil))
    #expect(!esc.isEnabled(grid: dead, viewerZoom: nil))
    #expect(!esc.isEnabled(grid: nil, viewerZoom: nil))
    // Disabled means inert even if invoked: nothing closes behind a sheet.
    esc.perform(grid: dead, viewerZoom: nil)
    #expect(deadLog.calls.isEmpty)
    // POSITIVE CONTROL: the same `canCloseBand: false` does not disable an ordinary row.
    #expect(AppCommands.openRow.isEnabled(grid: dead, viewerZoom: nil))
  }

  @Test("The help sheet still lists Space, A and ? — the silent keys stay discoverable there")
  func helpSheetStillListsTheSecondaryKeys() {
    let keys = Dictionary(uniqueKeysWithValues: ShortcutHelpModel.rows.map { ($0.id, $0.key) })
    #expect(keys[ShortcutID.openSpaceEnter.rawValue] == "Space or Return")
    #expect(keys[ShortcutID.autoAdvance.rawValue] == "A or ⌘⇧A")
    #expect(keys[ShortcutID.help.rawValue] == "? or ⌘/")
    #expect(keys[ShortcutID.closeBand.rawValue] == "Esc")
  }

  /// IMGMGR-541: the menu bar's group commands list no Day and no Month. They never did (the
  /// View menu's group rows are None, Scene and the Scene toggle), so this is a guard: it goes red
  /// only if a retired key comes back as a row.
  @Test("The menu-bar group commands list no Day and no Month")
  func menuBarGroupCommandsListNoDayOrMonth() {
    let rows = (AppCommands.gridMenuGroups + AppCommands.viewMenuGroups).flatMap(\.menuRows)
    for row in rows {
      #expect(!row.id.hasSuffix(".day") && !row.id.hasSuffix(".month"), "\(row.id)")
      #expect(!row.title.contains("Group: Day") && !row.title.contains("Group: Month"))
    }
    let groupRows = rows.filter { $0.id.hasPrefix("view.group.") }.map(\.id)
    #expect(groupRows == ["view.group.none", "view.group.scene", "view.group.toggleScene"])
  }
}
