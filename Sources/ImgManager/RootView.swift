import OpenAPIRuntime
import SwiftUI

/// One layout declaration, adaptive by measured space — "so there is no 'iPhone layout'
/// that could be enlarged" (plan Goal). Grid/Inspector are still empty placeholders (P0a
/// Do-NOT, carried into P3: "no grid, inspector, compare or loupe content yet") — P4/P5
/// replace them. The sidebar/Queue area is the one exception: P3 fold item 3 requires the
/// degraded/unreachable state to actually work, so it is wired to `ConnectivityState`
/// rather than a bare placeholder.
///
/// System glass only (ADR-N1, docs/adr/ADR-N1-native-glass-boundary.md): nothing here
/// requests a custom `glassEffect` — the chrome is whatever NavigationSplitView and its
/// system materials already provide.
struct RootView: View {
  @State private var layoutMode: LayoutMode = .compact
  @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
  @State private var connectivity: ConnectivityState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  init(transport: any ClientTransport = UnauthenticatedPlaceholderClientTransport()) {
    let client = ImgManagerAPIClient.make(transport: transport)
    let service = ImgManagerAPIService(client: client)
    _connectivity = State(initialValue: ConnectivityState(service: service))
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebar
    } content: {
      contentColumn
    } detail: {
      detailColumn
    }
    .navigationSplitViewStyle(.prominentDetail)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      applyWidth(width)
    }
    .task {
      await connectivity.check()
    }
  }

  private func applyWidth(_ width: CGFloat) {
    let mode = LayoutResolver.resolve(width: width, horizontalSizeClass: horizontalSizeClass)
    guard mode != layoutMode else { return }
    layoutMode = mode
    columnVisibility = LayoutResolver.columnVisibility(for: mode)
  }

  private var sidebar: some View {
    Group {
      switch connectivity.status {
      case .checking, .connected:
        Text("Queue")
      case .unreachable:
        Text(DegradedStateCopy.notConnected)
      }
    }
    .navigationTitle("img-manager")
  }

  private var contentColumn: some View {
    Text("Grid")
  }

  private var detailColumn: some View {
    Text("Inspector")
  }
}
