import SwiftUI

/// The dispatcher/menu-bar infrastructure P3 fold item 1 requires: the scene-level
/// `Commands` builder every phase's chrome adds its `CommandGroup` into once it lands. A
/// shortcut becomes ACTIVE — declared in `commands(content:)` — only in the same commit
/// that ships its owning phase's persistent-chrome surface (`ShortcutCatalog.swift`).
///
/// WP8 P4: the grid's own chrome now exists, so P4's active entries (arrows, P, X,
/// Shift+advance, T, Z) are declared here, each dispatching through `GridKeyboardActions` —
/// the `FocusedSceneValue` `RootView` publishes over its one `GridStore` instance (this type
/// has no view-state access of its own by design; that indirection is exactly what
/// `FocusedValue` is for). Bare keys, no `⌘` modifier — decision 9's "the web set verbatim...
/// as the fast path", and `ShortcutCatalog`'s own doc comment names `commands(content:)`
/// itself as the activation mechanism, so this is the ONE place these fire from (no parallel
/// `.onKeyPress` path elsewhere that could double-fire the same key). `openSpaceEnter`,
/// `clear`, and `help` stay undeclared here — `ShortcutCatalogTests.p4ActivatesExactlyItsOwnSet`
/// is this file's own regression guard: an entry declared here that the catalog does not also
/// mark active (or vice versa) is a defect that test catches, not a silent drift.
struct AppCommands: Commands {
  @FocusedValue(\.gridKeyboardActions) private var actions

  var body: some Commands {
    CommandMenu("Grid") {
      Button("Focus Up") { actions?.moveFocus(.up) }
        .keyboardShortcut(.upArrow, modifiers: [])
        .disabled(actions == nil)
      Button("Focus Down") { actions?.moveFocus(.down) }
        .keyboardShortcut(.downArrow, modifiers: [])
        .disabled(actions == nil)
      Button("Focus Left") { actions?.moveFocus(.left) }
        .keyboardShortcut(.leftArrow, modifiers: [])
        .disabled(actions == nil)
      Button("Focus Right") { actions?.moveFocus(.right) }
        .keyboardShortcut(.rightArrow, modifiers: [])
        .disabled(actions == nil)

      Divider()

      Button("Pick") { actions?.pick(false) }
        .keyboardShortcut("p", modifiers: [])
        .disabled(actions == nil)
      Button("Pick and Advance") { actions?.pick(true) }
        .keyboardShortcut("p", modifiers: [.shift])
        .disabled(actions == nil)
      Button("Dislike") { actions?.dislike(false) }
        .keyboardShortcut("x", modifiers: [])
        .disabled(actions == nil)
      Button("Dislike and Advance") { actions?.dislike(true) }
        .keyboardShortcut("x", modifiers: [.shift])
        .disabled(actions == nil)

      Divider()

      Button("Add Tag…") { actions?.tag() }
        .keyboardShortcut("t", modifiers: [])
        .disabled(actions == nil)
      Button("Undo") { actions?.undo() }
        .keyboardShortcut("z", modifiers: [])
        .disabled(actions == nil)
    }
  }
}
