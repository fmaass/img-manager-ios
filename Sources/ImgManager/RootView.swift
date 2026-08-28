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
///
/// P1 (WP8, IMGMGR-169): the workspace only ever renders once `AuthSession.status` is
/// `.signedIn` — `RootRouting.destination(for:)` is the one place that decision is made, so
/// the routing itself is a value test, not a rendered-view test. The composition root's
/// injectable seam (`ImgManagerAPIClient.swift`'s doc comment) stays exactly one
/// `ClientTransport`; its default is now the REAL `AuthenticatedClientTransport` instead of
/// the retired `UnauthenticatedPlaceholderClientTransport`.
struct RootView: View {
  @State private var layoutMode: LayoutMode = .compact
  @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
  @State private var connectivity: ConnectivityState
  @State private var auth: AuthSession
  @State private var showAccountSheet = false
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.scenePhase) private var scenePhase

  init(
    transport: (any ClientTransport)? = nil,
    credentialStore: CredentialStore = CredentialStore()
  ) {
    let resolvedTransport =
      transport ?? AuthenticatedClientTransport(credentialStore: credentialStore)
    let client = ImgManagerAPIClient.make(transport: resolvedTransport)
    let service = ImgManagerAPIService(client: client)
    _connectivity = State(initialValue: ConnectivityState(service: service))
    _auth = State(initialValue: AuthSession(credentialStore: credentialStore, client: client))
  }

  var body: some View {
    Group {
      switch RootRouting.destination(for: auth.status) {
      case .checking:
        ProgressView()
      case .signIn:
        SignInView(auth: auth)
      case .credentialError(let message):
        CredentialErrorView(message: message, auth: auth)
      case .workspace:
        workspace
      }
    }
    .task { await auth.bootstrap() }
    .onOpenURL { url in
      NativeLoginCallbackInbox.shared.deliver(url)
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active else { return }
      Task { await auth.renewOnForeground() }
    }
  }

  private var workspace: some View {
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
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showAccountSheet = true
        } label: {
          Label("Account", systemImage: "person.crop.circle")
        }
      }
    }
    .sheet(isPresented: $showAccountSheet) {
      AccountSheetView(auth: auth)
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
