import SwiftUI

/// The value a SECOND window is opened FOR: one shoot, in the scope the window that asked was
/// looking at. WP13 P11 (IMGMGR-220).
///
/// `Codable, Hashable` because that is exactly what SwiftUI's `WindowGroup(for:)` and
/// `openWindow(value:)` require — the system persists it across a scene restore and uses it as
/// the window's identity, so two "open" requests for the same shoot reuse one window instead of
/// stacking duplicates.
///
/// **The tier is OPTIONAL, end to end, and a `nil` tier stays `nil`.** It mirrors the stored scope
/// exactly (`GridImagesQuery.sourceTier: GridSourceTier?`) and the destination it feeds
/// (`GridStore.selectShoot(folderID:sourceTier:)`, whose tier defaults to `nil`). Decisively, the
/// queue — the app's launch surface and its most common navigation — ALWAYS produces a nil tier
/// (`QueueCardDestination.route(for:)` returns `(summary.folderId, nil)`), so a non-optional tier
/// would make this value unconstructible from the ordinary selected scope without inventing one,
/// and an invented tier silently re-scopes the second window to a tier the first was never on.
struct ShootSceneValue: Codable, Hashable, Sendable {
  let folderID: Int
  let sourceTier: GridSourceTier?

  /// Constructibility as a PURE FUNCTION, and it is also the "Open in New Window" control's
  /// enablement condition — one predicate, not two. It returns `nil` exactly when the query has
  /// no shoot in scope, and otherwise copies BOTH fields verbatim: no defaulting, no coercion,
  /// no force-unwrap.
  static func from(query: GridImagesQuery) -> ShootSceneValue? {
    guard let folderID = query.folderID else { return nil }
    return ShootSceneValue(folderID: folderID, sourceTier: query.sourceTier)
  }
}

/// `GridSourceTier` is a `String`-raw-value enum, so the standard library's
/// `RawRepresentable where RawValue: Codable` conformances supply both halves; the declaration
/// lives HERE rather than on the type because the scene value is the only thing that encodes it,
/// and `GridSourceTier.swift` is compiled into the widget extension too (project.yml), which has
/// no windows to restore.
extension GridSourceTier: Codable {}

/// The one-line adapter seam over SwiftUI's scene-level `openWindow` action, as a value so a test
/// can substitute a spy and prove the enabled control actually FIRES with the current scene value
/// rather than being a no-op. `openWindow` is an environment action and cannot be constructed in a
/// unit test, which is precisely why the call sites take this instead of reaching for it directly.
struct ShootWindowOpener: Sendable {
  var open: @MainActor @Sendable (ShootSceneValue) -> Void

  init(open: @escaping @MainActor @Sendable (ShootSceneValue) -> Void) {
    self.open = open
  }
}

/// A restored scene's initial shoot, applied through the SAME entry point a queue tap uses.
///
/// Pulled out of `RootView`'s `.task` as its own function for the reason every other routing
/// decision in this app is (`RootRouting`, `LayoutResolver`, `QueueCardDestination`,
/// `ForegroundRefresh`): so the test that proves a restored window lands in the identical grid
/// scope as a queue tap drives the PRODUCTION forwarding decision rather than a re-implementation
/// of it.
enum InitialShootApplication {
  /// Returns the folder id the caller should mirror into its own selection state, or `nil` when
  /// this window was opened with no shoot (the ordinary launch).
  @MainActor
  @discardableResult
  static func apply(_ shoot: ShootSceneValue?, to store: GridStore) async -> Int? {
    guard let shoot else { return nil }
    await store.selectShoot(folderID: shoot.folderID, sourceTier: shoot.sourceTier)
    return shoot.folderID
  }
}

/// The words the control uses, in ONE place: the grid's More menu and the menu bar's View menu
/// both render this string, so the two entry points cannot be spelled differently.
enum ShootWindowCopy {
  static let title = "Open in New Window"
}

/// The menu-bar twin of the More menu's entry, carried as a focused SCENE value because
/// `openWindow` is a scene capability and `AppCommands` sits outside any view hierarchy that
/// could reach the grid.
///
/// It carries the ALREADY-CONSTRUCTED scene value rather than the query, so `isEnabled` and "what
/// would this open" are one `ShootSceneValue.from(query:)` answer and not two checks that could
/// disagree — the same single-predicate rule the More-menu entry follows.
struct ShootWindowCommand {
  let value: ShootSceneValue?
  let opener: ShootWindowOpener

  var isEnabled: Bool { value != nil }

  @MainActor
  func run() {
    guard let value else { return }
    opener.open(value)
  }
}

private struct ShootWindowCommandKey: FocusedValueKey {
  typealias Value = ShootWindowCommand
}

extension FocusedValues {
  var shootWindowCommand: ShootWindowCommand? {
    get { self[ShootWindowCommandKey.self] }
    set { self[ShootWindowCommandKey.self] = newValue }
  }
}
