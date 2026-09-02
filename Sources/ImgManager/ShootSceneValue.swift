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

/// The ONE path a shoot window is opened by. WP16 P4 (IMGMGR-297), the plan's B8 fold.
///
/// Before this, the app's two "Open in New Window" entry points — the grid's More row and the
/// menu bar's View entry — each carried their own `guard let value … opener.open(value)`, so they
/// did not share a call path and "the menu-bar twin still fires" could only be asserted about a
/// hand-built command rather than about the shipped wiring. Both now delegate here: the guard,
/// the value and the opener call exist ONCE, and deleting this call from either site turns that
/// site's own test RED.
///
/// Nothing about what either entry point DOES changed with the extraction — the shoot opened, the
/// enablement rule and the titles are byte-identical to the behaviour that shipped in P11.
enum ShootWindowAction {
  /// Whether a window was asked for. `false` exactly when there is no shoot in scope — the same
  /// condition `ShootSceneValue.from(query:)` decides and both entry points render as their
  /// disabled state, so a disabled control that somehow fired is a no-op rather than a trap.
  @MainActor
  @discardableResult
  static func open(_ value: ShootSceneValue?, using opener: ShootWindowOpener) -> Bool {
    guard let value else { return false }
    opener.open(value)
    return true
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

  /// Routed through `ShootWindowAction.open` — the shared path the grid's More row takes — so
  /// the two entry points cannot open different things or disagree about the nil case.
  @MainActor
  func run() {
    ShootWindowAction.open(value, using: opener)
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
