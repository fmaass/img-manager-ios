import SwiftUI

/// One line of the shortcut help sheet. A value type so the sheet's CONTENT is testable
/// without a render host — the sheet below is a `List` over exactly these rows and carries no
/// second copy of the decision.
struct ShortcutHelpRow: Identifiable, Equatable, Sendable {
  /// The catalog entry's own raw value — stable and unique per entry, never an index
  /// (IMGMGR-210).
  let id: String
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
      ShortcutHelpRow(id: entry.id.rawValue, key: entry.id.keyLabel, meaning: entry.id.meaning)
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
        HStack(alignment: .firstTextBaseline, spacing: 16) {
          Text(row.key)
            .font(.body.monospaced())
            .frame(minWidth: 110, alignment: .leading)
          Text(row.meaning)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
      }
      .navigationTitle("Keyboard shortcuts")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .accessibilityIdentifier("shortcutHelpSheet")
  }
}
