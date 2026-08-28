import SwiftUI

/// The P4-active shortcut targets (`ShortcutCatalog`'s `.p4`-owned entries whose
/// `hasChromeSurface` is now `true`), published as a `FocusedSceneValue` so `AppCommands` — a
/// scene-level `Commands` builder with no direct view-state access — can reach the one
/// `GridStore` instance the workspace composed, without either type needing to know about the
/// other's construction.
struct GridKeyboardActions {
  var moveFocus: (GridArrowDirection) -> Void
  var pick: (_ shiftHeld: Bool) -> Void
  var dislike: (_ shiftHeld: Bool) -> Void
  var tag: () -> Void
  var undo: () -> Void
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
      pick: { [self] shiftHeld in Task { await handlePickShortcut(shiftHeld: shiftHeld) } },
      dislike: { [self] shiftHeld in Task { await handleDislikeShortcut(shiftHeld: shiftHeld) } },
      tag: { [self] in handleTagShortcut() },
      undo: { [self] in Task { await handleUndoShortcut() } }
    )
  }
}
