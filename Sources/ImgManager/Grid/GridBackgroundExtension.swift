import SwiftUI

/// IMGMGR-469 (p4128 D1/D6; ADR-N1 Amendment 1, IMGMGR-470 comment 10233): at Regular width the
/// grid's photographs continue under the floating iPad sidebar. The system mirrors the scroll
/// content into the safe area the sidebar covers and blurs the copies there; the real tiles stay
/// where the layout put them, beside the sidebar.
///
/// System glass only (ADR-N1): `.backgroundExtensionEffect()` is a system modifier, not a glass
/// surface — the sidebar above it stays the system's own Regular glass, and nothing here picks a
/// variant. It is applied to the grid's scroll CONTENT and nowhere else: never to a control, a
/// chrome row or the toolbar.
enum GridBackgroundExtension {
  /// Width alone decides, from the `LayoutMode` `RootView` resolved — never the device idiom.
  /// Regular-2 and Regular-3 both float the sidebar beside the grid; Compact has no sidebar
  /// beside it to extend under.
  static func extendsUnderSidebar(for mode: LayoutMode) -> Bool {
    mode != .compact
  }
}

extension View {
  /// The grid scroll content's one background-extension call site (`GridView.scrollArea`).
  func gridBackgroundExtension(for mode: LayoutMode) -> some View {
    let extends = GridBackgroundExtension.extendsUnderSidebar(for: mode)
    return modifier(GridBackgroundExtensionModifier(extendsUnderSidebar: extends))
  }
}

private struct GridBackgroundExtensionModifier: ViewModifier {
  let extendsUnderSidebar: Bool

  // One modifier chain in both widths: an `if`/`else` here would put the whole lazy grid in two
  // structural branches, so crossing Compact <-> Regular would rebuild every tile and restart its
  // load task. `isEnabled:` switches the effect without changing the view's identity.
  func body(content: Content) -> some View {
    content.backgroundExtensionEffect(isEnabled: extendsUnderSidebar)
  }
}
