import SwiftUI

/// One entry of the grid's More menu, declared AS DATA — the same discipline
/// `MenuCommandDeclaration` already applies to the menu-bar commands, and for the same reason:
/// the menu body renders exactly this table and holds no second, hand-written list, so
/// "the menu shows the decided set and every entry does something" is a TEST rather than a
/// comment. Deleting an entry means deleting a row here, and `GridMoreMenuTests` reads these
/// rows and invokes each row's own closure.
struct GridMoreMenuEntry: Identifiable, Sendable {
  /// What activating the entry offers. Three shapes, because the decided set has three: a
  /// command, a persisted on/off, and a single-select list of the grid's row-height steps.
  enum Surface: Sendable {
    case action(@MainActor @Sendable (GridStore) -> Void)
    case toggle(
      isOn: @MainActor @Sendable (GridStore) -> Bool,
      set: @MainActor @Sendable (GridStore, Bool) -> Void)
    /// Density. NOT a second property — see `GridMoreMenu.density`.
    case rowHeightSteps(
      set: @MainActor @Sendable (GridStore, GridRowHeight) -> Void,
      isCurrent: @MainActor @Sendable (GridStore, GridRowHeight) -> Bool)
  }

  /// Stable and unique — the menu `ForEach`'s identity. Never an index (IMGMGR-210).
  let id: String
  let systemImage: String
  let title: @MainActor @Sendable (GridStore) -> String
  let isEnabled: @MainActor @Sendable (GridStore) -> Bool
  let surface: Surface
}

/// WP13 P5a (IMGMGR-221): the More menu's decided set — **Select · Clear mark ·
/// Copy for Lightroom · Filename plates · Density · Status** (owner decision 2, 2026-08-30
/// kickoff, epic comment 2106).
///
/// **"Download…" is deliberately absent** (owner decision 3): downloads stay loupe-Share-only
/// natively, bulk/zip stays on the web. `ShareControls.swift` remains the app's one export
/// surface.
///
/// Every entry here has a working native surface. There is no placeholder row, and
/// `GridMoreMenuTests.everyEntryDoesSomethingObservable` invokes each entry's own closure and
/// requires an observable effect — so a deleted entry and a no-oped entry both turn it RED.
enum GridMoreMenu {

  static let entries: [GridMoreMenuEntry] = [
    select, clearMark, copyForLightroom, filenamePlates, density, status,
  ]

  /// Already shipped as the menu's one item; unchanged, and now declared beside its five
  /// siblings rather than written inline in `ActionBarView`.
  static let select = GridMoreMenuEntry(
    id: "more.select",
    systemImage: "checkmark.circle",
    title: { $0.selection.mode == .select ? "Exit Select" : "Select" },
    isEnabled: { _ in true },
    surface: .action { _ in })  // RED stub — see the commit message

  /// A SECOND ENTRY POINT to the store's one clear action, never a second implementation: the
  /// menu entry, the `U` key equivalent and the View menu's Clear all dispatch into
  /// `GridStore.handleClearShortcut`, which owns the target rule. WP13 P1 (IMGMGR-212) widens
  /// that rule from the focused photograph to `markTargetImageIDs` (the selection in Select
  /// mode) inside that same method — so this entry inherits bulk clearing at P1's merge with
  /// no change here, and this phase adds no copy of the rule that could drift from it.
  ///
  /// `shiftHeld: false` because a menu carries no modifier state; "clear and advance" is the
  /// keyboard's affordance (⇧U), not a menu row.
  static let clearMark = GridMoreMenuEntry(
    id: "more.clearMark",
    systemImage: "minus.circle",
    title: { _ in "Clear mark" },
    isEnabled: { !$0.tagTargetImageIDs.isEmpty },
    surface: .action { _ in })  // RED stub

  static let copyForLightroom = GridMoreMenuEntry(
    id: "more.copyForLightroom",
    systemImage: "doc.on.clipboard",
    title: { _ in "Copy for Lightroom" },
    isEnabled: { !$0.isCopyingMarksForLightroom },
    surface: .action { _ in })  // RED stub

  /// The filename UNDER each tile — never a path (p3220 §4.5). Persisted through
  /// `GridPreferences`, this app's first scalar preference.
  static let filenamePlates = GridMoreMenuEntry(
    id: "more.filenamePlates",
    systemImage: "textformat",
    title: { _ in "Filename plates" },
    isEnabled: { _ in true },
    surface: .toggle(
      isOn: { $0.preferences.filenamePlates },
      set: { _, _ in }))  // RED stub

  /// DENSITY, mapped onto the grid's EXISTING six row-height steps (`GridRowHeight`) rather
  /// than a second persisted property. The native grid already has six measured zoom steps
  /// which are exactly what the web's density control approximates on a phone; a second density
  /// knob would give one visual property two owners that can disagree. One state, two entry
  /// points — this menu and `GridZoomControl` (and ⌘1…⌘6), all calling `GridStore.setRowHeight`.
  ///
  /// This is a deliberate DEVIATION from the literal decided list (plan §P5a Approach) and is
  /// flagged for the owner to overrule; the warrant is "companion value through native
  /// capability, never web parity" (IMGMGR-114 comment 1949) plus the duplicated-functionality
  /// rule. `GridMoreMenuTests` asserts `GridPreferences.persistedKeys` holds no density key, so
  /// a future second property fails the gate rather than shipping quietly.
  static let density = GridMoreMenuEntry(
    id: "more.density",
    systemImage: "square.grid.2x2",
    title: { "Density: \(Int($0.rowHeight.rawValue)) pt" },
    isEnabled: { _ in true },
    surface: .rowHeightSteps(
      set: { _, _ in },  // RED stub
      isCurrent: { store, step in store.rowHeight == step }))

  /// READ ONLY (`StatusSheet`): maintenance state, last indexed, store health, coverage, recent
  /// runs. `POST /api/reindex` is in the vendored spec and stays unwired (plan invariant viii).
  static let status = GridMoreMenuEntry(
    id: "more.status",
    systemImage: "info.circle",
    title: { _ in "Status" },
    isEnabled: { _ in true },
    surface: .action { _ in })  // RED stub
}

/// The menu's rendered body: EXACTLY `GridMoreMenu.entries`, in order, with no second list.
struct GridMoreMenuContent: View {
  let store: GridStore

  var body: some View {
    ForEach(GridMoreMenu.entries) { entry in
      GridMoreMenuItem(entry: entry, store: store)
    }
  }
}

struct GridMoreMenuItem: View {
  let entry: GridMoreMenuEntry
  let store: GridStore

  var body: some View {
    switch entry.surface {
    case .action(let run):
      Button {
        run(store)
      } label: {
        Label(entry.title(store), systemImage: entry.systemImage)
      }
      .disabled(!entry.isEnabled(store))
      .labelStyle(.titleAndIcon)
      .accessibilityIdentifier("gridMoreMenu.\(entry.id)")

    case .toggle(let isOn, let set):
      Toggle(
        isOn: Binding(get: { isOn(store) }, set: { set(store, $0) })
      ) {
        Label(entry.title(store), systemImage: entry.systemImage)
      }
      .labelStyle(.titleAndIcon)
      .accessibilityIdentifier("gridMoreMenu.\(entry.id)")

    case .rowHeightSteps(let set, let isCurrent):
      Menu {
        // Identified by the STEP, never by its position (IMGMGR-210) — the same identity
        // `GridZoomControl` uses over the same six cases.
        ForEach(GridRowHeight.allCases, id: \.self) { step in
          Button {
            set(store, step)
          } label: {
            if isCurrent(store, step) {
              Label("\(Int(step.rawValue)) pt", systemImage: "checkmark")
            } else {
              Text("\(Int(step.rawValue)) pt")
            }
          }
        }
      } label: {
        Label(entry.title(store), systemImage: entry.systemImage)
      }
      .labelStyle(.titleAndIcon)
      .accessibilityIdentifier("gridMoreMenu.\(entry.id)")
    }
  }
}
