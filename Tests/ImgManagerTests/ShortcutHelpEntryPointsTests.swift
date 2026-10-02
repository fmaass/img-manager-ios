import ImgManagerAPI
import SwiftUI
import Testing

@testable import ImgManager

/// IMGMGR-464 (WP32 P2, p4128 D10): "Keyboard Shortcuts sheet: ⌘/ + one menu item only". The
/// owner ruling of 2026-10-02 removed the keyboard-glyph help control from Compact's options row
/// ("the sheet opens with ⌘/ (hardware keyboard) and from the iPad menu bar"), so the sheet has
/// exactly two entry points, both declared in `AppCommands` and both ONE command: the View
/// menu's "Keyboard Shortcuts" row, bound to ⌘/, and that row's silent `?` twin (IMGMGR-463).
///
/// The ⌘/ half is proven HERE, at unit level, for the reason `MenuOneRowPerCommandTests` gives:
/// XCUITest cannot open the system menu bar and ⌘ key equivalents never reach the gate's
/// simulators. `CompactSelectUITests.testShortcutHelpSheetListsEveryActiveShortcut` opens the
/// rendered sheet with bare `?`, the twin that does arrive.
@MainActor
@Suite("Keyboard Shortcuts sheet: ⌘/ and one menu row (IMGMGR-464)")
struct ShortcutHelpEntryPointsTests {

  /// The two declarations that open the sheet, by id: the menu row and its silent twin.
  private static let entryPoints = ["view.help.command", "view.help.question"]

  /// Whether running `declaration` opens the sheet. Every closure of the probe is inert except
  /// `showShortcutHelp`, which records the call, so the answer is about THAT declaration's own
  /// `run` — with no store, no network and no preference write behind it.
  private static func opensTheSheet(_ declaration: MenuCommandDeclaration) -> Bool {
    var opened = false
    let probe = GridKeyboardActions(
      moveFocus: { _ in }, open: {}, pick: { _ in }, dislike: { _ in }, clear: { _ in },
      tag: {}, undo: {}, setRowHeight: { _ in }, selectGrouping: { _ in }, setSortKey: { _ in },
      toggleSortDirection: {}, toggleSceneMode: {}, showShortcutHelp: { opened = true },
      toggleAutoAdvanceOnMark: {})
    declaration.run(probe)
    return opened
  }

  /// The ids of the declarations in `declarations` that open the sheet, sorted.
  private static func helpDispatchers(_ declarations: [MenuCommandDeclaration]) -> [String] {
    declarations.filter { Self.opensTheSheet($0) }.map(\.id).sorted()
  }

  @Test("Exactly two declarations open the sheet: the ⌘/ menu row and its silent ? twin")
  func exactlyOneMenuRowAndItsSilentTwinOpenTheSheet() {
    let declarations = AppCommands.declarations
    #expect(Self.helpDispatchers(declarations) == Self.entryPoints)

    let dispatchers = declarations.filter { Self.entryPoints.contains($0.id) }
    let rows = dispatchers.filter { $0.presentation == .menuRow }.map(\.id)
    let silent = dispatchers.filter { $0.presentation == .silent }.map(\.id)
    #expect(rows == ["view.help.command"], "The sheet's menu rows: \(rows)")
    #expect(silent == ["view.help.question"], "The sheet's silent bindings: \(silent)")
    // One command: the twin is the row's own copy — same catalog entry, same title.
    #expect(dispatchers.allSatisfy { $0.shortcut == .help && $0.title == "Keyboard Shortcuts" })

    // Positive controls: a third route fails the count, so does a lost twin, and the probe tells
    // a declaration that opens something else from one that opens the sheet.
    let rogue = AppCommands.helpRow.silentTwin(
      id: "test.rogue", key: KeyEquivalent("h"), modifiers: [])
    #expect(Self.helpDispatchers(declarations + [rogue]) != Self.entryPoints)
    let withoutTwin = declarations.filter { $0.id != "view.help.question" }
    #expect(Self.helpDispatchers(withoutTwin) != Self.entryPoints)
    #expect(Self.opensTheSheet(AppCommands.helpRow))
    #expect(!Self.opensTheSheet(AppCommands.openRow))
  }

  /// The ⌘/ binding's own proof — the UI suite cannot press it (see the type's note). The row's
  /// key and modifiers, and its dispatch into `GridStore.showShortcutHelp()` on a real store.
  @Test("⌘/ is the View menu's Keyboard Shortcuts row and raises the sheet on a real store")
  func commandSlashIsTheMenuRowAndOpensTheSheet() {
    let row = AppCommands.helpRow
    #expect(row.key == KeyEquivalent("/"))
    #expect(row.modifiers == [.command])
    #expect(row.presentation == .menuRow)
    #expect(row.shortcut == .help)
    #expect(AppCommands.declarations.contains { $0.id == row.id && $0.modifiers == [.command] })

    let store = GridStore(
      service: GridService(client: ImgManagerAPIClient.make(transport: GridStubTransport())))
    #expect(store.isShortcutHelpPresented == false)
    row.run(store.keyboardActions)
    #expect(store.isShortcutHelpPresented == true, "⌘/ did not raise the shortcut sheet")
  }

  /// No chrome control opens the sheet (owner ruling 2026-10-02). The type's cases are pinned
  /// LITERALLY, so the deleted `.shortcutHelp` — or any new control — fails here until it is
  /// named; each remaining case's action is its own (Info, Search, Select, Filter, Arrange, More,
  /// Triage), and none ships the removed identifier.
  @Test("No ShellToolbarControl case opens the sheet")
  func noToolbarControlOpensTheSheet() {
    #expect(
      ShellToolbarControl.allCases == [
        .info, .search, .select, .filter, .arrange, .more, .triage,
      ])
    let identifiers = ShellToolbarControl.allCases.compactMap(\.accessibilityIdentifier)
    #expect(!identifiers.contains("gridShortcutHelpControl"))
    // Positive control: the identifiers were read (Filter ships one at every width).
    #expect(identifiers.contains("gridFilterControl"))
  }
}
