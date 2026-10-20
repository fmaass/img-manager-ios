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
  /// IMGMGR-478: whether the reader left the Regular sidebar hidden, across launches
  /// (`SidebarVisibilityMemory` says why a `UserDefaults` boolean). Read only when a width
  /// resolves to Regular (`applyWidth`) and written only from a Regular split, so the Compact
  /// launch value above stays the resolver's.
  @AppStorage(SidebarVisibilityMemory.hiddenKey) private var regularSidebarHidden =
    SidebarVisibilityMemory.hiddenDefault
  @State private var connectivity: ConnectivityState
  @State private var auth: AuthSession
  /// IMGMGR-548: the Settings sheet, opened by the account item and by the sidebar gear.
  @State private var showSettingsSheet = false
  /// IMGMGR-548: the Settings sheet's own preferences; `GridStore` reads the Tap to Pick default
  /// through it (`RootView.makeGridStore`).
  @State private var settings: SettingsPreferences
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
  @State private var navigation: WorkspaceNavigation
  /// WP31 P2 (IMGMGR-461), plan decision 4: the Pass Summary a Triage pass left — held while the
  /// Triage cover is still going away (`pending`), then presented over the grid (`passSummary`)
  /// from the cover's `onDismiss`, so the sheet never races the cover's dismissal.
  @State private var pendingPassSummary: PassSummaryPresentation?
  @State private var passSummary: PassSummaryPresentation?
  /// WP31 P2 (IMGMGR-461), plan decision 6: the receiving route of a Triage Handoff; its ticket
  /// fence lets a newer continuation supersede an older one.
  @State private var continuationRouter = TriageContinuationRouter()
  /// WP28 P1: the folder tree's load and expansion, shared by every surface that renders it.
  @State private var folderTree: FolderTreeState
  /// The inspector's one flag at every width (WP28 P3, IMGMGR-450: the system `.inspector` on
  /// `WorkspaceContent`). COLLAPSED at launch — the owner's decision on IMGMGR-338 (comment 3731,
  /// IMGMGR-390): the reader expands it from the Info control when they want it. Deliberately not
  /// persisted across launches, so every launch starts from the same, cheapest workspace.
  @State private var showInspector = false
  #if DEBUG
    /// `-UITestInspectorShown` expands the inspector on the FIRST resolve to Regular-3 only —
    /// the width the flag has always governed — so a suite passing it on the iPhone or at
    /// Regular-2 (`TierHomeUITests`) still walks the collapsed workspace it walked before.
    @State private var hasAppliedDebugInspectorStart = false
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
    let settings = SettingsPreferences()
    _settings = State(initialValue: settings)
    // WP442 P12: bound first so the erasure handler below can leave the entered scene.
    let gridStore = Self.makeGridStore(service: gridService, settings: settings)
    _gridStore = State(initialValue: gridStore)
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
    // Final audit F4: the Compact tabs' paths are hoisted here too, so they end with the session
    // at the same boundary, in the same synchronous run.
    let navigation = WorkspaceNavigation()
    _navigation = State(initialValue: navigation)
    erasedBox.handler = { [weak queueStore, weak folderTree, weak navigation, weak gridStore] in
      // FENCE FIRST, and synchronously — this closure is `@MainActor`, so nothing suspends
      // before this line. Clearing the file first (as this did) left a window between the two
      // awaits in which a fetch could resume against an un-advanced generation and write the
      // snapshot straight back, one await after the erasure had removed it.
      queueStore?.endSession()
      folderTree?.endSession()
      navigation?.endSession()
      gridStore?.leaveScene(.sessionEnded)
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
    .overlay(alignment: .topLeading) { materialsSettingsProbe }
    .task { await auth.bootstrap() }
    .onOpenURL { url in
      // IMGMGR-501: a Handoff simulated MID-SESSION, fixture launches only — the UI test opens
      // `imgmanager://uitest-continue-activity?json=…` while the Pass Summary is up
      // (`DebugStubLaunch.midSessionContinuationJSON`), and the payload reaches the SAME
      // `continueTriage(userInfo:)` the two entries below call.
      #if DEBUG
        if continueFromDebugURL(url) { return }
      #endif
      NativeLoginCallbackInbox.shared.deliver(url)
    }
    // WP31 P2 (IMGMGR-461): a Triage pass handed off from another device. The DEBUG launch
    // argument `-UITestContinueActivity` feeds the same `continueTriage(userInfo:)`.
    .onContinueUserActivity(TriageActivity.activityType) { activity in
      continueTriage(userInfo: activity.userInfo)
    }
    .overlay(alignment: .topTrailing) { continuationProbe }
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
      // WP28 P1 (IMGMGR-448): the Compact layout mode renders the tab shell; every Regular state
      // keeps the split (`regularShell`), unchanged but for the shared `WorkspaceContent`
      // destination (R3-18, IMGMGR-550, removed WP28 P2's toolbar search). The
      // decision is `layoutMode` alone — width and size class, never the device idiom.
      if layoutMode == .compact {
        compactShell
      } else {
        regularShell
      }
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      applyWidth(width)
    }
    // IMGMGR-478: remember what the reader did to the Regular sidebar — the system toggle, the
    // grid bar's toggle or the edge swipe all write this one binding. The action runs after
    // `applyWidth` has returned, so `layoutMode` is already the new mode and the resolver's value
    // on a change into Compact is never recorded. Windows share the one flag; each reads it on its
    // next resolve to Regular.
    .onChange(of: columnVisibility) { _, visibility in
      if let hidden = SidebarVisibilityMemory.recordedHidden(visibility, in: layoutMode) {
        regularSidebarHidden = hidden
      }
    }
    // IMGMGR-548: Settings › Sidebar › "Show Sidebar" writes the same flag; apply it to the split.
    // The echo of a split-side change answers nil (`visibilityAfterFlagChange`), so no loop.
    .onChange(of: regularSidebarHidden) { _, hidden in
      if let next = SidebarVisibilityMemory.visibilityAfterFlagChange(
        columnVisibility, in: layoutMode, hidden: hidden)
      {
        columnVisibility = next
      }
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
          // WP28 P3: `-UITestSelectFolder <id>` picks another fixture folder (the Summary's
          // banner / no-summary cases); without it this is folder 1, as it always was.
          let folderID = DebugStubLaunch.autoSelectFolderID
          selectedFolderID = folderID
          await gridStore.selectShoot(folderID: folderID)
          // WP28 P1: the fixture's shoot is hosted by the Compact Library tab, so a Compact
          // launch lands on the populated grid exactly as it did in the collapsed split.
          navigation.showSelectedShoot(in: .library)
          // WP13 P1: applied AFTER the shoot loads, because `selectShoot` resets the selection
          // by design (a scope change leaves Select). See the flag's own doc comment.
          if DebugStubLaunch.enterSelectMode {
            gridStore.enterSelectExplicitly()
          }
          // WP14 lane B: likewise after the shoot loads — entering Scene mode reloads the window
          // for the CURRENT scope, so doing it first would only be undone. The preference is set
          // BEFORE the mode change so the first card that appears already knows whether to read
          // its inline picks, rather than reading them one body pass late.
          if DebugStubLaunch.enterSceneMode {
            gridStore.preferences.picksInGroups = true
            await gridStore.setDisplayMode(.scene)
          }
          // WP13 P2: likewise applied after the shoot loads — `selectShoot` calls
          // `pickLock.exit()`, and so does `setDisplayMode` (WP442 P12, T2/T5), so latching before
          // either would be silently undone. Mutually exclusive with the Select flag by
          // construction: `lockFromMenu` refuses while Select is active, so passing both leaves
          // Select, exactly as the shipped rule does.
          if DebugStubLaunch.latchDislikeLock {
            gridStore.lockFromMenu(.dislike)
          }
        }
        // WP31 P2 (IMGMGR-461): an incoming Handoff, simulated — after the fixture's own shoot
        // has loaded, through the SAME decode-and-route function `.onContinueUserActivity` calls.
        if DebugStubLaunch.isActive, let json = DebugStubLaunch.continueActivityJSON {
          continueTriage(userInfo: TriageActivity.userInfo(json: json))
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
    // IMGMGR-548: the account item and the sidebar gear both open Settings through this ONE host.
    .sheet(isPresented: $showSettingsSheet) {
      SettingsSheetView(
        auth: auth, preferences: gridStore.preferences, settings: settings,
        showsSidebarVisibilityRow: layoutMode != .compact)
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
      // WP30 P1 (IMGMGR-456): a stack of its own, so the loupe's system toolbar has a bar to
      // render on. No Info here: the Compact inspector is a sheet of the workspace UNDER this
      // cover, so the cover has no inspector path and its trailing group is More alone.
      NavigationStack {
        LoupeView(
          store: gridStore, layoutMode: layoutMode, share: shareExport,
          chrome: LoupeChrome(shootTitle: currentBreadcrumb?.title ?? "", info: nil))
      }
      // IMGMGR-463: the cover takes the workspace's place, so it carries the silent keys too.
      .background { SilentKeyCommandHost() }
    }
    // WP31 P1 (IMGMGR-460): Triage — Compact only, its own cover beside the loupe's. It never
    // sets `isLoupeOpen` (`openTriage()` refuses while the loupe is open), so the two covers are
    // never up together. WP31 P2 (IMGMGR-461), plan decision 4: a pass that ended with at least
    // one action leaves a Pass Summary, presented over the grid once the cover is gone. A pass
    // ended by anything that already closed Triage (an incoming Handoff, decision 6) leaves none.
    // IMGMGR-501 review r2: presented by ITEM — each presentation carries its own gate
    // generation, which its content's onAppear and onDisappear name.
    .fullScreenCover(
      item: Binding(
        get: { GridStore.triageCoverIsHosted(in: layoutMode) ? gridStore.triageCover : nil },
        set: { item in
          if item == nil { gridStore.closeTriage() }
        }),
      onDismiss: {
        // Review round 2: the sheet is registered where it is requested — before the cover is
        // settled, so a waiting route never slips between the two. IMGMGR-501 review r2: its
        // generation travels inside the sheet's item.
        if var summary = pendingPassSummary {
          summary.gateGeneration = gridStore.presentationGate.requested(.passSummarySheet)
          passSummary = summary
        } else {
          passSummary = nil
        }
        pendingPassSummary = nil
        gridStore.presentationGate.dismissed(.triageCover)
      }
    ) { cover in
      TriageView(
        store: gridStore, shootTitle: currentBreadcrumb?.title ?? "",
        totalCount: currentImageCount,
        onPassEnded: { result in
          if gridStore.isTriagePresented {
            pendingPassSummary = PassSummaryPresentation.make(
              result: result, folderID: gridStore.query.folderID,
              tier: gridStore.query.sourceTier, folderTitle: currentBreadcrumb?.title ?? "",
              pool: gridStore.actionableImages.map(\.id))
          }
          gridStore.closeTriage()
        }
      )
      // IMGMGR-501: the content names the presentation it belongs to — its item's generation.
      .onAppear {
        gridStore.presentationGate.presented(.triageCover, generation: cover.generation)
      }
      .onDisappear {
        gridStore.presentationGate.disappeared(.triageCover, generation: cover.generation)
      }
      // IMGMGR-463: as on the loupe's cover — the silent keys follow their menu rows here.
      .background { SilentKeyCommandHost() }
    }
    // WP31 P2 (IMGMGR-461): the Pass Summary — a medium detent at Compact, a form at Regular
    // (`ShootSummarySizing`), the same content.
    .sheet(
      item: $passSummary,
      onDismiss: { gridStore.presentationGate.dismissed(.passSummarySheet) }
    ) { presentation in
      PassSummarySheet(presentation: presentation, layoutMode: layoutMode)
        .onAppear {
          gridStore.presentationGate.presented(
            .passSummarySheet, generation: presentation.gateGeneration)
        }
        .onDisappear {
          gridStore.presentationGate.disappeared(
            .passSummarySheet, generation: presentation.gateGeneration)
        }
        .overlay { midSessionContinuationTrigger(presentation) }
    }
    // WP13 P4 (IMGMGR-215): the shortcut help sheet is hosted HERE, on the workspace, not in
    // `GridView` — `?`/⌘/ and the menu-bar View menu are scene-level, and on Regular-2/3 the
    // grid is swapped out for the docked loupe, which would take the sheet's host with it.
    .sheet(isPresented: $gridStore.isShortcutHelpPresented) {
      ShortcutHelpSheet()
    }
    // WP30 P3 (IMGMGR-458), plan decision 7: nil while Compare is open, so every key command is
    // disabled there; the same actions are published again after Back.
    .focusedSceneValue(\.gridKeyboardActions, publishedKeyboardActions)
    // IMGMGR-463 (p4128 D10): the secondary keys (Space, bare A, `?`) the menu bar no longer
    // draws as twin rows, bound here instead and dispatched into the same focused values.
    .background { SilentKeyCommandHost() }
    // WP13 P11: the menu-bar twin of the More menu's "Open in New Window". Published from here
    // because `openWindow` is a SCENE capability the store cannot hold, and carried as the
    // ALREADY-CONSTRUCTED value so the menu item's enabled state and the value it would open are
    // the same `ShootSceneValue.from(query:)` answer rather than two independent checks.
    .focusedSceneValue(\.shootWindowCommand, shootWindowCommand)
  }

  /// The keyboard actions the scene publishes: none while Compare is open (decision 7).
  private var publishedKeyboardActions: GridKeyboardActions? {
    let actions = gridStore.keyboardActions
    return CompareKeyboardIsolation.published(actions, isCompareOpen: gridStore.isCompareOpen)
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
    // IMGMGR-501: only Compact hosts Triage's cover, so only Compact may request it.
    gridStore.hostsTriageCover = GridStore.triageCoverIsHosted(in: mode)
    // WP30 P3: iPhone-width has no Compare (p4128 "Open items" 2) — the loupe carries on alone.
    if mode == .compact { gridStore.closeCompare() }
    // WP28 P1 (IMGMGR-448): Regular→Compact with a shoot selected lands on its grid in Library.
    navigation.applyLayoutChange(
      from: previous, to: mode, hasSelectedShoot: gridStore.query.folderID != nil)
    // WP28 P3 (IMGMGR-450): one 2-column split at every Regular width, so the visibility is the
    // resolver's own answer — the sidebar beside the grid (IMGMGR-390) whatever the inspector
    // is doing, because the inspector no longer takes a split column. IMGMGR-478: unless the
    // reader left it hidden, which a Regular width restores; Compact ignores the flag.
    columnVisibility = SidebarVisibilityMemory.columnVisibility(
      for: mode, sidebarHidden: regularSidebarHidden)
    #if DEBUG
      if mode == .regular3, DebugStubLaunch.startsWithInspectorShown,
        !hasAppliedDebugInspectorStart
      {
        hasAppliedDebugInspectorStart = true
        showInspector = true
      }
    #endif
  }

  /// WP28 P4 (IMGMGR-451): the materials suite's read-back of the REAL accessibility settings,
  /// over whichever shell renders. Two declarations, no `#if` inside a builder — the shape of
  /// `GridView.debugProbeElement`; in Release it is an `EmptyView`.
  #if DEBUG
    @ViewBuilder private var materialsSettingsProbe: some View {
      if DebugStubLaunch.materialsProbe {
        MaterialsSettingsProbe()
      }
    }
  #else
    private var materialsSettingsProbe: some View { EmptyView() }
  #endif

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
        showSettingsSheet = true
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
    // R3-18 (IMGMGR-550): no search surface narrows the tree any more.
    let tree = folderTreeSection(onSelect: selectShoot)
    // The app-level controls on the app-level column: the persistent bar on Regular-2/3 —
    // `LayoutResolver` never hides this column (`.doubleColumn`/`.all`). At Compact the tab shell
    // carries them instead: Account on the Shoots root, the View menu on the Library root.
    // WP28 P2: the sidebar names its two sections, "Shoots" and "Library".
    queueHome(
      showsNeedsReview: true, showsSectionHeaders: true, onSelectShoot: selectShoot, tree: tree
    )
    .toolbar {
      folderTreeViewMenuItem
      accountToolbarItem
      settingsGearItem
    }
  }

  /// IMGMGR-548: the sidebar gear — Settings' second entry point, on the Regular sidebar column's
  /// bottom bar. Compact has no sidebar, so no gear: its Shoots root keeps the one account item.
  @ToolbarContentBuilder
  private var settingsGearItem: some ToolbarContent {
    ToolbarItem(placement: .bottomBar) {
      Button {
        showSettingsSheet = true
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
      .accessibilityIdentifier("settingsGearButton")
    }
  }

  /// IMGMGR-548: the app's grid store, wired to the Settings sheet's Tap to Pick default. A
  /// static factory so a unit test can prove the wire (`SettingsInteractionTests`).
  static func makeGridStore(service: GridService, settings: SettingsPreferences) -> GridStore {
    GridStore(service: service, startsWithTapToPick: { settings.tapToPickDefault })
  }

  /// WP28 P2 (IMGMGR-449): the Regular shell — the split view in both of its shapes. R3-18
  /// (IMGMGR-550) removed its toolbar folder search.
  private var regularShell: some View {
    // One 2-column split (sidebar | workspace) at Regular-2 and Regular-3 alike, in the system
    // default style. WP28 P3 (IMGMGR-450) retired the 3-column branch: the inspector is the
    // system `.inspector` inside the detail (`WorkspaceContent`), so no column count changes when
    // it opens and the grid keeps one structural identity. The 2-column initializer is also the
    // WP8 diff-gate round-3 fix: a 3-column one with an empty pane still reserved it.
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebar
    } detail: {
      contentColumn
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
      // WP442 P12: a row tap always lands on the folder's stream (it leaves an entered scene).
      Task { await store.openShoot(folderID: folderID, sourceTier: sourceTier) }
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
    showsNeedsReview: Bool, showsSectionHeaders: Bool = false,
    onSelectShoot: @escaping (Int, GridSourceTier?) -> Void, tree: FolderTreeSection
  ) -> some View {
    switch SidebarRouting.destination(for: connectivity.status) {
    case .checking:
      ProgressView()
    case .queue:
      QueueView(
        queueStore: queueStore, selectedFolderID: $selectedFolderID,
        onRefresh: { await refreshQueueHome() },
        // IMGMGR-389: the pinned section's rows route through the SAME closure the tree's do.
        onSelectShoot: onSelectShoot, showsNeedsReview: showsNeedsReview,
        showsSectionHeaders: showsSectionHeaders, treeSection: tree)
    }
  }

  /// IMGMGR-499: the home's ONE refresh — `QueueHomeRefresh.run` with its two closures, composed
  /// here and nowhere else. The pull-to-refresh (`QueueView.onRefresh`) and its visible twin, the
  /// tree View menu's "Refresh" row (`folderTreeViewMenuItem`), both run this, so the gesture and
  /// the menu row cannot diverge.
  ///
  /// DEBUG only (reviews r1, r2), so a UI test attributes a re-run to THIS path — the launch load
  /// and the foreground resume (`ForegroundRefresh`) fetch the same endpoints but never pass
  /// through here: the summaries half counts itself once it has run, and the tree half records
  /// the reload token it issued, whose completed load `FolderTreeSection` reports.
  private func refreshQueueHome() async {
    await QueueHomeRefresh.run(
      summaries: {
        await queueStore.refresh()
        #if DEBUG
          DebugProbe.shared.homeRefreshSummaries += 1
        #endif
      },
      tree: {
        let issued = treeReloadToken + 1
        treeReloadToken = issued
        // Review r2: the token THIS refresh issued, so a UI test can wait for the tree load
        // that completes for it (`DebugProbe.treeLoadCompletedToken`) — not merely that this
        // closure ran.
        #if DEBUG
          DebugProbe.shared.homeRefreshTreeToken = issued
        #endif
      })
  }

  /// The folder tree, built in ONE place for every surface that renders it (the split's sidebar
  /// and the Compact Library tab). Both share `folderTree` — one load, one set of open rows — and
  /// differ only in where a row tap lands. R3-18 (IMGMGR-550): no search narrows it, so the
  /// section's query is always empty.
  private func folderTreeSection(
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
      openedFolderID: gridStore.query.folderID, treeState: folderTree, searchQuery: "",
      onSelect: { folderID, sourceTier in onSelect(folderID, sourceTier) })
  }

  // MARK: - The Compact shell (WP28 P1, IMGMGR-448)

  /// `layoutMode == .compact`'s whole chrome: two tabs over the ONE workspace destination. A
  /// Back out of the hosting tab's grid clears the List selection, exactly as the collapsed
  /// split's pop-back did — the open folder's highlight survives through `openedFolderID`.
  private var compactShell: some View {
    CompactShell(
      navigation: navigation, badgeCount: CompactTab.badgeCount(summaries: queueStore.summaries),
      onHostPopped: { selectedFolderID = nil },
      enteredSceneID: gridStore.enteredSceneID,
      onScenePopped: { [gridStore] in gridStore.leaveScene(.userBack) },
      shoots: shootsRoot, library: libraryRoot,
      destination: { route in workspaceColumn(scope: Self.compactScope(for: route)) })
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
    let tree = folderTreeSection(onSelect: open)
    queueHome(showsNeedsReview: false, onSelectShoot: open, tree: tree)
      .toolbar {
        folderTreeViewMenuItem
      }
  }

  /// IMGMGR-362 (WP21 P3), the plan's Compact REACHABILITY answer, verified in the code rather
  /// than assumed: the More menu is declared on the GRID's action bar (`GridView`) and nowhere
  /// else, so on the phone — where the tree home is a place of its own and the grid is pushed on
  /// top of it — a reader standing in front of the folder tree has no way to reach a view option
  /// about the folder tree.
  ///
  /// So the tree home gets its own View menu, and what it renders is the declared
  /// `GridMoreMenuEntry` value `GridMoreMenu.pruneMirroredArchive`, through the shared
  /// `GridMoreMenuItem` row: its identifier, title and binding onto the one `GridPreferences`
  /// property. WP29 P2 (IMGMGR-453): the grid's More menu no longer renders it, so this menu is
  /// the switch's ONE home (Regular sidebar and Compact Library tab).
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
        // IMGMGR-499: the visible twin of the home's pull-to-refresh, on both of the menu's
        // surfaces (the Compact Library tab, the Regular sidebar) — the SAME `refreshQueueHome()`
        // the gesture runs, as the Shoots title menu's Refresh row twins that tab's gesture. Two
        // rows, depth 1: inside the ≤ 6 rows / depth ≤ 2 menu budget.
        Button {
          Task { await refreshQueueHome() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier(QueueHomeRefresh.menuRowIdentifier)
      } label: {
        Label("View", systemImage: "slider.horizontal.3")
      }
      // Named for the same reason `gridMoreMenu` is: "View" is a word this app puts on screen in
      // more than one place, and a UI test that matched the label alone could drive the wrong
      // control.
      .accessibilityIdentifier("folderTreeViewMenu")
    }
  }

  /// The grid's breadcrumb for the current folder — also the Compact loupe's shoot title.
  private var currentBreadcrumb: GridBreadcrumb? {
    GridBreadcrumb.make(
      folderID: gridStore.query.folderID, treeFolders: folderTree.load.foldersByTier,
      cachedTreeFolders: queueStore.cachedTree?.foldersByTier, summaries: queueStore.summaries)
  }

  /// WP31 P1 (IMGMGR-460): the breadcrumb's server count as a number — Triage's "of N".
  private var currentImageCount: Int? {
    GridBreadcrumb.imageCount(
      folderID: gridStore.query.folderID, treeFolders: folderTree.load.foldersByTier,
      cachedTreeFolders: queueStore.cachedTree?.foldersByTier)
  }

  /// WP31 P2 (IMGMGR-461), plan decision 6: the ONE receiving entry of a Triage Handoff — the
  /// `.onContinueUserActivity` handler and the DEBUG `-UITestContinueActivity` launch argument
  /// both call it. An undecodable payload is ignored: no navigation at all. The ticket is issued
  /// here, synchronously, so the newest arrival supersedes any route still running.
  ///
  /// The shoot opens the way a restored window's does — `GridStore.selectShoot` AWAITED (the
  /// row-tap closure `selectShoot` starts an unstructured `Task` and cannot be awaited), then
  /// the List selection and `WorkspaceNavigation.showSelectedShoot`, applied only once the router
  /// has re-checked the ticket after that load (`showShoot`) — and the loupe opens only on a
  /// photograph the grid has actually loaded. At Compact that is the loupe's cover, never Triage.
  private func continueTriage(userInfo: [AnyHashable: Any]?) {
    guard let activity = TriageActivity(userInfo: userInfo) else { return }
    let router = continuationRouter
    let ticket = router.begin()
    Task {
      let outcome = await router.route(
        activity, ticket: ticket,
        dismissPresentations: { await dismissTriagePresentations() },
        openShoot: { folderID, tier in
          await gridStore.selectShoot(folderID: folderID, sourceTier: tier)
        },
        showShoot: { folderID in
          selectedFolderID = folderID
          navigation.showSelectedShoot(in: .library)
        },
        isShowingShoot: { folderID, tier in
          gridStore.query.folderID == folderID && gridStore.query.sourceTier == tier
        },
        locate: { imageID in await gridStore.locateForContinuation(imageID: imageID) },
        openLoupe: { imageID in
          #if DEBUG
            DebugProbe.shared.recordRouteEvent("openLoupe-\(imageID)")
          #endif
          gridStore.openLoupe(on: imageID)
        })
      #if DEBUG
        DebugProbe.shared.continuation = outcome.probeValue
      #else
        _ = outcome
      #endif
    }
  }

  #if DEBUG
    /// IMGMGR-501 (gate on 1676195): a Handoff arriving while the Pass Summary is up, in the
    /// RUNNING process — the sheet's own advertised payload, through the same
    /// `continueTriage(userInfo:)` both shipped entries call. Fixture launches armed with
    /// `-UITestMidSessionContinuation` only; nothing at all otherwise.
    @ViewBuilder
    private func midSessionContinuationTrigger(_ presentation: PassSummaryPresentation)
      -> some View
    {
      if DebugStubLaunch.isActive, DebugStubLaunch.armsMidSessionContinuation,
        let handoff = presentation.handoff
      {
        Button("Continue here (fixture)") {
          continueTriage(userInfo: handoff.userInfo)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("debugTrigger.midSessionContinuation")
      }
    }
  #else
    private func midSessionContinuationTrigger(_ presentation: PassSummaryPresentation)
      -> some View
    {
      EmptyView()
    }
  #endif

  #if DEBUG
    /// IMGMGR-501: the mid-session continuation URL (`DebugStubLaunch.midSessionContinuationJSON`),
    /// fixture launches only. True when the URL was this one and has been routed.
    private func continueFromDebugURL(_ url: URL) -> Bool {
      guard let json = DebugStubLaunch.midSessionContinuationJSON(from: url) else { return false }
      continueTriage(userInfo: TriageActivity.userInfo(json: json))
      return true
    }
  #endif

  /// Decision 6 (a): Triage and any Pass Summary go away before the shoot opens. The pass ends
  /// WITHOUT a summary — `onPassEnded` only leaves one while `isTriagePresented` is still true,
  /// and it is false from here on. UIKit refuses a presentation while a dismissal is still
  /// animating, so the route awaits the dismissal's COMPLETION (`GridStore.presentationGate`:
  /// each surface registered where its presentation is requested, settled by its own
  /// `onDismiss`) before the loupe's cover can be asked for. A route that arrives while an
  /// earlier route's dismissal is still animating, or before a requested surface has appeared,
  /// finds the flags already cleared and awaits the same completion. A request withdrawn here
  /// before its content ever appeared is settled after the gate's bounded grace instead.
  private func dismissTriagePresentations() async {
    pendingPassSummary = nil
    passSummary = nil
    gridStore.closeTriage()
    gridStore.presentationGate.withdrawUnappeared()
    await gridStore.presentationGate.settled()
  }

  /// EVIDENCE, fixture-only (`GridView.debugProbeElement`'s pattern): how the last Handoff
  /// continuation ended — the positive signal a UI test waits for before asserting that NO loupe
  /// opened.
  #if DEBUG
    @ViewBuilder private var continuationProbe: some View {
      if DebugStubLaunch.isActive {
        Text("debugProbeContinuation")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe.continuation")
          .accessibilityValue("continuation=\(DebugProbe.shared.continuation)")
        // Review round 2: which path settled the last surface a route waited on.
        Text("debugProbeDismissal")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe.dismissal")
          .accessibilityValue("dismissal=\(DebugProbe.shared.dismissal)")
        // IMGMGR-483: every key press the app RECEIVED (`DebugKeyReceipt`), stamped with
        // whether the grid's key actions were published (`grid`) or withheld by Compare
        // (`withheld`) at that moment. The stamp is the published value itself, mirrored here.
        Text("debugProbeKeyReceipts")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe.keyReceipts")
          .accessibilityValue(DebugProbe.shared.keyReceiptsValue)
          .onChange(of: publishedKeyboardActions == nil, initial: true) { _, withheld in
            DebugProbe.shared.gridKeysWithheld = withheld
            DebugKeyReceipt.installIfNeeded()
          }
        // IMGMGR-501 (review r1): the route's boundary events in order.
        Text("debugProbeRouteEvents")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe.routeEvents")
          .accessibilityValue("routeEvents=\(DebugProbe.shared.routeEvents)")
        // IMGMGR-501 (gate on 1676195): which process the probes describe.
        Text("debugProbeLaunch")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe.launch")
          .accessibilityValue("launch=\(DebugProbe.shared.launchID)")
      }
    }
  #else
    private var continuationProbe: some View { EmptyView() }
  #endif

  /// WP28 P1 (IMGMGR-448): the shared workspace destination — the split's detail at Regular and
  /// the pushed destination of whichever Compact tab hosts the grid (`WorkspaceNavigation`).
  /// WP442 P12: a Compact route's constant grid scope; `.group` renders the stream for now (P13).
  static func compactScope(for route: WorkspaceRoute) -> GridScope {
    guard case .scene(let id) = route else { return .stream }
    return .scene(id)
  }

  private var contentColumn: some View {
    workspaceColumn(scope: gridStore.activeScope)
  }

  private func workspaceColumn(scope: GridScope) -> some View {
    // WP28 P3: read here in the body, so the title follows the tree's and the queue's loads.
    // WP29 P1 (IMGMGR-452): the breadcrumb carries that title plus the tree's server count.
    let breadcrumb = currentBreadcrumb
    return WorkspaceContent(
      store: gridStore, service: gridService, share: shareExport, layoutMode: layoutMode,
      scope: scope, queueStore: queueStore, breadcrumb: breadcrumb, showInspector: $showInspector,
      columnVisibility: $columnVisibility)
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
