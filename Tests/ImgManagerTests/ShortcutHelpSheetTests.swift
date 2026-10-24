import Testing

@testable import ImgManager

/// WP13 P4 (IMGMGR-215): the `?` surface's MODEL. These assertions are about the row list the
/// sheet is built from — they are deliberately NOT the sheet's own verification, because a
/// model-against-its-own-source test stays green with an empty `List` body (diff-gate r1
/// blocker 3). The RENDERED sheet is asserted in
/// `ViewOptionsScreenshotUITests.testShortcutHelpSheetListsEveryActiveShortcut`, which opens it
/// on both destinations and matches the real rows by the identifiers pinned below.
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
    let group = ShortcutHelpModel.rows.first { $0.id == ShortcutID.groupMode.rawValue }
    #expect(group?.key == "⌃⌘1 · ⌃⌘2")
    // IMGMGR-495: the sheet lists ⌘0 — generated from the catalog, so this is its row, not a copy.
    let viewerZoom = ShortcutHelpModel.rows.first { $0.id == ShortcutID.viewerZoomToggle.rawValue }
    #expect(viewerZoom?.key == "⌘0")
    #expect(viewerZoom?.meaning == ShortcutID.viewerZoomToggle.meaning)
    #expect(viewerZoom?.accessibilityID == "shortcutHelpRow.viewerZoomToggle")
    // IMGMGR-542 (R3-22): Esc has no menu row, so the sheet is where a reader finds it.
    let closeBand = ShortcutHelpModel.rows.first { $0.id == ShortcutID.closeBand.rawValue }
    #expect(closeBand?.key == "Esc")
    #expect(closeBand?.meaning == "Close the scene band opened last, or cancel Looks")
    #expect(closeBand?.accessibilityID == "shortcutHelpRow.closeBand")
  }

  @Test("Every row carries the ASCII identifier the rendered sheet is addressed by")
  func everyRowCarriesItsRenderedIdentifier() {
    // The UI test can only see the sheet through these — it has no access to the catalog. So
    // the identifier scheme itself is pinned here, in the same place the rows are built: the UI
    // test harvests every element whose identifier carries this prefix and counts them against
    // the active-entry count the sheet's header publishes. Model == catalog (the test above),
    // identifiers unique and schematic (here), rendered count == published count (there).
    let rows = ShortcutHelpModel.rows
    let expected = ShortcutCatalog.activeEntries.map {
      "shortcutHelpRow.\($0.id.accessibilityToken)"
    }
    #expect(rows.map(\.accessibilityID) == expected)
    #expect(Set(rows.map(\.accessibilityID)).count == rows.count)
    // ASCII, because an identifier full of ⌘/⇧ glyphs is a poor handle for an XCTest predicate.
    // Closure form, never `allSatisfy(\.isASCII)`: inside `#expect` the macro re-emits the
    // predicate as a generic function value and a key path passed to a `rethrows` call there
    // is treated as throwing (the same trap `ShortcutCatalogTests` already documents).
    #expect(rows.allSatisfy { row in row.accessibilityID.allSatisfy { $0.isASCII } })
    #expect(rows.contains { $0.accessibilityID == "shortcutHelpRow.groupMode" })
  }
}
