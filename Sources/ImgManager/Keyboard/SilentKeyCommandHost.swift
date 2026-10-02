import SwiftUI

/// IMGMGR-463 (p4128 D10): "one row per command, the secondary key handled silently". The
/// iPadOS 26 menu bar is the shortcut discovery surface and lists each command ONCE (Open on
/// Return, Advance After Marking on ⌘⇧A, Keyboard Shortcuts on ⌘/); the command's second key —
/// Space, bare A, `?` — stays bound and is rendered HERE, by an invisible view in the scene,
/// from `AppCommands.silentDeclarations` and from nothing else.
///
/// Why a hidden SwiftUI host and not the alternatives:
/// - `Commands` has no hidden-entry form — every `Button` in `AppCommands.body` draws a menu row
///   — and SwiftUI binds one key per `Button`, so the second key cannot live in the menu.
/// - A UIKit `UIKeyCommand` with `.attributes = .hidden` would have to be added either through
///   `buildMenu(with:)`, which the SwiftUI app lifecycle's own delegate owns, or from a responder
///   of ours in the chain; and either way it could not read `@FocusedValue`, so it would need a
///   second route to the grid actions — the drift `GridKeyboardActions` exists to prevent.
/// - A `Button` with `.keyboardShortcut` is the SAME SwiftUI key binding the menu rows use (same
///   `KeyEquivalent` and `EventModifiers`, so the same text-input arbitration the bare menu keys
///   P, X, U… get), reads the SAME focused values as `AppCommands`, and is enabled and
///   dispatched by the SAME `isEnabled`/`perform` as `AppCommands.entry(_:)` — disabled exactly
///   when its menu twin is (no grid actions focused, e.g. while Compare is open).
///
/// The one difference from a menu row: a view's key binding is live while its host is in the
/// responder chain, not whenever the scene is key. So the host is mounted on the workspace AND
/// inside each Compact full-screen cover (the loupe, Triage), the surfaces that take the
/// workspace's place; a sheet over them is a modal of its own, where a bare key reaching the
/// grid underneath was never the point. If the chain does reach the workspace's host from a
/// cover as well, UIKit still performs one key command per key press.
struct SilentKeyCommandHost: View {
  @FocusedValue(\.gridKeyboardActions) private var actions
  @FocusedValue(\.viewerZoomCommand) private var viewerZoom

  var body: some View {
    // Copied into locals so each Button's action reads the values this render saw, the same
    // values `isEnabled` decided on — `AppCommands.entry(_:)`'s own discipline.
    let grid = actions
    let zoom = viewerZoom
    ZStack {
      ForEach(AppCommands.silentDeclarations) { item in
        if let key = item.key {
          Button(item.title) {
            item.perform(grid: grid, viewerZoom: zoom)
          }
          .disabled(!item.isEnabled(grid: grid, viewerZoom: zoom))
          .keyboardShortcut(key, modifiers: item.modifiers)
        }
      }
    }
    // Drawn nowhere and reachable by nothing but its keys: no pixels, no taps, and no element in
    // the accessibility tree (so neither VoiceOver nor a UI test's chrome census counts it).
    .opacity(0)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
