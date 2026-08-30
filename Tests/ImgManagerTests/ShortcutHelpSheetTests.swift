import Testing

@testable import ImgManager

/// WP13 P4 (IMGMGR-215): the `?` surface. The sheet renders `ShortcutHelpModel.rows` and
/// nothing else, so these assertions are about what a reader actually sees listed.
@Suite("Shortcut help sheet (WP13 P4)")
struct ShortcutHelpSheetTests {

  @Test("Lists exactly the ACTIVE catalog entries — never a hand-written list that can drift")
  func listsExactlyTheActiveCatalogEntries() {
    let rows = ShortcutHelpModel.rows
    let active = ShortcutCatalog.activeEntries

    #expect(rows.map(\.id) == active.map { $0.id.rawValue })
    #expect(rows.count == active.count)
    // An INACTIVE entry must never appear: the sheet is the inventory of what actually works.
    let inactive = ShortcutCatalog.entries.filter { !$0.isActive }.map { $0.id.rawValue }
    #expect(rows.allSatisfy { !inactive.contains($0.id) })
    // Row identity is the entry's own raw value, never an index (IMGMGR-210).
    #expect(Set(rows.map(\.id)).count == rows.count)
  }

  @Test("Every row carries a key and a meaning a reader can act on — no empty cells")
  func everyRowCarriesAKeyAndAMeaning() {
    for row in ShortcutHelpModel.rows {
      #expect(!row.key.isEmpty)
      #expect(!row.meaning.isEmpty)
    }
    // The two WP13 P4 entries read as their ⌘ forms, which is the whole point of publishing
    // them: the sheet is where a reader discovers the Command equivalents.
    let zoom = ShortcutHelpModel.rows.first { $0.id == ShortcutID.zoomStep.rawValue }
    #expect(zoom?.key == "⌘1 … ⌘6")
    let scene = ShortcutHelpModel.rows.first { $0.id == ShortcutID.sceneToggle.rawValue }
    #expect(scene?.key == "⌘⇧G")
    let help = ShortcutHelpModel.rows.first { $0.id == ShortcutID.help.rawValue }
    #expect(help?.key == "? or ⌘/")
  }
}
