import ImgManagerAPI
import OpenAPIRuntime
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

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
  @State private var selectedFolderID: Int?
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
      #if DEBUG
        if DebugStubLaunch.isActive {
          // Item 9(a): the fixture composition renders the workspace directly — auth is never
          // exercised (no Keychain write, no token, no routing decision touched) in this path.
          workspace
        } else {
          routedBody
        }
      #else
        routedBody
      #endif
    }
    .task { await auth.bootstrap() }
    .onOpenURL { url in
      NativeLoginCallbackInbox.shared.deliver(url)
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active else { return }
      // P6 (IMGMGR-116): ONE ordered task, not two independent ones — (a) renew, (b) confirm
      // still signed in AND a shoot is selected, (c) only then the authoritative refresh. The
      // prior two-`Task{}` shape ran renewal and the grid reload concurrently/unordered, and
      // used `fullReload()` (unconditional focus-clear); `authoritativeRefresh()` replaces that
      // reload with the generation-fenced, multi-page, focus-preserving re-read.
      Task {
        await auth.renewOnForeground()
        guard case .signedIn = auth.status, gridStore.query.folderID != nil else { return }
        await gridStore.authoritativeRefresh()
      }
    }
  }

  @ViewBuilder
  private var routedBody: some View {
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

  private var workspace: some View {
    Group {
      if layoutMode == .regular3 {
        NavigationSplitView(columnVisibility: $columnVisibility) {
          sidebar
        } content: {
          contentColumn
        } detail: {
          detailColumn
        }
        .navigationSplitViewStyle(.prominentDetail)
      } else {
        // Compact and Regular-2 (diff-gate round 3, blocker 3): a genuine 2-column split
        // (sidebar | grid) — GridView owns the FULL workspace pane, matching fold item 7's
        // "no permanent inspector column outside Regular-3" pin. Reusing the 3-column
        // initializer with an EMPTY `detailColumn` (as this view did before this fix) still
        // reserves a second, always-visible pane under `.doubleColumn` visibility — the grid
        // was confined to a narrow column beside a wasted blank pane (retained Regular-2
        // screenshot evidence). The 2-column initializer has no third pane to accidentally
        // reserve, so `contentColumn` (grid + its own Info-sheet toolbar button) becomes the
        // sole `detail`.
        NavigationSplitView(columnVisibility: $columnVisibility) {
          sidebar
        } detail: {
          contentColumn
        }
      }
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      applyWidth(width)
    }
    .task {
      await connectivity.check()
      #if DEBUG
        if DebugStubLaunch.isActive {
          // Auto-select the fixture shoot so the grid is already populated for screenshots —
          // no manual navigation step in the fixture harness. Sets `selectedFolderID` too (not
          // just calling the store directly) so the List's own selection state agrees and the
          // split view actually navigates, exactly as a real tap would.
          selectedFolderID = 1
          await gridStore.selectShoot(folderID: 1)
        }
        #if canImport(UIKit)
          if DebugStubLaunch.forceLandscape,
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
          {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
          }
        #endif
      #endif
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
    // P5: full-screen loupe takeover — unconditionally on Compact (the loupe is ALWAYS
    // full-screen there), and on Regular-2/3 only once the explicit toggle is on. The docked
    // Regular-2/3 presentation (the common case there) lives in `contentColumn` instead, never
    // here — this cover and that in-place swap are mutually exclusive by construction (see
    // `contentColumn`'s own condition), so the loupe is never rendered twice at once.
    .fullScreenCover(
      isPresented: Binding(
        get: { gridStore.isLoupeOpen && (layoutMode == .compact || gridStore.isLoupeFullScreen) },
        set: { presented in
          if !presented { gridStore.closeLoupe() }
        })
    ) {
      LoupeView(store: gridStore, layoutMode: layoutMode)
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
        // `FolderNode.path`). The browsable shoot leaves are the dated kinds — see
        // `ShootListFilter` for the vocabulary and IMGMGR-173 for why the value is pinned
        // there, not inlined here. Selection-bound (not a bare `Button`) so
        // `NavigationSplitView` actually navigates into the content column on ALL layout
        // modes, Compact included — a plain `Button` calling `selectShoot` mutated the
        // grid's data but never pushed the split view anywhere.
        List(ShootListFilter.shoots(folders), id: \.id, selection: $selectedFolderID) {
          folder in
          Text(folder.name)
        }
        .task {
          if let tree = try? await gridService.folders() {
            folders = tree.items
          }
        }
        .onChange(of: selectedFolderID) { _, newValue in
          guard let newValue else { return }
          Task { await gridStore.selectShoot(folderID: newValue) }
        }
      case .unreachable:
        Text(DegradedStateCopy.notConnected)
      }
    }
    .navigationTitle("img-manager")
  }

  private var contentColumn: some View {
    Group {
      // P5: Regular-2/3's DEFAULT loupe presentation — docked in place of the grid, never a
      // takeover (spec: "not a full-screen takeover by default... the detail pane, with the
      // grid retained as a filmstrip"). Compact never takes this branch (its loupe is always
      // the full-screen cover above); once `isLoupeFullScreen` is toggled on, this falls back
      // to the plain grid branch below so the cover above is the only thing showing the loupe.
      if gridStore.isLoupeOpen && layoutMode != .compact && !gridStore.isLoupeFullScreen {
        LoupeView(store: gridStore, layoutMode: layoutMode)
      } else {
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
