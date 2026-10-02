import SwiftUI

/// IMGMGR-495 (owner ruling, comment 10230): "⌘0 alone toggles Fit/100% in the loupe and in
/// Compare". The menu bar's ⌘0 entry dispatches into THIS value, published as a focused SCENE
/// value by whichever of the two viewers is mounted — `LoupeView` or `CompareView`, which the
/// docked detail container and the Compact cover make mutually exclusive — and by nothing else.
///
/// It is deliberately NOT a member of `GridKeyboardActions`: the scene publishes that value as
/// nil while Compare is open (WP30 P3 plan decision 7, `CompareKeyboardIsolation`), which must
/// keep disabling every grid and loupe key there, while ⌘0 is the one key the owner wants live in
/// Compare. A separate value lets each entry be enabled by exactly the surface it acts on: the
/// grid keys by the grid's actions, ⌘0 by a mounted viewer, and the ⌘0 entry is disabled on the
/// bare grid because nothing publishes this value there.
///
/// `toggle` is each viewer's OWN zoom action, never a second target value: the loupe hands in
/// `LoupeZoomState.toggle()` (its double-tap's), Compare hands in `CompareZoomSync.toggleAll()`
/// (its double-tap's synced semantics, both panes).
struct ViewerZoomCommand {
  var toggle: () -> Void
}

private struct ViewerZoomCommandKey: FocusedValueKey {
  typealias Value = ViewerZoomCommand
}

extension FocusedValues {
  var viewerZoomCommand: ViewerZoomCommand? {
    get { self[ViewerZoomCommandKey.self] }
    set { self[ViewerZoomCommandKey.self] = newValue }
  }
}
