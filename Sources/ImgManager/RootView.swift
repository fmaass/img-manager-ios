import ImgManagerAPI
import OpenAPIRuntime
import SwiftUI
import WidgetKit

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
  // WP8 P7 (advisory 1): must agree with `LayoutResolver.columnVisibility(for: .compact)` —
  // `applyWidth`'s own `guard mode != layoutMode else { return }` means this INITIAL value is
  // what actually governs a genuine Compact-width launch (the common case: the first
  // `.onGeometryChange` pass resolves to the same `.compact` `layoutMode` already set above, so
  // the guard skips ever re-deriving `columnVisibility` from `LayoutResolver` at all). A
  // mismatched literal here would silently reintroduce the pre-P7 "Compact starts on the empty
  // grid" bug this same phase fixes in `LayoutResolver`.
  @State private var columnVisibility: NavigationSplitViewVisibility =
    LayoutResolver.columnVisibility(for: .compact)
  @State private var connectivity: ConnectivityState
  @State private var auth: AuthSession
  @State private var showAccountSheet = false
  /// WP8 P4: the grid store and its own API boundary (`GridService`, a sibling of `ImgManagerAPIService`
  /// — see that type's doc comment for why P4 does not extend P3's).
  @State private var gridStore: GridStore
  private let gridService: GridService
  /// WP12 (IMGMGR-196): the share lane's app-owned pre-flight — see `ShareExportStore`.
  @State private var shareExport: ShareExportStore
  /// WP8 P7: the work-queue home's own orchestrator and hero-thumbnail loader — siblings of
  /// `gridStore`/`gridService`, sharing the SAME generated `client` but no mutable state with
  /// either (P6 coexistence, binding adjudication 7).
  @State private var queueStore: QueueStore
  private let heroLoader: HeroThumbnailLoader
  @State private var selectedFolderID: Int?
  @State private var showInspector = false
  /// WP16 P2 (IMGMGR-298), design record [/link/3332] decision 4 "both panels collapsible":
  /// whether Regular-3's inspector COLUMN is rendered. Its own flag rather than a second use of
  /// `showInspector`, because the two mean opposite things at rest — the sheet and the slide-over
  /// start hidden and are opened, the column starts SHOWN and is hidden. Defaulting this to false
  /// would be a capability loss dressed as a collapse. Deliberately NOT persisted across launches
  /// (no `GridPreferences` key): IMGMGR-298 does not ask for it, and a reader who quit with the
  /// inspector hidden should not find the workspace's own third column missing next launch.
  #if DEBUG
    @State private var showRegular3Inspector = !DebugStubLaunch.startsWithInspectorHidden
  #else
    @State private var showRegular3Inspector = true
  #endif
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.scenePhase) private var scenePhase
  /// WP13 P11 (IMGMGR-220): the scene value this window was opened (or restored) with, or nil for
  /// an ordinary launch. Applied ONCE, through `selectShoot` — the identical entry point a queue
  /// tap uses — so a restored window lands in the same grid contract rather than a parallel one.
  private let initialShoot: ShootSceneValue?
  @State private var hasAppliedInitialShoot = false
  /// The scene-level window action, read here because `RootView` is the app's composition root
  /// and the only view that spans both the menu bar's focused values and the workspace.
  @Environment(\.openWindow) private var openWindow
  /// WP16 P2 (IMGMGR-298): the workspace-level facets-refresh trigger, injectable for exactly the
  /// reason `GridView.pointerGestureInstaller` is — see `FacetsRefreshInstaller`'s own doc
  /// comment. INTERNAL, like that one, so `RootViewFacetsWiringTests` can substitute a spy;
  /// `.live` is the only installer the running app ever uses.
  let facetsRefreshInstaller: FacetsRefreshInstaller

  init(
    shoot: ShootSceneValue? = nil,
    transport: (any ClientTransport)? = nil,
    credentialStore: CredentialStore = CredentialStore(),
    facetsRefreshInstaller: FacetsRefreshInstaller = .live
  ) {
    self.initialShoot = shoot
    self.facetsRefreshInstaller = facetsRefreshInstaller
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
    // One share pre-flight for the whole app: the docked and full-screen loupes are two
    // presentations of the same thing, and a prepared export (and its temp file) belongs to
    // neither of them alone. The SAME `GridService` is the master lane's byte source
    // (IMGMGR-279, step 4 of `Share/ShareMasterSeam.swift`) — one client, one service, no
    // second transport for the share lane.
    _shareExport = State(initialValue: ShareExportStore(service: gridService, master: gridService))
    let queueService = QueueService(client: client)
    // IMGMGR-198: the queue's cached last answer. The session gets the erase hook (a credential
    // that is genuinely gone takes the answers fetched under it with it), and the store gets a
    // LIVE read of the signed-in subject so a retained store cannot show account A's shoots to
    // account B — see `QueueStore.resetIfSubjectChanged`.
    let queueSnapshotStore = QueueSnapshotStore()
    // A second write-once box, for the same reason as `unauthorizedBox` above and with the same
    // ordering guarantee: the session's erase hook has to reach the QUEUE STORE, and the queue
    // store has to read the SESSION's subject, so one of the two ends is filled in immediately
    // after both exist — synchronously, before any request or sign-out can run.
    let erasedBox = CredentialsErasedBox()
    let session = AuthSession(
      credentialStore: credentialStore, client: client,
      onCredentialsErased: { await erasedBox.handler?() })
    let queueStore = QueueStore(
      service: queueService, snapshotStore: queueSnapshotStore,
      subject: { [weak session] in
        guard case .signedIn(let subject) = session?.status else { return nil }
        return subject
      })
    erasedBox.handler = { [weak queueStore] in
      // FENCE FIRST, and synchronously — this closure is `@MainActor`, so nothing suspends
      // before this line. Clearing the file first (as this did) left a window between the two
      // awaits in which a fetch could resume against an un-advanced generation and write the
      // snapshot straight back, one await after the erasure had removed it.
      queueStore?.endSession()
      await queueSnapshotStore.clear()
    }
    _queueStore = State(initialValue: queueStore)
    heroLoader = HeroThumbnailLoader(service: gridService)
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
      //
      // P7 coexistence (binding adjudication 7a): the queue's OWN foreground refresh is
      // appended AFTER the grid step, unconditionally (even with no shoot selected) — see
      // `ForegroundRefresh.run`'s own doc comment for why this ordering is a pulled-out,
      // independently-tested pure sequencing function rather than inline closure logic.
      Task {
        await ForegroundRefresh.run(
          renew: { await auth.renewOnForeground() },
          isSignedIn: { if case .signedIn = auth.status { true } else { false } },
          hasSelectedShoot: { gridStore.query.folderID != nil },
          refreshGrid: { await gridStore.authoritativeRefresh() },
          refreshQueue: { await queueStore.refresh() }
        )
      }
    }
    .onChange(of: auth.status) { _, newStatus in
      // WP12 (IMGMGR-199): losing the signed-in state must reach the widget promptly — its own
      // timeline refresh is budgeted by WidgetKit and could be half an hour away, and until it
      // runs the widget would keep rendering this account's shoot counts on a device that is no
      // longer signed in. The widget's provider is what DECIDES what a credential-less refresh
      // shows (`ReadinessTimelineResolver`, tested); this is only the nudge to go and ask.
      if case .signedIn = newStatus { return }
      WidgetCenter.shared.reloadTimelines(ofKind: ReadinessWidgetKind.value)
    }
    .onChange(of: gridStore.mutationCommitCount) { _, _ in
      // P7 coexistence (binding adjudication 7c): the ONE signal a committed mark/undo/tag
      // mutation gives the queue — a coalesced, debounced re-read, never an optimistic local
      // patch. Pure view-layer glue: neither store knows about the other.
      queueStore.invalidateAfterMutation()
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

  /// INTERNAL rather than private (WP16 P2 / IMGMGR-298). `workspace` is where the facets
  /// trigger is now installed, and the assertion that it IS installed has to evaluate this
  /// property — a private one is unreachable from a test even with `@testable import`, which is
  /// what the phase's round-2 gate found. Exactly the visibility `GridView` already gives
  /// `pointerGestureInstaller` for the same reason.
  ///
  /// The attach wraps the chrome rather than sitting inside it so the trigger is hosted by the
  /// whole workspace — mounted in every layout mode and every collapse state — rather than by
  /// any one column that a width or a toggle can remove.
  var workspace: some View {
    facetsRefreshInstaller.attach(workspaceChrome, store: gridStore)
  }

  private var workspaceChrome: some View {
    Group {
      // WP16 P2 (IMGMGR-298): the THIRD COLUMN IS ASKED FOR ONLY WHILE IT IS WANTED. Rendering
      // an `EmptyView` into it instead was measured at the gate and does not collapse anything
      // — `actionBarMidX before=104.5 after=104.5` at a 1376 pt window — because the column is
      // reserved by this initializer's arity, not by its content. See
      // `InspectorPlacement.columnVisibility(for:regular3InspectorShown:)`, which is what keeps
      // the queue out of the width that frees up.
      if layoutMode == .regular3 && showRegular3Inspector {
        NavigationSplitView(columnVisibility: $columnVisibility) {
          sidebar
        } content: {
          contentColumn
        } detail: {
          detailColumn
        }
        .navigationSplitViewStyle(.prominentDetail)
      } else {
        // Compact, Regular-2, and (WP16 P2) Regular-3 with the inspector collapsed — the same
        // shape, for the same reason, which is why the collapse reuses it rather than inventing
        // one: a genuine 2-column split
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
      // WP13 P11: the restored/opened window's own shoot, applied through the ONE entry point —
      // `InitialShootApplication` calls `GridStore.selectShoot(folderID:sourceTier:)`, exactly
      // what `QueueCardDestination.route(for:)`'s tap does, so the two paths cannot produce
      // different scopes. Guarded by `hasAppliedInitialShoot` because `.task` re-runs on an
      // identity change and re-selecting would discard a selection the reader has since made.
      if !hasAppliedInitialShoot {
        hasAppliedInitialShoot = true
        if let folderID = await InitialShootApplication.apply(initialShoot, to: gridStore) {
          // Mirrored into the List's own selection state so the split view actually navigates,
          // exactly as a real tap would (the same reason the DEBUG fixture below sets it).
          selectedFolderID = folderID
        }
      }
      #if DEBUG
        if DebugStubLaunch.isActive && DebugStubLaunch.noAutoAdvance {
          // IMGMGR-348: the fixture's own way to park the cadence, now that the loupe header
          // control a UI test used to drive is gone.
          gridStore.preferences.autoAdvanceOnMark = false
        }
        if DebugStubLaunch.isActive && !DebugStubLaunch.skipAutoSelect {
          // Auto-select the fixture shoot so the grid is already populated for screenshots —
          // no manual navigation step in the fixture harness. Sets `selectedFolderID` too (not
          // just calling the store directly) so the List's own selection state agrees and the
          // split view actually navigates, exactly as a real tap would. WP8 P7:
          // `skipAutoSelect` lets the queue's OWN screenshot see the sidebar as a real launch
          // would, instead of being auto-navigated past it into the grid (see that flag's own
          // doc comment).
          selectedFolderID = 1
          await gridStore.selectShoot(folderID: 1)
          // WP13 P1: applied AFTER the shoot loads, because `selectShoot` resets the selection
          // by design (a scope change leaves Select). See the flag's own doc comment.
          if DebugStubLaunch.enterSelectMode {
            gridStore.enterSelectExplicitly()
          }
          // WP13 P2: likewise applied after the shoot loads — `selectShoot` calls
          // `pickLock.exit()`, so latching before it would be silently undone. Mutually
          // exclusive with the Select flag by construction: `lockFromMenu` refuses while Select
          // is active, so passing both leaves Select, exactly as the shipped rule does.
          if DebugStubLaunch.latchDislikeLock {
            gridStore.lockFromMenu(.dislike)
          }
          // WP14 lane B: likewise after the shoot loads — entering Scene mode reloads the window
          // for the CURRENT scope, so doing it first would only be undone. The preference is set
          // BEFORE the mode change so the first card that appears already knows whether to read
          // its inline picks, rather than reading them one body pass late.
          if DebugStubLaunch.enterSceneMode {
            gridStore.preferences.picksInGroups = true
            await gridStore.setDisplayMode(.scene)
          }
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
    // IMGMGR-255: the SHEET stays here, on the container — a sheet needs a host, not a bar, and
    // this host outlives the grid being swapped out for the docked loupe (the same reasoning P4
    // wrote down for the shortcut-help sheet below). Its BUTTON is what moved: see
    // `accountToolbarItem`.
    .sheet(isPresented: $showAccountSheet) {
      AccountSheetView(auth: auth, preferences: gridStore.preferences)
    }
    // P5: full-screen loupe takeover — Compact only, where the loupe is ALWAYS full-screen.
    // The docked Regular-2/3 presentation lives in `contentColumn` instead, never here — this
    // cover and that in-place swap are mutually exclusive by construction (see `contentColumn`'s
    // own condition), so the loupe is never rendered twice at once. The Regular-2/3 opt-in that
    // used to widen this condition went with its header control (IMGMGR-348).
    .fullScreenCover(
      isPresented: Binding(
        get: { gridStore.isLoupeOpen && layoutMode == .compact },
        set: { presented in
          if !presented { gridStore.closeLoupe() }
        })
    ) {
      LoupeView(store: gridStore, layoutMode: layoutMode, share: shareExport)
    }
    // WP13 P4 (IMGMGR-215): the shortcut help sheet is hosted HERE, on the workspace, not in
    // `GridView` — `?`/⌘/ and the menu-bar View menu are scene-level, and on Regular-2/3 the
    // grid is swapped out for the docked loupe, which would take the sheet's host with it.
    .sheet(isPresented: $gridStore.isShortcutHelpPresented) {
      ShortcutHelpSheet()
    }
    .focusedSceneValue(\.gridKeyboardActions, gridStore.keyboardActions)
    // WP13 P11: the menu-bar twin of the More menu's "Open in New Window". Published from here
    // because `openWindow` is a SCENE capability the store cannot hold, and carried as the
    // ALREADY-CONSTRUCTED value so the menu item's enabled state and the value it would open are
    // the same `ShootSceneValue.from(query:)` answer rather than two independent checks.
    .focusedSceneValue(\.shootWindowCommand, shootWindowCommand)
  }

  /// The value's own construction, off the modifier chain: the action is copied into a LOCAL
  /// before the closure is formed, so nothing captures the view struct itself.
  private var shootWindowCommand: ShootWindowCommand {
    let open = openWindow
    return ShootWindowCommand(
      value: ShootSceneValue.from(query: gridStore.query),
      opener: ShootWindowOpener { open(value: $0) })
  }

  private func applyWidth(_ width: CGFloat) {
    let mode = LayoutResolver.resolve(width: width, horizontalSizeClass: horizontalSizeClass)
    guard mode != layoutMode else { return }
    layoutMode = mode
    // WP16 P2 (IMGMGR-298): through `InspectorPlacement`, not `LayoutResolver` directly, so a
    // launch that starts collapsed (`-UITestInspectorHidden`) reaches Regular-3 already asking
    // for the one-pane visibility the collapsed shape needs — the same answer the toggle gives.
    columnVisibility = InspectorPlacement.columnVisibility(
      for: mode, regular3InspectorShown: showRegular3Inspector)
  }

  /// IMGMGR-255: the account item, declared ONCE and attached to the split view's own COLUMNS.
  /// WP8 P1 attached it to the `Group` that wraps the `NavigationSplitView` instead, and that
  /// container owns no navigation bar — SwiftUI had nowhere to place the item and dropped it,
  /// silently, on both idioms in both launch states. Three preserved accessibility trees show the
  /// absence (P8 probe, 2026-08-31): the queue root, the pushed grid on Compact, and iPad
  /// Regular-2. So the account sheet and Sign Out were unreachable from the moment the workspace
  /// shipped, and this item is the only route to either.
  @ToolbarContentBuilder
  private var accountToolbarItem: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Button {
        showAccountSheet = true
      } label: {
        Label("Account", systemImage: "person.crop.circle")
      }
      // WP13 P8 (IMGMGR-214): addressable by IDENTIFIER, not by its label. The gate run at
      // 09:02 showed XCTest matching `app.buttons["Account"]` as `"Account" IN identifiers`
      // and finding nothing — a `Label`'s text is not an identifier. The account sheet is a
      // chrome surface a UI test has to reach, so it gets a handle.
      .accessibilityIdentifier("accountToolbarButton")
    }
  }

  /// WP8 P7 (advisory 1 / Q's launch-surface change): this IS the queue now — Compact's launch
  /// surface (a full-screen list) and Regular's persistent sidebar column, with the pre-P7
  /// shoot-tree List folded into `FolderTreeSection` as a secondary disclosure below it. P6
  /// (IMGMGR-216) deleted the `layoutMode == .compact ? nil` ternary that used to sit on
  /// `treeSection` and gave the phone no browse surface: the tree ships on both idioms, from one
  /// component, and the only mode-dependent thing left about it — whether the disclosure starts
  /// open — is decided in `FolderTreePresentation`. The row-navigation discipline this replaces
  /// (selection-bound List + `.simultaneousGesture`, never a bare `Button`, never `onChange`) is
  /// preserved verbatim inside `QueueView`/`FolderTreeSection` themselves — see their own doc
  /// comments.
  private var sidebar: some View {
    Group {
      // Diff-gate round-3 closure, B3: `SidebarRouting` (not raw `connectivity.status`) decides
      // this branch — `QueueView` mounts for BOTH `.connected` and `.unreachable` so its own
      // `QueueStore` degraded-state machine is always the one that runs; see that type's own
      // doc comment for why the old direct switch was a defect, not a deliberate second gate.
      switch SidebarRouting.destination(for: connectivity.status) {
      case .checking:
        ProgressView()
      case .queue:
        QueueView(
          queueStore: queueStore, heroLoader: heroLoader, selectedFolderID: $selectedFolderID,
          onSelect: { folderID, sourceTier in
            selectedFolderID = folderID
            Task { await gridStore.selectShoot(folderID: folderID, sourceTier: sourceTier) }
          },
          treeSection: FolderTreeSection(
            // The SAME loader instance the queue cards above take (WP16 P5): one cache, one
            // concurrency gate for every cover in this column.
            gridService: gridService, heroLoader: heroLoader, layoutMode: layoutMode,
            selectedFolderID: $selectedFolderID,
            onSelect: { folderID, sourceTier in
              Task { await gridStore.selectShoot(folderID: folderID, sourceTier: sourceTier) }
            })
        )
      }
    }
    // The app-level control on the app-level column. This is the bar on screen at Compact's
    // launch surface (the queue root) and the persistent one on Regular-2/3 — `LayoutResolver`
    // never hides this column (`.doubleColumn`/`.all`), so of the two columns it is the one whose
    // bar is present in every `layoutMode` branch.
    .toolbar { accountToolbarItem }
  }

  private var contentColumn: some View {
    Group {
      // P5: Regular-2/3's loupe presentation — docked in place of the grid, never a takeover
      // (spec: "not a full-screen takeover by default... the detail pane, with the grid retained
      // as a filmstrip"). Compact never takes this branch (its loupe is always the full-screen
      // cover above).
      if gridStore.isLoupeOpen && layoutMode != .compact {
        LoupeView(store: gridStore, layoutMode: layoutMode, share: shareExport)
      } else {
        GridView(store: gridStore, layoutMode: layoutMode)
          .toolbar {
            // Fold item 7's persistent chrome control, unchanged in role: wherever the inspector
            // is not a permanent column, this ONE control is how it is reached — never a second,
            // width-specific surface. WP13 P10 (IMGMGR-219) changes only WHAT it presents at
            // Regular-2, and the decision now comes from one pure resolver
            // (`InspectorPlacement`) rather than an inline `layoutMode != .regular3`.
            if inspectorPresentation.usesChromeControl {
              ToolbarItem(placement: .primaryAction) {
                inspectorChromeButton
              }
            }
            // IMGMGR-255, Compact ONLY: a collapsed `NavigationSplitView` is a stack, so the
            // moment a shoot is selected the grid is PUSHED over the sidebar and the sidebar's
            // bar — the one carrying the account item — leaves the screen entirely (the 10:15 P8
            // gate tree at that moment: `BackButton 'img-manager'`, `Info`, and nothing else).
            // The item therefore rides this bar as well, which is what `GridView.toolbarContent`
            // has assumed in writing since WP13 P4: "Compact has no room for them beside Account
            // and Info". Deliberately NOT declared on Regular — there both columns' bars are on
            // screen at once, and a second copy would sit next to the first.
            if layoutMode == .compact {
              accountToolbarItem
            }
          }
          .overlay(alignment: .trailing) {
            // The ONE place P10 could have gone wrong: the slide-over is an overlay ON THE
            // DETAIL PANE, never a third column. `workspace`'s 2-column `NavigationSplitView`
            // for Compact/Regular-2 is a deliberate WP8 diff-gate round-3 fix (reusing the
            // 3-column initializer with an empty `detailColumn` still reserved a wasted pane
            // under `.doubleColumn`, squeezing the grid), and a panel built as a column would
            // undo it. An overlay sits outside NavigationSplitView's column management
            // entirely, so the two cannot fight over the same space.
            if showInspector && inspectorPresentation == .slideOver {
              inspectorSlideOver
            }
          }
          .sheet(isPresented: inspectorSheetBinding) {
            InspectorView(store: gridStore, service: gridService)
          }
      }
    }
  }

  /// The inspector's presentation at the CURRENT layout mode. One resolver, read by the toolbar
  /// condition, the sheet binding and the slide-over overlay alike, so the three can never
  /// disagree about which surface is showing.
  private var inspectorPresentation: InspectorPresentation {
    InspectorPlacement.presentation(for: layoutMode)
  }

  /// The sheet presents ONLY where the resolved presentation IS the sheet. One `showInspector`
  /// state drives every non-permanent presentation, so there is no width at which two of them
  /// could be on screen at once, and no second flag to drift out of step.
  private var inspectorSheetBinding: Binding<Bool> {
    Binding(
      get: { showInspector && inspectorPresentation.isModal },
      set: { showInspector = $0 })
  }

  /// WP16 P2 (IMGMGR-298): which flag the persistent chrome control owns at the CURRENT width,
  /// resolved in ONE place — the same discipline `inspectorSheetBinding` above follows, and for
  /// the same reason. The column and the two transient presentations cannot share one flag (they
  /// mean opposite things at rest, see `showRegular3Inspector`), so the risk is three surfaces
  /// disagreeing about which one a tap moved. Reading the presentation here is what makes that
  /// structurally impossible rather than a rule three call sites have to remember.
  private var inspectorVisibilityBinding: Binding<Bool> {
    guard inspectorPresentation == .permanentColumn else { return $showInspector }
    // The Regular-3 collapse is TWO facts that must move together: whether the inspector column
    // is asked for, and what the split view is asked to show. Written in one setter — and the
    // visibility computed from the incoming value rather than read back from the state just
    // written — so no ordering between two `@State` writes can leave the pane count and the
    // visibility describing different workspaces.
    return Binding(
      get: { showRegular3Inspector },
      set: { shown in
        showRegular3Inspector = shown
        columnVisibility = InspectorPlacement.columnVisibility(
          for: .regular3, regular3InspectorShown: shown)
      })
  }

  /// [/link/3220] §2.2's side panel: anchored to the trailing edge of the grid pane,
  /// width-limited by `InspectorSlideOverMetrics`, and NON-MODAL — nothing dims, nothing is
  /// disabled, and the grid keeps taking taps beside it. Two details carry that guarantee:
  /// `GeometryReader` measures the PANE the overlay covers (so the width rule applies to the
  /// space actually available, including a half-width iPad window), and the widened frame around
  /// the panel carries no background, so it has no hit region of its own and taps in it reach the
  /// grid underneath. System materials only, never a custom `glassEffect` (ADR-N1) — `.bar` and
  /// `.thinMaterial` are already this app's chrome backing (`ActionBarView`, `GridView`).
  private var inspectorSlideOver: some View {
    GeometryReader { proxy in
      InspectorView(store: gridStore, service: gridService)
        .frame(width: InspectorSlideOverMetrics.width(inPane: proxy.size.width))
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) { Divider() }
        .accessibilityIdentifier("inspectorSlideOver")
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .transition(.move(edge: .trailing))
  }

  /// The Info button doubles as the "filters are on" indicator: on Compact the Info·Stats sheet
  /// is the ONLY filter surface, so the count has to ride the control that opens it — there is
  /// no other chrome to put it on, and a filtered grid that looks unfiltered is exactly the
  /// failure this prevents. The count is the facet fields only, never the shoot scope
  /// (`InspectorFacetFilters`), so browsing an archive shoot never reads as "filtered".
  @ViewBuilder
  private var inspectorChromeButton: some View {
    let activeFilters = InspectorFacetFilters.activeCount(gridStore.currentQuery)
    let spokenLabel = InspectorFacetFilters.infoButtonAccessibilityLabel(activeCount: activeFilters)
    Button {
      // A TOGGLE, not a one-way open: the slide-over has no sheet grabber to dismiss it, so the
      // persistent chrome control is also how it closes (zero gesture-only actions). At Compact
      // the sheet covers this control while it is up, so toggling reads exactly as before.
      // WP16 P2 (IMGMGR-298): at Regular-3 the same tap hides and restores the COLUMN — which
      // flag that is comes from `inspectorVisibilityBinding`, never from a branch written here.
      withAnimation(.snappy(duration: 0.25)) { inspectorVisibilityBinding.wrappedValue.toggle() }
    } label: {
      if activeFilters > 0 {
        // IMGMGR-224: the spoken phrasing rides the TITLE TEXT itself. A `ToolbarItem`'s bar item
        // is built from the button's title, and the WP13 P10 gate log recorded VoiceOver reading
        // the visual "Info · 1" while `.accessibilityLabel` on the button sat there as dead code;
        // the 23:26 run of this lane showed the same for the collapsed-content form. Labelling
        // the Text is the remaining attachment point that travels with the title the bar item
        // actually takes. The visual string is unchanged either way.
        Label {
          Text(InspectorFacetFilters.infoButtonTitle(activeCount: activeFilters))
            .accessibilityLabel(spokenLabel)
        } icon: {
          Image(systemName: "line.3.horizontal.decrease.circle.fill")
        }
        .labelStyle(.titleAndIcon)
      } else {
        Label {
          Text("Info").accessibilityLabel(spokenLabel)
        } icon: {
          Image(systemName: "info.circle")
        }
      }
    }
    .accessibilityLabel(spokenLabel)
    // Diagnostic AND useful: the account item's own identifier surfaces through the same bridge
    // (gate tree, `accountToolbarButton`), so if this one appears while the label still does not,
    // the bridge drops labels specifically — which is the finding, not a guess.
    .accessibilityIdentifier("inspectorChromeButton")
  }

  /// WP16 P2 (IMGMGR-298): the third column renders only while Regular-3 AND the reader has not
  /// collapsed it. `InspectorPresentation` gains no case for the collapsed state — the
  /// presentation at this width is still a column; whether it is on screen is view state, the
  /// same relationship `showInspector` already has with the sheet and the slide-over.
  private var detailColumn: some View {
    Group {
      if layoutMode == .regular3 && showRegular3Inspector {
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

/// The same write-once box for the credential-erasure hook (see `RootView.init`): filled in
/// synchronously during init, before the app can sign out, so no read can observe it unset.
private final class CredentialsErasedBox: @unchecked Sendable {
  var handler: (@MainActor @Sendable () async -> Void)?
}
