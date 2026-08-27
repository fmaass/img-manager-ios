import SwiftUI

/// One layout declaration, adaptive by measured space — "so there is no 'iPhone layout'
/// that could be enlarged" (plan Goal). Empty scaffold only (P0a Do-NOT: no product
/// screens); the sidebar/content/detail placeholders are replaced by P3–P5.
///
/// System glass only (ADR-N1, docs/adr/ADR-N1-native-glass-boundary.md): nothing here
/// requests a custom `glassEffect` — the chrome is whatever NavigationSplitView and its
/// system materials already provide.
struct RootView: View {
    @State private var layoutMode: LayoutMode = .compact
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            contentColumn
        } detail: {
            detailColumn
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            applyWidth(width)
        }
    }

    private func applyWidth(_ width: CGFloat) {
        let mode = LayoutResolver.resolve(width: width)
        guard mode != layoutMode else { return }
        layoutMode = mode
        columnVisibility = LayoutResolver.columnVisibility(for: mode)
    }

    private var sidebar: some View {
        Text("Queue")
            .navigationTitle("img-manager")
    }

    private var contentColumn: some View {
        Text("Grid")
    }

    private var detailColumn: some View {
        Text("Inspector")
    }
}
