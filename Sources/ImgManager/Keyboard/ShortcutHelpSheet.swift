import SwiftUI

/// One line of the shortcut help sheet. A value type so the sheet's CONTENT is testable
/// without a render host — the sheet below is a `List` over exactly these rows and carries no
/// second copy of the decision.
struct ShortcutHelpRow: Identifiable, Equatable, Sendable {
  /// The catalog entry's own raw value — stable and unique per entry, never an index
  /// (IMGMGR-210).
  let id: String
  /// What the RENDERED row is addressable by from outside the process (diff-gate r1 blocker 3:
  /// the help-sheet test asserted the model against its own source and never the rendered
  /// sheet, so an empty `List` body passed). ASCII, derived from the catalog case name —
  /// `id` is a display string of ⌘/⇧ glyphs and makes a poor identifier.
  let accessibilityID: String
  let key: String
  let meaning: String
}

/// WP13 P4 (IMGMGR-215): the `?` surface `ShortcutCatalog` has carried as PLANNED since WP8
/// P3. Rendered from `ShortcutCatalog.activeEntries` — never a hand-written list — so a
/// shortcut that is declared but not catalogued, or catalogued but not active, cannot appear
/// here, and one that IS active cannot be missing.
enum ShortcutHelpModel {
  static var rows: [ShortcutHelpRow] {
    ShortcutCatalog.activeEntries.map { entry in
      ShortcutHelpRow(
        id: entry.id.rawValue,
        accessibilityID: "shortcutHelpRow.\(entry.id.accessibilityToken)",
        key: entry.id.keyLabel,
        meaning: entry.id.meaning)
    }
  }
}

/// The sheet itself: every ACTIVE shortcut with its key and what it does. Reached from the
/// menu-bar View menu, from `?` and from ⌘/ (`AppCommands.viewMenuGroups`).
struct ShortcutHelpSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List(ShortcutHelpModel.rows) { row in
        let spokenLabel = "\(row.key), \(row.meaning)"
        HStack(alignment: .firstTextBaseline, spacing: 16) {
          Text(row.key)
            .font(.body.monospaced())
            .frame(minWidth: 110, alignment: .leading)
          Text(row.meaning)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        // The element that carries the identifier must also CARRY THE TEXT: with a merely
        // combined element the label XCTest reads back came out empty on both gate legs
        // (queue-p4-green2 run, `Rendered row shortcutHelpRow.help reads ''`), so the row
        // states its own label and value instead of relying on the synthesized one. The key
        // goes in the value as well, which is what a UI test can assert on directly.
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(row.key)
        // The rendered row's own handle. `ViewOptionsScreenshotUITests` opens this sheet on
        // BOTH destinations and asserts the rows it finds by these identifiers, so emptying
        // the `List` above turns that test RED instead of leaving a model-only test green.
        .accessibilityIdentifier(row.accessibilityID)
      }
      .navigationTitle("Keyboard shortcuts")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    // NO `.accessibilityIdentifier` on this container: an identifier set on a container
    // OVERRIDES its descendants' — observed on the iPhone 17 Pro gate leg for `GridOptionsRow`,
    // whose two controls both came back as the row's identifier and were unaddressable
    // (`GridView.swift`). The rows above are what a test needs to name; the sheet itself is
    // addressable by its navigation bar title, which is real rendered chrome either way.
  }
}
