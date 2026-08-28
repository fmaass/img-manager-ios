import ImgManagerAPI
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
  /// WP8 P4: the grid store and its own API boundary (`GridService`, a sibling of `ImgManagerAPIService`
  /// — see that type's doc comment for why P4 does not extend P3's).
  @State private var gridStore: GridStore
  private let gridService: GridService
  @State private var folders: [Components.Schemas.FolderNode] = []
  @State private var showInspectorSheet = false
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.scenePhase) private var scenePhase

  init(
    transport: (any ClientTransport)? = nil,
    credentialStore: CredentialStore = CredentialStore()
  ) {
    // Breaks an otherwise-circular wire: the transport needs to CALL into `AuthSession` on a
    // terminal 401 (diff-gate round 1, blocker 3), but `AuthSession` needs the CLIENT, which
    // needs the transport, to be constructed first. The box's `handler` is written exactly
    // once, synchronously, before `resolvedTransport` is ever handed a live request — nothing
    // concurrent can observe it unset.
    let unauthorizedBox = TerminalUnauthorizedBox()
    let resolvedTransport =
      transport
      ?? AuthenticatedClientTransport(
        credentialStore: credentialStore,
        onTerminalUnauthorized: { token in await unauthorizedBox.handler?(token) })
    let client = ImgManagerAPIClient.make(transport: resolvedTransport)
    let service = ImgManagerAPIService(client: client)
    _connectivity = State(initialValue: ConnectivityState(service: service))
    let gridService = GridService(client: client)
    self.gridService = gridService
    _gridStore = State(initialValue: GridStore(service: gridService))
    let session = AuthSession(credentialStore: credentialStore, client: client)
    unauthorizedBox.handler = { [weak session] token in
      await session?.handleTerminalUnauthorized(presentedToken: token)
    }
    _auth = State(initialValue: session)
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
    .focusedSceneValue(\.gridKeyboardActions, gridStore.keyboardActions)
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
      case .checking:
        ProgressView()
      case .connected:
        // Shoot navigation (P4 endpoint table: `GET /api/folders`; sufficient; never render
        // `FolderNode.path`). "Day"-kind nodes are the browsable shoot leaves (ADR-0004: shoot
        // ≡ folder) — this list intentionally shows only those, not the full tree.
        List(folders.filter { $0.kind == "day" }, id: \.id) { folder in
          Button(folder.name) {
            Task { await gridStore.selectShoot(folderID: folder.id) }
          }
        }
        .task {
          if let tree = try? await gridService.folders() {
            folders = tree.items
          }
        }
      case .unreachable:
        Text(DegradedStateCopy.notConnected)
      }
    }
    .navigationTitle("img-manager")
  }

  private var contentColumn: some View {
    GridView(store: gridStore)
      .toolbar {
        // Fold item 7: Compact (and, per this pass's simplification, Regular-2) reach the
        // inspector through a persistent chrome control presenting ONE Info/Stats sheet —
        // never a second phone-only surface.
        if layoutMode != .regular3 {
          ToolbarItem(placement: .primaryAction) {
            Button {
              showInspectorSheet = true
            } label: {
              Label("Info", systemImage: "info.circle")
            }
          }
        }
      }
      .sheet(isPresented: $showInspectorSheet) {
        InspectorView(store: gridStore, service: gridService)
      }
  }

  private var detailColumn: some View {
    Group {
      if layoutMode == .regular3 {
        InspectorView(store: gridStore, service: gridService)
      } else {
        EmptyView()
      }
    }
  }
}

/// A single settable closure, written once synchronously during `RootView.init` (see its own
/// comment) before the transport it is handed to ever sees a live request. `@unchecked Sendable`
/// is safe here specifically because of that ordering — there is no window in which a write and
/// a concurrent read could race — not because the box is generally thread-safe.
private final class TerminalUnauthorizedBox: @unchecked Sendable {
  var handler: (@Sendable (String) async -> Void)?
}
