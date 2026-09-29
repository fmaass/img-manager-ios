import SwiftUI

/// One entry of the grid's More menu, declared AS DATA — the same discipline
/// `MenuCommandDeclaration` already applies to the menu-bar commands, and for the same reason:
/// the menu body renders exactly this table and holds no second, hand-written list, so
/// "the menu shows the decided set and every entry does something" is a TEST rather than a
/// comment. Deleting an entry means deleting a row here, and `GridMoreMenuTests` reads these
/// rows and invokes each row's own closure.
struct GridMoreMenuEntry: Identifiable, Sendable {
  /// What activating the entry offers: a command, a persisted on/off, or a scene window. WP29 P2
  /// (IMGMGR-453) removed the row-height list with the Density row; thumbnail size lives in the
  /// Arrange popover (`ArrangeModel`).
  enum Surface: Sendable {
    case action(@MainActor @Sendable (GridStore) -> Void)
    case toggle(
      isOn: @MainActor @Sendable (GridStore) -> Bool,
      set: @MainActor @Sendable (GridStore, Bool) -> Void)
    /// WP13 P11 (IMGMGR-220): the one entry whose action needs a capability the STORE cannot
    /// hold — SwiftUI's scene-level `openWindow`. It therefore takes the injected
    /// `ShootWindowOpener` alongside the store, which is also what lets a test substitute a spy
    /// and prove the enabled control actually fires rather than being a no-op.
    case sceneWindow(@MainActor @Sendable (GridStore, ShootWindowOpener) -> Void)
  }

  /// Stable and unique — the menu `ForEach`'s identity. Never an index (IMGMGR-210).
  let id: String
  /// What XCUITest resolves this row by, at rest.
  let accessibilityIdentifier: String
  /// The identifier this row takes INSTEAD when the action bar folds Clear into the More menu
  /// (`ActionBarLayout.foldsClearIntoMore`, WP13 P1). Only the Clear row has one: folded, that
  /// row IS the bar's Clear control, so it answers to `ActionBarMarkControl.clear`'s identifier
  /// and P1's tests find exactly one of it. Nil everywhere else.
  let foldedAccessibilityIdentifier: String?
  let systemImage: String
  let title: @MainActor @Sendable (GridStore) -> String
  let isEnabled: @MainActor @Sendable (GridStore) -> Bool
  let surface: Surface
}

/// One labelled run of the More menu. WP16 P4 (IMGMGR-297, p3332 decision 3 — "the Lightroom
/// overflow-menu grouping applied to the existing decided entry set: organization only, no new
/// entries").
///
/// Sections are the menu's SINGLE inventory: `GridMoreMenu.entries` is DERIVED from them, so a
/// grouping cannot drift from the set it groups — there is no second list to drift from. The
/// partition is CONTIGUOUS over that one order — since WP29 P3 (IMGMGR-454),
/// View · Actions · Shoot.
struct GridMoreMenuSection: Identifiable, Sendable {
  /// Stable and unique — the menu `ForEach`'s identity. Never an index (IMGMGR-210).
  let id: String
  /// The words the group reads under. Never empty: a `Section` with no title is grouping WITHOUT
  /// labels, which is a DECLARED DEVIATION from decision 3 rather than something that may ship
  /// quietly, and `GridMoreMenuSectionsTests` fails on one.
  let title: String
  let entries: [GridMoreMenuEntry]
}

/// WP13 P5a (IMGMGR-221): the More menu's decided set — **Select · Clear mark ·
/// Copy for Lightroom · Filename plates · Density · Status** (owner decision 2, 2026-08-30
/// kickoff, epic comment 2106). Select moved to the grid's bar in WP29 P1; Density moved to the
/// Arrange popover's thumbnail sizes in WP29 P2 (IMGMGR-453), which also gave Hide mirrored
/// archive its one home in the tree's View menu.
///
/// **"Download…" is deliberately absent** (owner decision 3): downloads stay loupe-Share-only
/// natively, bulk/zip stays on the web. `ShareControls.swift` remains the app's one export
/// surface.
///
/// Every entry here has a working native surface. There is no placeholder row, and
/// `GridMoreMenuTests.everyEntryDoesSomethingObservable` invokes each entry's own closure and
/// requires an observable effect — so a deleted entry and a no-oped entry both turn it RED.
enum GridMoreMenu {

  /// WP16 P4 (IMGMGR-297): the labelled groups — three since WP29 P4 (IMGMGR-455) moved the
  /// Scene group to the Select bar's Scene ▸ — and the menu's ONE inventory. Every row carries
  /// an SF Symbol through the system `Label` (WP29 P3, IMGMGR-454).
  ///
  /// WP13 P11 (IMGMGR-220) APPENDED "Open in New Window"; it did not reorder the owner's decided
  /// set. WP14 P4 (IMGMGR-277) APPENDED the three scene-edit actions, in the plan's own order —
  /// Merge into…, Split here, Extract selected. They were appended for the same reason P11's row
  /// was: the owner's decided set and its order are untouched, and a topology action is chrome by
  /// decision ("no new gestures", plan Decision 2).
  ///
  /// Each section is a CONTIGUOUS run of `entries`, which is these sections flattened — the one
  /// order, asserted element-wise by `GridMoreMenuSectionsTests`. WP29 P3 (IMGMGR-454, ticket
  /// scope + owner decision D-a) deliberately REORDERED the six rows into the ticket's shape:
  /// View · Actions · Shoot. Same six rows, same identifiers, same fold rule.
  static let sections: [GridMoreMenuSection] = [
    GridMoreMenuSection(
      id: "more.section.view", title: "View",
      // WP29 P2 (IMGMGR-453): Density left for the Arrange popover's thumbnail sizes, and Hide
      // mirrored archive left for its one home, the tree's View menu (`RootView`), which renders
      // the same static `pruneMirroredArchive` entry. 12 → 10 rows.
      entries: [filenamePlates, picksInGroups]),
    GridMoreMenuSection(
      id: "more.section.actions", title: "Actions",
      // WP29 P1 (IMGMGR-452): Select left this run for the grid's bar (`GridSelectCommand`),
      // 13 → 12 rows. WP29 P3 (IMGMGR-454): Clear mark STAYS — folded, this row is the bar's
      // only Clear (`ActionBarLayout.foldsClearIntoMore`) — and Open in New Window joins it.
      entries: [clearMark, copyForLightroom, openInNewWindow]),
    GridMoreMenuSection(
      id: "more.section.shoot", title: "Shoot",
      entries: [status]),
    // WP29 P4 (IMGMGR-455): the Scene section (Merge into…, Split here, Extract selected, Add to
    // scene…) left for its one touch home, the Select bar's Scene ▸ (`SelectBarSceneMenu`), which
    // now holds those four declarations. 10 → 6 rows in 3 groups.
  ]

  /// DERIVED, never declared: the menu has one inventory and this is a view onto it. Every
  /// existing reader (`GridMoreMenuContent`, `GridMoreMenuTests`, `ScenePicksInGroupsTests`,
  /// `ShootSceneValueTests`) keeps working because the shape and the order are unchanged.
  static let entries: [GridMoreMenuEntry] = sections.flatMap(\.entries)

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
    accessibilityIdentifier: "gridMoreMenu.more.clearMark",
    // Folded, this row IS the bar's Clear control — same identifier, same state source, same
    // disabled rule. So there is never a SECOND Clear beside it, and P1's UI tests
    // (`SelectModeScreenshotUITests`) find `gridClearButton` in the menu exactly when the bar
    // gave it up.
    foldedAccessibilityIdentifier: ActionBarMarkControl.clear.accessibilityIdentifier,
    systemImage: ActionBarMarkControl.clear.systemImage,
    title: { _ in "Clear mark" },
    isEnabled: { !$0.isMarkActionUnavailable },
    surface: .action { store in
      Task { await store.applyMarkToTarget(ActionBarMarkControl.clear.state) }
    })

  static let copyForLightroom = GridMoreMenuEntry(
    id: "more.copyForLightroom",
    accessibilityIdentifier: "gridMoreMenu.more.copyForLightroom",
    foldedAccessibilityIdentifier: nil,
    systemImage: "doc.on.clipboard",
    title: { _ in "Copy for Lightroom" },
    isEnabled: { !$0.isCopyingMarksForLightroom },
    surface: .action { store in
      Task { await store.copyMarkedFilenamesForLightroom() }
    })

  /// The filename UNDER each tile — never a path (p3220 §4.5). Persisted through
  /// `GridPreferences`, this app's first scalar preference.
  static let filenamePlates = GridMoreMenuEntry(
    id: "more.filenamePlates",
    accessibilityIdentifier: "gridMoreMenu.more.filenamePlates",
    foldedAccessibilityIdentifier: nil,
    systemImage: "textformat",
    title: { _ in "Filename plates" },
    isEnabled: { _ in true },
    surface: .toggle(
      isOn: { $0.preferences.filenamePlates },
      set: { store, isOn in store.preferences.filenamePlates = isOn }))

  /// IMGMGR-261: the picks inside a COLLAPSED scene, shown in the card. Beside Filename plates
  /// because it is the same kind of switch — "draw one more fact on every cell" — and in THIS
  /// menu because the native app already has a view-options surface; the web sibling's settings
  /// panel exists only because the web does not (covered-differently, not divergence).
  static let picksInGroups = GridMoreMenuEntry(
    id: "more.picksInGroups",
    accessibilityIdentifier: "gridMoreMenu.more.picksInGroups",
    foldedAccessibilityIdentifier: nil,
    systemImage: "checkmark.square",
    title: { _ in "Picks in groups" },
    isEnabled: { _ in true },
    surface: .toggle(
      isOn: { $0.preferences.picksInGroups },
      set: { store, isOn in store.preferences.picksInGroups = isOn }))

  /// IMGMGR-362 (WP21 P3): hide the archive folders the incoming library already holds.
  ///
  /// Beside Filename plates and Picks in groups because it is the same kind of switch — "change
  /// what the browse surfaces draw" — and in THIS menu because the native app already has a
  /// view-options surface (the web sibling puts its twin next to the tier row instead; that is
  /// covered-differently, not divergence).
  ///
  /// WP29 P2 (IMGMGR-453): no longer a More row. Its one home is the tree's View menu
  /// (`RootView.folderTreeViewMenuItem`), which renders THIS value — the switch is about the tree,
  /// and the tree's own surface is where it belongs. The entry stays declared here so the row
  /// keeps its identifier, title and binding onto the one `GridPreferences` key.
  static let pruneMirroredArchive = GridMoreMenuEntry(
    id: "more.pruneMirroredArchive",
    accessibilityIdentifier: "gridMoreMenu.more.pruneMirroredArchive",
    foldedAccessibilityIdentifier: nil,
    systemImage: "eye.slash",
    title: { _ in "Hide mirrored archive" },
    isEnabled: { _ in true },
    surface: .toggle(
      isOn: { $0.preferences.pruneMirroredArchive },
      set: { store, isOn in store.preferences.pruneMirroredArchive = isOn }))

  /// READ ONLY (`StatusSheet`): maintenance state, last indexed, store health, coverage, recent
  /// runs. `POST /api/reindex` is in the vendored spec and stays unwired (plan invariant viii).
  /// The identifier a row renders with at this fold state — a pure function, so
  /// "folded shows exactly one Clear, unfolded shows none" is a unit test rather than a
  /// screenshot.
  static func accessibilityIdentifier(
    for entry: GridMoreMenuEntry, foldsClearIntoMore: Bool
  ) -> String {
    guard foldsClearIntoMore, let folded = entry.foldedAccessibilityIdentifier else {
      return entry.accessibilityIdentifier
    }
    return folded
  }

  static let status = GridMoreMenuEntry(
    id: "more.status",
    accessibilityIdentifier: "gridMoreMenu.more.status",
    foldedAccessibilityIdentifier: nil,
    systemImage: "info.circle",
    title: { _ in "Status" },
    isEnabled: { _ in true },
    surface: .action { store in store.presentStatus() })

  /// WP13 P11 (IMGMGR-220): "the second shoot beside the first" — the OS window arrangement, as
  /// a chrome menu item and never a gesture. It ships UNCONDITIONALLY: the capability
  /// (`UIApplicationSupportsMultipleScenes` in the built product) and the entry point are
  /// independent facts, and the audit's D6 row records BOTH as missing, so the affordance lands
  /// whatever the manifest already said.
  ///
  /// Enablement and constructibility are ONE predicate by construction —
  /// `ShootSceneValue.from(query:)` decides both, so "the control is enabled" and "the scene
  /// value exists" cannot drift apart. There is no second `folderID != nil` check anywhere in
  /// this lane, and no defaulted or force-unwrapped tier.
  static let openInNewWindow = GridMoreMenuEntry(
    id: "more.openInNewWindow",
    accessibilityIdentifier: "gridMoreMenu.more.openInNewWindow",
    foldedAccessibilityIdentifier: nil,
    systemImage: "macwindow.badge.plus",
    title: { _ in ShootWindowCopy.title },
    isEnabled: { ShootSceneValue.from(query: $0.query) != nil },
    surface: .sceneWindow { store, opener in
      // The SAME function the enabled state is derived from, handed to the SAME opening path the
      // menu-bar twin uses (WP16 P4 / IMGMGR-297 B8) — never a second check, never a second call
      // site, never a force-unwrap. `ShootWindowAction.open` owns the guard, so a disabled row
      // that somehow fired is a no-op rather than a trap.
      let value = ShootSceneValue.from(query: store.query)
      ShootWindowAction.open(value, using: opener)
    })
}

/// The menu's rendered body: EXACTLY `GridMoreMenu.sections`, in order, with no second list —
/// and therefore exactly `GridMoreMenu.entries`, which is those sections flattened.
struct GridMoreMenuContent: View {
  let store: GridStore
  /// From `ActionBarLayout.foldsClearIntoMore` (WP13 P1) — the ONE thing about the menu that
  /// varies with the bar's width, and it changes an identifier, never the set of rows.
  let foldsClearIntoMore: Bool
  /// WP13 P11: handed down from `GridView`, which is the deepest view that can see the scene's
  /// own `openWindow` environment action. Injected rather than reached for so a test can prove
  /// the enabled control fires with the current scene value.
  let openShootWindow: ShootWindowOpener

  var body: some View {
    ForEach(GridMoreMenu.sections) { section in
      Section(section.title) {
        ForEach(section.entries) { entry in
          GridMoreMenuItem(
            entry: entry, store: store, foldsClearIntoMore: foldsClearIntoMore,
            openShootWindow: openShootWindow)
        }
      }
    }
  }
}

struct GridMoreMenuItem: View {
  let entry: GridMoreMenuEntry
  let store: GridStore
  let foldsClearIntoMore: Bool
  let openShootWindow: ShootWindowOpener

  private var identifier: String {
    GridMoreMenu.accessibilityIdentifier(for: entry, foldsClearIntoMore: foldsClearIntoMore)
  }

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
      .accessibilityIdentifier(identifier)

    case .toggle(let isOn, let set):
      Toggle(
        isOn: Binding(get: { isOn(store) }, set: { set(store, $0) })
      ) {
        Label(entry.title(store), systemImage: entry.systemImage)
      }
      .labelStyle(.titleAndIcon)
      .accessibilityIdentifier(identifier)

    case .sceneWindow(let run):
      Button {
        run(store, openShootWindow)
      } label: {
        Label(entry.title(store), systemImage: entry.systemImage)
      }
      .disabled(!entry.isEnabled(store))
      .labelStyle(.titleAndIcon)
      .accessibilityIdentifier(identifier)
    }
  }
}
