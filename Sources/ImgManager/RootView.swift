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
  /// IMGMGR-350 P2: bumped by the home's pull-to-refresh so the folder tree re-loads with the
  /// summaries. It lives here because `RootView` builds both halves — the `QueueView` the gesture
  /// is on and the `FolderTreeSection` that holds the load — and neither can reach the other.
  @State private var treeReloadToken = 0
  /// WP28 P1 (IMGMGR-448): the Compact shell's tabs and which one hosts the grid.
  @State private var navigation = WorkspaceNavigation()
  /// WP28 P1: the folder search text, hoisted so every search surface shares one query.
  @State private var folderSearch = FolderSearchModel()
  /// WP28 P1: the folder tree's load and expansion, shared by every surface that renders it.
  @State private var folderTree: FolderTreeState
  @State private var showInspector = false
  /// Whether Regular-3's inspector COLUMN is rendered. Its own flag rather than a second use of
  /// `showInspector`: WP16 P2 (IMGMGR-298) needed one because the two meant opposite things at
  /// rest, and IMGMGR-390 keeps it because the COUPLING is different — this flag also decides the
  /// split view's visibility (`inspectorVisibilityBinding`), which `showInspector` never does.
  ///
  /// **The default is now false.** WP16 P2's own comment argued the opposite — "defaulting this
  /// to false would be a capability loss dressed as a collapse" — and the owner's decision on
  /// IMGMGR-338 (comment 3731) overrules it with the trade that sentence did not price: at
  /// Regular-3 the expanded inspector costs the SIDEBAR its pane and squeezes the grid's own bar
  /// to ~209 pt, so the workspace opened with the queue gone and three of six chrome controls
  /// folded into the overflow chevron. Collapsed at launch, the sidebar stays visible
  /// (`InspectorPlacement.columnVisibility` answers `.doubleColumn`) and the six ride the grid's
  /// wide bar; the reader expands the inspector when they want it, from the same persistent
  /// control that has always closed it. Nothing is lost — only un-asked-for.
  ///
  /// Still deliberately NOT persisted across launches (no `GridPreferences` key): the state is
  /// session-scoped by design, so every launch starts from the same, cheapest workspace, and a
  /// reader who expanded the inspector once does not find a narrowed grid waiting next time.
  #if DEBUG
    @State private var showRegular3Inspector = DebugStubLaunch.startsWithInspectorShown
  #else
    @State private var showRegular3Inspector = false
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
    // WP28 P1: the folder tree's state is RootView's, so it outlives the workspace view and has
    // to end with the session the same way the queue does (see `FolderTreeState.endSession`).
    let folderTree = FolderTreeState()
    _folderTree = State(initialValue: folderTree)
    erasedBox.handler = { [weak queueStore, weak folderTree] in
      // FENCE FIRST, and synchronously — this closure is `@MainActor`, so nothing suspends
      // before this line. Clearing the file first (as this did) left a window between the two
      // awaits in which a fetch could resume against an un-advanced generation and write the
      // snapshot straight back, one await after the erasure had removed it.
      queueStore?.endSession()
      folderTree?.endSession()
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
          refreshQueue: { await queueStore.refresh() },
          // Checkpoint-2 finding B2: the home's own data. The tree load is view state, so the
          // resume reaches it the same way the pull-to-refresh does — by advancing the token
          // `FolderTreeSection.task(id:)` keys on.
          refreshTree: { treeReloadToken += 1 }
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
      // `InspectorPlacement.columnVisibility(for:regular3InspectorShown:)`, which says what the
      // remaining panes are — since IMGMGR-390 the queue KEEPS its pane when the inspector
      // collapses, which is the owner's whole reason for collapsing it.
      // WP28 P1 (IMGMGR-448): the Compact layout mode renders the tab shell; every Regular state
      // keeps the split below, unchanged but for the shared `WorkspaceContent` destination. The
      // decision is `layoutMode` alone — width and size class, never the device idiom.
      if layoutMode == .compact {
        compactShell
      } else if layoutMode == .regular3 && showRegular3Inspector {
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
          // WP28 P1: at Compact the restored shoot opens in Library, as a tree tap there would.
          navigation.showSelectedShoot(in: .library)
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
          // WP28 P1: the fixture's shoot is hosted by the Compact Library tab, so a Compact
          // launch lands on the populated grid exactly as it did in the collapsed split.
          navigation.showSelectedShoot(in: .library)
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

  /// The value's own construction, off the modifier chain.
  private var shootWindowCommand: ShootWindowCommand {
    ShootWindowCommand(
      value: ShootSceneValue.from(query: gridStore.query), opener: shootWindowOpener)
  }

  /// The opener on its own, so a caller that needs only the seam does not also read
  /// `gridStore.query` and take an observation dependency it has no use for (IMGMGR-362's tree
  /// View menu). The action is copied into a LOCAL before the closure is formed, so nothing
  /// captures the view struct itself.
  private var shootWindowOpener: ShootWindowOpener {
    let open = openWindow
    return ShootWindowOpener { open(value: $0) }
  }

  private func applyWidth(_ width: CGFloat) {
    let mode = LayoutResolver.resolve(width: width, horizontalSizeClass: horizontalSizeClass)
    guard mode != layoutMode else { return }
    let previous = layoutMode
    layoutMode = mode
    // WP28 P1 (IMGMGR-448): Regular→Compact with a shoot selected lands on its grid in Library.
    navigation.applyLayoutChange(
      from: previous, to: mode, hasSelectedShoot: gridStore.query.folderID != nil)
    // WP16 P2 (IMGMGR-298): through `InspectorPlacement`, not `LayoutResolver` directly, so a
    // launch reaching Regular-3 already asks for the visibility its inspector state needs — the
    // same answer the toggle gives. Since IMGMGR-390 the collapsed state IS the launch state
    // (`-UITestInspectorShown` is what a DEBUG test uses to start expanded), so this is the path
    // every fresh iPad landscape session takes.
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

  /// Compact's launch surface (a full-screen list) and Regular's persistent sidebar column.
  ///
  /// IMGMGR-350: its content is the tier-grouped FOLDER TREE — the tree `FolderTreeSection`
  /// already carried, promoted from a collapsed disclosure below the readiness sections to the
  /// home itself. `QueueView` stays mounted around it for the degraded/loading machine
  /// (IMGMGR-198) and for the summaries P3's row badge reads; it no longer arranges anything.
  /// P6 (IMGMGR-216) deleted the `layoutMode == .compact ? nil` ternary that used to sit on
  /// `treeSection` and gave the phone no browse surface: one component, both idioms. The
  /// row-navigation discipline (selection-bound List + `.simultaneousGesture`, never a bare
  /// `Button`, never `onChange`) is preserved verbatim inside `FolderTreeSection` itself — see
  /// its own doc comment.
  ///
  /// IMGMGR-389 closes IMGMGR-342 (sidebar composition, Option B): above the tree sits ONE pinned
  /// "Needs review" section, composed by `QueueView` inside the SAME list so the two are one
  /// scroll and one selection. It renders only when it has members, so the tree is still this
  /// column's sole content whenever nothing is awaiting review.
  @ViewBuilder
  private var sidebar: some View {
    let tree = folderTreeSection(
      searchQuery: folderSearch.text, inlineSearchText: $folderSearch.text, onSelect: selectShoot)
    // The app-level controls on the app-level column: the persistent bar on Regular-2/3 —
    // `LayoutResolver` never hides this column (`.doubleColumn`/`.all`). At Compact the tab shell
    // carries them instead: Account on the Shoots root, the View menu on the Library root.
    queueHome(showsNeedsReview: true, onSelectShoot: selectShoot, tree: tree)
      .toolbar {
        folderTreeViewMenuItem
        accountToolbarItem
      }
  }

  /// ONE routing path for both halves of the home, on every shell. The pinned section and the tree
  /// row would otherwise each carry their own closure into
  /// `GridStore.selectShoot(folderID:sourceTier:)` — the same call twice, which is the shape a
  /// second navigation path starts as. The tier is optional because a summary names its tier as a
  /// wire string and an unrecognised one must clear the grid's filter rather than resolve to an
  /// invented tier. WP28 P1: the Compact tabs reach it through `WorkspaceNavigation.open`, which
  /// calls exactly this closure and then decides which tab shows the grid.
  private var selectShoot: (Int, GridSourceTier?) -> Void {
    let store = gridStore
    return { folderID, sourceTier in
      Task { await store.selectShoot(folderID: folderID, sourceTier: sourceTier) }
    }
  }

  /// A Compact tab's row tap: the one routing path, then the tab that hosts the grid.
  private func openShoot(from tab: CompactTab) -> (Int, GridSourceTier?) -> Void {
    let nav = navigation
    let route = selectShoot
    return { folderID, sourceTier in
      nav.open(folderID: folderID, tier: sourceTier, from: tab, via: route)
    }
  }

  /// The queue home around a tree: the split's sidebar (with the pinned section) and the Compact
  /// Library tab (without it — at Compact the section's one home is the Shoots tab).
  ///
  /// Diff-gate round-3 closure, B3: `SidebarRouting` (not raw `connectivity.status`) decides this
  /// branch — `QueueView` mounts for BOTH `.connected` and `.unreachable` so its own `QueueStore`
  /// degraded-state machine is always the one that runs; see that type's own doc comment for why
  /// the old direct switch was a defect, not a deliberate second gate.
  @ViewBuilder
  private func queueHome(
    showsNeedsReview: Bool, onSelectShoot: @escaping (Int, GridSourceTier?) -> Void,
    tree: FolderTreeSection
  ) -> some View {
    switch SidebarRouting.destination(for: connectivity.status) {
    case .checking:
      ProgressView()
    case .queue:
      QueueView(
        queueStore: queueStore, selectedFolderID: $selectedFolderID,
        onRefreshTree: { treeReloadToken += 1 },
        // IMGMGR-389: the pinned section's rows route through the SAME closure the tree's do.
        onSelectShoot: onSelectShoot, showsNeedsReview: showsNeedsReview, treeSection: tree)
    }
  }

  /// The folder tree, built in ONE place for every surface that renders it (the split's sidebar,
  /// the Compact Library and Search tabs). All of them share `folderTree` — one load, one set of
  /// open rows — and differ only in what narrows the rows, whether the inline field renders, and
  /// where a row tap lands.
  private func folderTreeSection(
    searchQuery: String, inlineSearchText: Binding<String>?,
    onSelect: @escaping (Int, GridSourceTier?) -> Void
  ) -> FolderTreeSection {
    FolderTreeSection(
      // The same loader the rest of the app's covers come through (WP16 P5): one cache,
      // one concurrency gate for every cover in this column.
      gridService: gridService, heroLoader: heroLoader,
      // IMGMGR-362 (WP21 P3): the ONE `GridPreferences` this app has, handed to the tree as
      // the observable object rather than as a copied `Bool` — one instance, two readers
      // (this column's tree and the grid's own menus), one persisted key set. `gridStore`
      // is a single `@State` here (:43), so both columns of the split view read the same
      // object and the iPad cannot hold a stale answer.
      preferences: gridStore.preferences, layoutMode: layoutMode,
      reloadToken: treeReloadToken,
      // P3: read here in the body, so a summaries load that lands later re-renders the
      // rows — `queueStore` is observed, the tree section is a value.
      summariesByFolderID: FolderTreeRowPresentation.index(queueStore.summaries),
      // P4: one store owns both of the home's answers — the tree's replay and its write
      // travel through the same subject, generation and erase path as the summaries'.
      cachedTree: queueStore.cachedTree,
      rememberTree: { folders, fence in
        await queueStore.rememberTree(folders, fence: fence)
      },
      treeFence: { queueStore.treeFence() },
      selectedFolderID: $selectedFolderID,
      // IMGMGR-405: the folder whose grid is showing, read HERE in the body so the tree
      // re-renders when the scope changes — `GridStore.query` is what
      // `selectShoot(folderID:sourceTier:)` records, and it is the only notion of "the open
      // folder" that outlives both a Compact pop-back (which clears the List's selection)
      // and the column-count swap this very view performs (which destroys the tree's state).
      openedFolderID: gridStore.query.folderID, treeState: folderTree, searchQuery: searchQuery,
      inlineSearchText: inlineSearchText,
      onSelect: { folderID, sourceTier in onSelect(folderID, sourceTier) })
  }

  // MARK: - The Compact shell (WP28 P1, IMGMGR-448)

  /// `layoutMode == .compact`'s whole chrome: three tabs over the ONE workspace destination. A
  /// Back out of the hosting tab's grid clears the List selection, exactly as the collapsed
  /// split's pop-back did — the open folder's highlight survives through `openedFolderID`.
  private var compactShell: some View {
    CompactShell(
      navigation: navigation, search: folderSearch,
      badgeCount: CompactTab.badgeCount(summaries: queueStore.summaries),
      onHostPopped: { selectedFolderID = nil }, shoots: shootsRoot, library: libraryRoot,
      searchRoot: searchRoot, destination: contentColumn)
  }

  /// The Shoots tab: Needs review, then Recent. Account's ONE Compact home (p4128 R2-Inventory)
  /// — the grid's bar no longer carries it, so it is declared here and on the split's sidebar.
  private var shootsRoot: some View {
    ShootsHomeView(
      queueStore: queueStore, selectedFolderID: $selectedFolderID,
      onSelectShoot: openShoot(from: .shoots)
    )
    .toolbar {
      accountToolbarItem
    }
  }

  /// The Library tab: the tree alone, its degraded machine and its View menu unchanged.
  @ViewBuilder
  private var libraryRoot: some View {
    let open = openShoot(from: .library)
    let tree = folderTreeSection(searchQuery: "", inlineSearchText: nil, onSelect: open)
    queueHome(showsNeedsReview: false, onSelectShoot: open, tree: tree)
      .toolbar {
        folderTreeViewMenuItem
      }
  }

  /// The Search tab: the SAME tree, narrowed by the tab bar's search field (`folderSearch`), with
  /// no inline field of its own.
  private var searchRoot: some View {
    List(selection: $selectedFolderID) {
      Section {
        folderTreeSection(
          searchQuery: folderSearch.text, inlineSearchText: nil, onSelect: openShoot(from: .search))
      }
    }
    .navigationTitle(CompactTab.search.title)
  }

  /// IMGMGR-362 (WP21 P3), the plan's Compact REACHABILITY answer, verified in the code rather
  /// than assumed: the More menu is declared on the GRID's action bar (`GridView`) and nowhere
  /// else, so on the phone — where the tree home is a place of its own and the grid is pushed on
  /// top of it — a reader standing in front of the folder tree has no way to reach a view option
  /// about the folder tree.
  ///
  /// So the tree home gets its own View menu, and what it renders is the SAME
  /// `GridMoreMenuEntry` value the grid's menu renders (`GridMoreMenu.pruneMirroredArchive`),
  /// through the same `GridMoreMenuItem` row: the same identifier, the same title, the same
  /// binding onto the same `GridPreferences` property. One key, two entry points, and no second
  /// mechanism — a divergence between the two menus is not something to keep in step, it is
  /// impossible.
  ///
  /// `foldsClearIntoMore: false` because that fold is the grid ACTION BAR's width rule (WP13 P1)
  /// and applies to the Clear row alone; this menu holds neither.
  @ToolbarContentBuilder
  private var folderTreeViewMenuItem: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Menu {
        GridMoreMenuItem(
          entry: GridMoreMenu.pruneMirroredArchive, store: gridStore,
          foldsClearIntoMore: false, openShootWindow: shootWindowOpener)
      } label: {
        Label("View", systemImage: "slider.horizontal.3")
      }
      // Named for the same reason `gridMoreMenu` is: "View" is a word this app puts on screen in
      // more than one place, and a UI test that matched the label alone could drive the wrong
      // control.
      .accessibilityIdentifier("folderTreeViewMenu")
    }
  }

  /// WP28 P1 (IMGMGR-448): the shared workspace destination — the split's detail at Regular and
  /// the pushed destination of whichever Compact tab hosts the grid (`WorkspaceNavigation`).
  private var contentColumn: some View {
    WorkspaceContent(
      store: gridStore, service: gridService, share: shareExport, layoutMode: layoutMode,
      showInspector: $showInspector, inspectorVisibility: inspectorVisibilityBinding)
  }

  /// The inspector's presentation at the CURRENT layout mode — the same resolver
  /// `WorkspaceContent` reads, so the two cannot disagree about which surface is showing.
  private var inspectorPresentation: InspectorPresentation {
    InspectorPlacement.presentation(for: layoutMode)
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
