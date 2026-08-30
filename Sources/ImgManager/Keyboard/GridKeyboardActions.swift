import SwiftUI

/// The P4-active shortcut targets (`ShortcutCatalog`'s `.p4`-owned entries whose
/// `hasChromeSurface` is now `true`), published as a `FocusedSceneValue` so `AppCommands` — a
/// scene-level `Commands` builder with no direct view-state access — can reach the one
/// `GridStore` instance the workspace composed, without either type needing to know about the
/// other's construction.
struct GridKeyboardActions {
  var moveFocus: (GridArrowDirection) -> Void
  /// P5: Space/Enter opens the loupe on the focused image — ONE catalog entry
  /// (`ShortcutID.openSpaceEnter`), dispatched from two separate `AppCommands` key bindings.
  var open: () -> Void
  var pick: (_ shiftHeld: Bool) -> Void
  var dislike: (_ shiftHeld: Bool) -> Void
  /// P5: U — Clear, active in the grid AND the loupe (this closure fires regardless of which
  /// screen is on top; see `GridStore.handleClearShortcut`'s own doc comment).
  var clear: (_ shiftHeld: Bool) -> Void
  var tag: () -> Void
  var undo: () -> Void
  /// WP13 P4 (IMGMGR-215): the View menu's six zoom steps (⌘1…⌘6). Same `GridStore.setRowHeight`
  /// the Group/Zoom chrome control calls, so the menu-bar entry and the on-screen menu cannot
  /// diverge.
  var setRowHeight: (GridRowHeight) -> Void
  /// WP13 P4: the View menu's Group single-select pair. Scene is a MODE, not a `group_by` wire
  /// value (ADR-0005 decision 6).
  var setDisplayMode: (GridDisplayMode) -> Void
  /// WP13 P4: Scene view on/off (⌘⇧G) — the accelerator form of the pair above.
  var toggleSceneMode: () -> Void
  /// WP13 P4: `?` and ⌘/ both open the shortcut help sheet, the surface that finally makes
  /// `ShortcutID.help` active (`ShortcutCatalog.swift`).
  var showShortcutHelp: () -> Void
}

private struct GridKeyboardActionsKey: FocusedValueKey {
  typealias Value = GridKeyboardActions
}

extension FocusedValues {
  var gridKeyboardActions: GridKeyboardActions? {
    get { self[GridKeyboardActionsKey.self] }
    set { self[GridKeyboardActionsKey.self] = newValue }
  }
}

extension GridStore {
  /// Built once by `RootView` and handed to `.focusedSceneValue` — the closures capture `self`
  /// (the one `GridStore`) and translate each catalog entry into the async call it already
  /// exposes for the equivalent on-screen control, so a shortcut and its button do the exact
  /// same thing.
  var keyboardActions: GridKeyboardActions {
    GridKeyboardActions(
      moveFocus: { [self] direction in moveFocus(direction) },
      open: { [self] in handleOpenShortcut() },
      pick: { [self] shiftHeld in Task { await handlePickShortcut(shiftHeld: shiftHeld) } },
      dislike: { [self] shiftHeld in Task { await handleDislikeShortcut(shiftHeld: shiftHeld) } },
      clear: { [self] shiftHeld in Task { await handleClearShortcut(shiftHeld: shiftHeld) } },
      tag: { [self] in handleTagShortcut() },
      undo: { [self] in Task { await handleUndoShortcut() } },
      setRowHeight: { [self] step in setRowHeight(step) },
      setDisplayMode: { [self] mode in Task { await setDisplayMode(mode) } },
      // On/off, read off the store's OWN current mode rather than a copy the menu holds — the
      // focused value is a snapshot, and a stale copy would flip the wrong way after a change
      // made from the Group control.
      toggleSceneMode: { [self] in
        Task { await setDisplayMode(displayMode == .scene ? .flat : .scene) }
      },
      showShortcutHelp: { [self] in showShortcutHelp() }
    )
  }
}
