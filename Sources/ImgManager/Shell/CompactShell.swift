import SwiftUI

/// WP28 P1 (IMGMGR-448): the Compact shell (p4128 D3) — two tabs, Shoots · Library, rendered only
/// when `layoutMode == .compact`. R3-18 (IMGMGR-550) removed the Search tab and its field.
///
/// System components only (ADR-N1): `TabView` + `Tab`, `.badge` and `.tabBarMinimizeBehavior`.
/// Nothing here draws glass of its own.
///
/// Each tab is a `NavigationStack` over `WorkspaceNavigation`'s path for that tab, and its ONLY
/// destination is the shared workspace — rendered solely in the tab `WorkspaceNavigation` names
/// as the grid host, so the one `GridStore` is never on screen under two stacks at once.
///
/// Generic over its roots so `RootView` keeps owning every store, closure and toolbar item they
/// need; this type owns only the arrangement.
struct CompactShell<Shoots: View, Library: View, Destination: View>: View {
  @Bindable var navigation: WorkspaceNavigation
  /// `CompactTab.badgeCount(summaries:since:)` — 0 renders no badge.
  let badgeCount: Int
  /// A Back out of the grid in the hosting tab.
  let onHostPopped: () -> Void
  /// WP442 P12: the grid store's entered scene (projected onto the host's stack) and the store's
  /// leave, called when a USER write removed the scene from the stack.
  var enteredSceneID: Int?
  var onScenePopped: () -> Void = {}
  let shoots: Shoots
  let library: Library
  let destination: (WorkspaceRoute) -> Destination

  var body: some View {
    TabView(selection: $navigation.activeTab) {
      Tab(value: CompactTab.shoots) {
        stack(for: .shoots, root: shoots)
      } label: {
        tabLabel(.shoots)
      }
      .badge(badgeCount)
      Tab(value: CompactTab.library) {
        stack(for: .library, root: library)
      } label: {
        tabLabel(.library)
      }
    }
    // iPhone behaviour; the system ignores it where the tab bar does not minimise.
    .tabBarMinimizeBehavior(.onScrollDown)
  }

  private func tabLabel(_ tab: CompactTab) -> some View {
    Label(tab.title, systemImage: tab.systemImage)
      .accessibilityIdentifier(tab.identifier)
  }

  private func stack(for tab: CompactTab, root: some View) -> some View {
    NavigationStack(path: path(for: tab)) {
      root
        .navigationDestination(for: WorkspaceRoute.self) { route in
          if navigation.gridHost == tab {
            destination(route)
          }
        }
    }
  }

  private func path(for tab: CompactTab) -> Binding<[WorkspaceRoute]> {
    let navigation = self.navigation
    let onHostPopped = self.onHostPopped
    let onScenePopped = self.onScenePopped
    let entered = self.enteredSceneID
    return Binding(
      get: { navigation.presentedPath(for: tab, entered: entered) },
      set: { newPath in
        let effect = navigation.applyStackWrite(newPath, for: tab, entered: entered)
        if effect.leavesScene { onScenePopped() }
        if effect.popsHost { onHostPopped() }
      })
  }
}
