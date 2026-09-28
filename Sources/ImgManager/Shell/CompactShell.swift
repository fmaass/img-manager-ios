import SwiftUI

/// WP28 P1 (IMGMGR-448): the Compact shell (p4128 D3) — three tabs, Shoots · Library · Search,
/// with search in the tab bar, rendered only when `layoutMode == .compact`.
///
/// System components only (ADR-N1): `TabView` + `Tab`, a `.search`-role tab whose own stack
/// carries `.searchable` (the system's bottom-search composition), `.badge` and
/// `.tabBarMinimizeBehavior`. Nothing here draws glass of its own.
///
/// Each tab is a `NavigationStack` over `WorkspaceNavigation`'s path for that tab, and its ONLY
/// destination is the shared workspace — rendered solely in the tab `WorkspaceNavigation` names
/// as the grid host, so the one `GridStore` is never on screen under two stacks at once.
///
/// Generic over its roots so `RootView` keeps owning every store, closure and toolbar item they
/// need; this type owns only the arrangement.
struct CompactShell<Shoots: View, Library: View, SearchRoot: View, Destination: View>: View {
  @Bindable var navigation: WorkspaceNavigation
  @Bindable var search: FolderSearchModel
  /// `CompactTab.badgeCount(summaries:)` — 0 renders no badge.
  let badgeCount: Int
  /// A Back out of the grid in the hosting tab.
  let onHostPopped: () -> Void
  let shoots: Shoots
  let library: Library
  let searchRoot: SearchRoot
  let destination: Destination

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
      Tab(value: CompactTab.search, role: .search) {
        // On the Search tab's own stack, never the `TabView`: applied there, the system also drew
        // the field in the Shoots and Library navigation bars, where it filtered nothing (D3).
        stack(for: .search, root: searchRoot)
          .searchable(text: $search.text, prompt: "Search folders")
      } label: {
        tabLabel(.search)
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
        .navigationDestination(for: WorkspaceRoute.self) { _ in
          if navigation.gridHost == tab {
            destination
          }
        }
    }
  }

  private func path(for tab: CompactTab) -> Binding<[WorkspaceRoute]> {
    let navigation = self.navigation
    let onHostPopped = self.onHostPopped
    return Binding(
      get: { navigation.path(for: tab) },
      set: { newPath in
        let wasHost = navigation.gridHost == tab
        navigation.setPath(newPath, for: tab)
        if wasHost, newPath.isEmpty { onHostPopped() }
      })
  }
}
