import ImgManagerAPI
import SwiftUI

/// The culling surface itself, presented differently per `LayoutMode` BY DESIGN (spec §"Loupe /
/// cull"). One view, branched only on `layoutMode` — never on the device-idiom API, whose very
/// NAME is banned from this tree by a mac-gate absence grep (plan invariant (i)):
///
/// - `.compact`: the filmstrip below the main image, and no full-screen toggle control (the
///   presenting view — `RootView` — always shows this full-screen here already). WP13 P9
///   (IMGMGR-218) removed the filmstrip exclusion this bullet used to record: the phone gets the
///   spec's thumb bar, and it is the SAME `FilmstripView` over the SAME store the iPad's is, so
///   Scene-mode frame walking is inherited rather than re-implemented.
/// - `.regular2`/`.regular3`: the same filmstrip (same store, same pagers, never a
///   filmstrip-local page — fold's "one paging path" pivot) and a full-screen toggle button in
///   the header.
///
/// IMGMGR-406 (owner decision 2026-09-05, option (a), both idioms alike) scopes WHAT that one
/// strip shows and whether it is built at all — `FilmstripScope` below — without giving any
/// layout mode a strip the other does not have.
///
/// Pixels: `.preview` tier only (spec: "the loupe never requests originals") — this view never
/// requests `.grid` for its own main image (the filmstrip's thumbnails do, same as `TileView`).
/// WP13 P3 (IMGMGR-213) adds zoom, and zoom does NOT change that: magnification is 1:1 against
/// the SAME `preview` proxy at every scale, because 1600 px is the largest proxy the backend
/// renders. `theLoupeNeverRequestsAnythingButThePreviewTier` pins it.
///
/// ## Zoom state: normalise on read, normalise on write
///
/// `zoomModel` holds the last COMMITTED zoom. Every read (`resolvedZoom`) and every write
/// (`mutateZoom`) first routes the currently focused image id through `zoomInstaller`
/// `applyFrameChange`, so a frame change resets the zoom even before the `.task` below has run —
/// and `body` itself therefore exercises the seam, which is what
/// `LoupeZoomWiringTests.bodyRoutesAFocusChangeIntoTheInstaller` observes. The `.task` still
/// commits the reset to storage so that stepping A -> B -> A cannot restore A's old zoom.
/// How long THIS loupe's paging is allowed to keep asking (Codex round 4).
///
/// The paging trigger is an unstructured `Task` on purpose — a `.task(id:)` would cancel a page
/// still on the wire on every focus change, and `GridService` turns any thrown error, a
/// `CancellationError` included, into `.unreachable`, which the pagers record as
/// `lastPageLoadError`. But "not cancellable" also means the continuation after an `await`
/// survives the loupe being closed, and would then start the NEXT pager's request against a
/// surface nobody is looking at any more (`GridStore.closeLoupe` keeps focus and generation, so
/// the store itself cannot tell).
///
/// A reference type held in `@State`, so the object the running Task captured is the SAME object
/// the closing view bumps — a value would be re-created with the view struct on every render and
/// the bump would land where nothing is watching. Ending the lifetime never cancels anything: the
/// request already in flight completes and stores its page; only the ASK AFTER it is dropped.
@MainActor
final class LoupePagingLifetime {
  private(set) var generation = 0

  /// This loupe is gone: nothing started before now may ask for more.
  func end() { generation += 1 }
}

struct LoupeView: View {
  @Bindable var store: GridStore
  let layoutMode: LayoutMode
  /// The share lane's pre-flight, owned by `RootView` so ONE instance spans the docked and the
  /// full-screen presentations of this same loupe (they are mutually exclusive but swap freely,
  /// and a prepared export must not be lost — or leaked — across that swap).
  let share: ShareExportStore
  /// WP30 P1 (IMGMGR-456): the shoot's name and the inspector toggle, from the host shell.
  let chrome: LoupeChrome

  /// The production reset adapter; a test substitutes a spy (see the type's own doc comment for
  /// why it is a value and not a view-wrapping closure).
  var zoomInstaller: LoupeZoomInstaller = .live
  /// The production zoom surfaces (chrome twin + gestures); a test substitutes a spy.
  var zoomControls: LoupeZoomControls = .live
  /// The production filmstrip surface; a test substitutes a spy. A value adapter for the reason
  /// `LoupeZoomInstaller`'s own doc comment gives: a call site that exists only inside a `body`
  /// cannot be observed any other way, and WP13 P9's whole claim is about WHICH layout modes
  /// reach this one.
  var filmstrip: LoupeFilmstripSurface = .live

  @State private var proxyImage: PlatformImage?
  /// What `proxyImage` was rendered as (IMGMGR-382), published with it; nil while nothing is.
  @State private var renderedAs: LoupeRendering?
  /// The photograph `proxyImage` shows, so a failed reload of the SAME frame keeps it on screen.
  @State private var paintedImageID: Int?
  @State private var zoomModel: LoupeZoomModel
  /// This presentation's paging lifetime — see `LoupePagingLifetime`. Injectable for the same
  /// reason `zoomModel` is: a test cannot install `@State` on an unrendered view, but it CAN hand
  /// in the object and end it from the outside.
  @State private var pagingLifetime: LoupePagingLifetime
  @State private var imageViewport: CGSize = .zero
  /// The Share row's prepare and sheet (WP30 P1): owned here, because the row lives in a menu.
  @State private var shareLauncher = ShareLauncher()
  @Environment(\.displayScale) private var displayScale

  init(
    store: GridStore, layoutMode: LayoutMode, share: ShareExportStore,
    chrome: LoupeChrome = .none,
    zoomModel: LoupeZoomModel = LoupeZoomModel(),
    pagingLifetime: LoupePagingLifetime = LoupePagingLifetime()
  ) {
    self.store = store
    self.layoutMode = layoutMode
    self.share = share
    self.chrome = chrome
    _zoomModel = State(initialValue: zoomModel)
    _pagingLifetime = State(initialValue: pagingLifetime)
  }

  private var focusedImage: Components.Schemas.ImageSummary? {
    guard let id = store.focusedImageID else { return nil }
    // WP12: the shared actionable projection, not `images` — in Scene mode the photograph the
    // loupe was opened on is a member of an expanded scene or a loose row, and `images` is empty.
    return store.actionableImages.first { $0.id == id }
  }

  /// The zoom AS RENDERED: committed storage, normalised against the photograph currently in the
  /// loupe. Pure — it never writes, so reading it during `body` is not a state mutation.
  var resolvedZoom: LoupeZoomState {
    var resolved = zoomModel.state
    zoomInstaller.applyFrameChange(&resolved, store.focusedImageID)
    return resolved
  }

  /// Every zoom write goes through here: normalise for the current frame first, then apply, then
  /// commit. One place, so no call site can forget the reset.
  func mutateZoom(_ change: (inout LoupeZoomState) -> Void) {
    var next = zoomModel.state
    zoomInstaller.applyFrameChange(&next, store.focusedImageID)
    change(&next)
    zoomModel.state = next
  }

  /// THE zoom action, built once per `body` and handed to both surfaces — the chrome control and
  /// the double-tap. Two call sites, one function: "100 %" cannot come to mean two things.
  private var zoomToggleAction: () -> Void {
    { mutateZoom { $0.toggle() } }
  }

  /// Real pixel dimensions of the decoded proxy — `UIImage.size` is in POINTS, so a proxy decoded
  /// at a non-1 scale would otherwise understate the pixels the zoom ceiling is derived from.
  private var proxyPixelSize: CGSize {
    guard let proxyImage else { return .zero }
    #if canImport(UIKit)
      return CGSize(
        width: proxyImage.size.width * proxyImage.scale,
        height: proxyImage.size.height * proxyImage.scale)
    #else
      return proxyImage.size
    #endif
  }

  private func syncZoomGeometry() {
    mutateZoom {
      $0.updateGeometry(
        proxyPixels: proxyPixelSize, viewport: imageViewport, displayScale: displayScale)
    }
  }

  var body: some View {
    let zoomToggle = zoomToggleAction
    return VStack(spacing: 0) {
      ShareStatusBar(share: share)
      mainImageArea(zoomToggle: zoomToggle)
      // IMGMGR-406: on a loose photograph in Scene mode the strip is not built at all, so the
      // main image takes its 72 pt back. Emitting nothing is what frees the height — a strip that
      // rendered an empty band would still occupy this row of the stack in every layout mode.
      if FilmstripScope.resolve(for: store).isRendered {
        filmstrip.make(store)
      }
      ConflictRecoveryBanner(store: store)
      UnsavedMarksBanner(store: store)
    }
    // The loupe's own accessible subtree, one container a UI test can scope to (its bars are the
    // host's navigation bar and bottom toolbar). `.contain` FIRST, then the identifier — the
    // IMGMGR-280 order, so the identifier never propagates down onto the children.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("loupeContent")
    // WP30 P1 (IMGMGR-456): the header is a system toolbar of exactly three groups, built from
    // `LoupeChromeLayout`, and the mark group rides the system bottom bar. Both hosts give it a
    // bar: the Regular split's detail column, and the Compact cover's own `NavigationStack`.
    .toolbar {
      LoupeToolbar(layout: chromeLayout) { chromeItem($0) }
      LoupeMarkGroup(store: store)
    }
    .navigationBarTitleDisplayMode(.inline)
    // IMGMGR-495: ⌘0's target while this loupe is mounted — THE zoom action, the same closure the
    // double-tap and the More row's "Zoom to 100%" call, so the key cannot mean a second value.
    .focusedSceneValue(\.viewerZoomCommand, ViewerZoomCommand(toggle: zoomToggle))
    .modifier(ShareLauncherPresentation(launcher: shareLauncher, share: share))
    // WP30 P2 (IMGMGR-457): tag entry for the focused photograph, hosted HERE while the loupe is
    // open — the docked Regular loupe replaces the grid that hosts it otherwise, and the Compact
    // loupe covers it. `TagEntryHost` gives the one flag exactly one host.
    .sheet(
      isPresented: Binding(
        get: { store.presentsTagEntry(on: .loupe) },
        set: { store.isTagEntryPresented = $0 })
    ) {
      TagEntrySheet(store: store)
    }
    // NOT `.task(id:)` (Codex round 2): that binds the page load to this frame's view lifetime,
    // so the next focus change CANCELS a page still on the wire — and `GridService` maps every
    // thrown error, `CancellationError` included, to `.unreachable`, which the pagers record as
    // `lastPageLoadError` (GridStore.swift:1177/1229/1340). Stepping back while the tail page
    // loaded would have surfaced a paging error the reader can do nothing about. An unstructured
    // `Task` outlives the focus change; the store's own single-flight guards (`isLoadingPage`,
    // `sceneMembersInFlight`) and tail tests make a duplicate ask a no-op, so nothing is asked
    // twice.
    .onChange(of: store.focusedImageID, initial: true) { _, _ in
      Task { await pageIfNeeded() }
    }
    // Both halves of "this loupe is gone", because neither alone is guaranteed: `closeLoupe()`
    // removes this view (Compact's cover, Regular's docked branch) but the disappear is the
    // framework's timing, while the store's own flag is the app's. Ending twice is harmless — the
    // generation only has to CHANGE.
    .onChange(of: store.isLoupeOpen) { _, isOpen in
      if !isOpen {
        pagingLifetime.end()
        // A tag entry the loupe hosted ends with it, rather than re-presenting on the grid.
        store.isTagEntryPresented = false
      }
    }
    .onDisappear { pagingLifetime.end() }
    // IMGMGR-382: the look catalogue, fetched once per app session on the first open; a failed
    // fetch is asked again on the next open (`LookModel.loadCatalogueIfNeeded`).
    .task { await store.looks.loadCatalogueIfNeeded() }
    .task(id: store.focusedImageID) {
      // Commit the frame-change reset to storage (the render already reflects it through
      // `resolvedZoom`): without this, stepping away from a zoomed frame and back would restore
      // the old magnification instead of opening at fit.
      mutateZoom { _ in }
      // A prepared export names the photograph it was made from, so it never outlives that
      // photograph being the focused one — the temp file is deleted the moment focus moves, not
      // left behind for whatever the user shares next. This is the SUPERSEDE, not a completion:
      // the context changed, so it abandons every generation rather than ending a named one.
      share.supersede()
    }
    // The main image reloads on a frame change AND on a look change (IMGMGR-382). Its own task,
    // so choosing a look neither supersedes a prepared export (the share is never looked) nor
    // re-commits a zoom reset; a newer key cancels the older load (`loadMainImage`).
    .task(id: mainImageRequest) {
      await loadMainImage()
      syncZoomGeometry()
    }
  }

  /// The loupe's paging hook: the store's own pagers, and nothing else. Named so the Do-NOT
  /// ("no second paging path, no loupe-local cursor" — WP8 P5's pivot) is one function a diff can
  /// read, rather than a closure buried in a view modifier.
  ///
  /// IMGMGR-267: this is EXACTLY `GridView.page(from:)`, asked of a photograph. The three
  /// questions ("page the flat grid", "page the scene stream", "page THIS scene's membership")
  /// are each a no-op in the wrong mode by the store's own guards, so asking all three adds no
  /// second path — it makes the loupe ask the same ones the grid does.
  ///
  /// IMGMGR-406 moved it here from `FilmstripView`, where it hung off each thumbnail's own
  /// `.task`. Since option (a) there is no strip at all on a loose photograph in Scene mode, and
  /// a trigger that lives on a view which is not drawn is not a trigger: the reader could walk to
  /// the tail of the loaded window and simply stop, because the loupe's own forward-neighbour
  /// prefetch is flat-only (`GridStore.loupeNext`). Driving it from the FOCUSED photograph — the
  /// one thing that exists in every mode and every layout — keeps the reader's walk paging, and
  /// keeps it to exactly ONE ask per frame: the strip used to ask once per rendered thumbnail.
  func pageIfNeeded() async {
    let lifetime = pagingLifetime
    let generation = lifetime.generation
    // TWO guards, checked at entry and again after EVERY await, because the Task is deliberately
    // not cancellable and its continuation therefore outlives the loupe:
    //
    // - `store.isLoupeOpen` is the SYNCHRONOUS one. `closeLoupe()` clears it on the main actor in
    //   the same turn the reader closed, so a fetch that completes in the update cycle BEFORE the
    //   view's own `onDisappear`/`onChange` has run still sees it false (Codex round 5).
    // - the lifetime generation covers the other direction: this presentation going away without
    //   the store's flag moving (a disappear, or a swap between the docked and full-screen loupe).
    //
    // Neither tears anything down: the request in flight completes and stores its page; only the
    // ASK AFTER it is dropped.
    func mayStillAsk() -> Bool { store.isLoupeOpen && lifetime.generation == generation }
    guard let imageID = store.focusedImageID, mayStillAsk() else { return }
    await store.loadMoreIfNeeded(currentItemID: imageID)
    guard mayStillAsk() else { return }
    await store.loadMoreSceneMembersIfNeeded(afterMemberID: imageID)
    guard mayStillAsk() else { return }
    await store.loadMoreScenesIfNeeded(currentRowID: .image(imageID))
  }

  /// IMGMGR-348, owner device pass 2026-09-02: the zoom ("100 %"), auto-advance ("play") and
  /// full-screen ("expand") controls that used to sit in the header are gone, verbatim — "i think
  /// we can get rid of those altogether … its not necessary". Zoom itself is UNCHANGED as a
  /// gesture (pinch and double-tap, `mainImageArea`); advance-after-marking keeps its keyboard
  /// form (`A`/⌘⇧A) and its account-sheet row; the full-screen MODE had no other way in and went
  /// with its control. WP30 P1 (IMGMGR-456) keeps it that way: `LoupeChromeLayout` has no zoom
  /// item, and the bar is Back · title · Looks, Compare, Info, More (Looks: IMGMGR-382).
  var chromeLayout: LoupeChromeLayout {
    LoupeChromeLayout.make(layoutMode: layoutMode, hasInfo: chrome.info != nil)
  }

  /// "<shoot name> · n of N" over the filmstrip's own scope (`LoupeTitle`).
  var titleText: String {
    LoupeTitle.text(
      shootTitle: chrome.shootTitle, scope: FilmstripScope.resolve(for: store),
      focusedImageID: store.focusedImageID)
  }

  /// One toolbar control, by item. Identifiers come from `LoupeChromeItem`, so the value the
  /// layout test pins and the identifiers the UI test reads are one table.
  @ViewBuilder
  private func chromeItem(_ item: LoupeChromeItem) -> some View {
    switch item {
    case .back:
      // Replaces Close and does exactly what it did; ⎋ and the store's other close paths are
      // untouched.
      Button {
        store.closeLoupe()
      } label: {
        Label(item.title, systemImage: "chevron.backward")
      }
      .accessibilityIdentifier(item.accessibilityIdentifier)
    case .title:
      VStack(spacing: 0) {
        Text(titleText)
          .font(.headline)
          .lineLimit(1)
          .accessibilityIdentifier(item.accessibilityIdentifier)
        // The fidelity label's home is now the title's subtitle — always visible, in every loupe
        // state (spec), including when `focusedImage` is nil (nothing loaded yet), which
        // `LoupeFidelityLabel.label(sourceKind:)`'s own `nil` branch renders as the SAME visible
        // fallback a present-but-unrecognized value would.
        Text(LoupeFidelityLabel.label(sourceKind: focusedImage?.sourceKind))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .accessibilityIdentifier("loupeFidelityLabel")
      }
    case .looks:
      // IMGMGR-382: the server-rendered look, for the main image only.
      LoupeLooksControl(looks: store.looks, focusedImageID: store.focusedImageID)
    case .compare:
      // WP30 P3 (IMGMGR-458): opens Compare on the focused photograph and the next scope image.
      // Enabled iff the filmstrip scope holds at least two photographs (plan decision 2).
      Button(item.title, systemImage: "rectangle.split.2x1") {
        store.openCompare()
      }
      .disabled(!store.canOpenCompare)
      .accessibilityIdentifier(item.accessibilityIdentifier)
    case .info:
      if let info = chrome.info {
        // The SAME inspector flag the grid bar's Info toggles (`inspectorChromeButton`).
        Button {
          info.toggle()
        } label: {
          Label(item.title, systemImage: "info.circle")
        }
        .accessibilityAddTraits(info.isPresented ? [.isSelected] : [])
        .accessibilityIdentifier(item.accessibilityIdentifier)
      }
    case .more:
      // WP30 P2 (IMGMGR-457): the Cull More, rendered from `CullMoreMenuModel` — two sections,
      // six rows. Share keeps the home P1 gave it.
      Menu {
        ForEach(CullMoreMenuModel.sections) { section in
          Section {
            ForEach(section.commands, id: \.self) { command in
              cullRow(command, identifier: CullMoreMenuModel.accessibilityIdentifier(for: command))
            }
          }
        }
      } label: {
        Label(item.title, systemImage: "ellipsis.circle")
      }
      .accessibilityIdentifier(item.accessibilityIdentifier)
    }
  }

  /// WP30 P2 (IMGMGR-457): the photograph's context menu, rendered from `LoupeContextMenuModel`
  /// — [Pick, Dislike, Clear] | [Tag, Share] | [Lock ▸]. Every row is a twin of a control that
  /// exists elsewhere (the mark group, More), so the long press adds no gesture-only verb.
  @ViewBuilder
  private var photoContextMenu: some View {
    ForEach(LoupeContextMenuModel.groups) { group in
      Section {
        ForEach(group.nodes) { node in
          switch node {
          case .command(let command):
            cullRow(
              command, identifier: LoupeContextMenuModel.accessibilityIdentifier(for: command))
          case .submenu(let submenu):
            Menu {
              ForEach(submenu.commands, id: \.self) { command in
                cullRow(
                  command, identifier: LoupeContextMenuModel.accessibilityIdentifier(for: command))
              }
            } label: {
              Label(submenu.title, systemImage: submenu.systemImage)
            }
            .accessibilityIdentifier(submenu.accessibilityIdentifier)
          }
        }
      }
    }
  }

  /// One row of either Cull menu. Each verb reaches the SAME path its existing control uses:
  /// marks through `applyLoupeMark` (the mark group's own cadence), Tag through the grid's tag
  /// entry, Share through this loupe's `ShareLauncher`, Lock through the grid latch, Zoom through
  /// `zoomToggleAction`, Advance through `preferences.autoAdvanceOnMark`.
  @ViewBuilder
  private func cullRow(_ command: CullCommand, identifier: String) -> some View {
    switch command {
    case .pick, .dislike, .clear:
      Button {
        guard let state = command.markState else { return }
        Task { await store.applyLoupeMark(state) }
      } label: {
        Label(command.title, systemImage: command.systemImage)
      }
      .disabled(store.focusedImageID == nil || store.isMutatingMark)
      .accessibilityIdentifier(identifier)
    case .tag:
      Button {
        store.handleTagShortcut()
      } label: {
        Label(command.title, systemImage: command.systemImage)
      }
      .disabled(store.tagTargetImageIDs.isEmpty)
      .accessibilityIdentifier(identifier)
    case .share:
      ShareMenuRow(
        launcher: shareLauncher, share: share, image: focusedImage,
        accessibilityIdentifier: identifier)
    case .lockPick, .lockDislike, .zoomToOneToOne, .advanceAfterMarking:
      checkRow(command, identifier: identifier)
    }
  }

  /// A menu check row: a `Toggle`, which a menu draws with the system ✓. The spoken value states
  /// the same thing for VoiceOver and for the UI test that reads it.
  private func checkRow(_ command: CullCommand, identifier: String) -> some View {
    let latched = store.pickLock.latchedVerb
    let zoom = resolvedZoom
    let isOn: Bool
    let isEnabled: Bool
    if let verb = command.latchVerb {
      // ✓ while its verb holds the grid latch; inert while the other verb does.
      isOn = CullLockRow.isChecked(verb, latchedVerb: latched)
      isEnabled = CullLockRow.action(for: verb, latchedVerb: latched) != nil
    } else if command == .zoomToOneToOne {
      isOn = CullZoomRow.isAtOneToOne(zoom)
      isEnabled = zoom.isZoomAvailable
    } else {
      isOn = store.preferences.autoAdvanceOnMark
      isEnabled = true
    }
    return Toggle(isOn: Binding(get: { isOn }, set: { setCheck(command, to: $0) })) {
      Label(command.title, systemImage: command.systemImage)
    }
    .disabled(!isEnabled)
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityIdentifier(identifier)
  }

  /// What selecting a check row does.
  private func setCheck(_ command: CullCommand, to isOn: Bool) {
    if let verb = command.latchVerb {
      store.toggleLockFromLoupe(verb)
    } else if command == .zoomToOneToOne {
      // The loupe's ONE zoom action — the double-tap's — so "100%" cannot mean two things.
      zoomToggleAction()
    } else if command == .advanceAfterMarking {
      store.preferences.autoAdvanceOnMark = isOn
    }
  }

  private func mainImageArea(zoomToggle: @escaping () -> Void) -> some View {
    let zoom = resolvedZoom
    return ZStack {
      zoomControls.attachGestures(
        AnyView(
          Group {
            if let proxyImage {
              PlatformImageView(image: proxyImage)
                .aspectRatio(contentMode: .fit)
            } else {
              Rectangle().fill(.quaternary)
            }
          }
          .scaleEffect(zoom.scale)
          .offset(zoom.offset)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
          .contentShape(Rectangle())
          .accessibilityIdentifier("loupeImage")
          // IMGMGR-382: the label says which look the painted bytes went through; the value
          // stays the zoom state it always was.
          .accessibilityLabel(store.looks.imageAccessibilityLabel(for: renderedAs))
          .accessibilityValue(zoom.accessibilityValue)
          .onGeometryChange(for: CGSize.self) {
            $0.size
          } action: { size in
            imageViewport = size
            syncZoomGeometry()
          }
        ),
        LoupeZoomGestureHandlers(
          onToggle: zoomToggle,
          onMagnify: { magnification in mutateZoom { $0.magnify(to: magnification) } },
          onMagnifyEnded: { mutateZoom { $0.endMagnify() } },
          onDrag: { translation in mutateZoom { $0.pan(to: translation) } },
          onDragEnded: { translation in handleDragEnded(translation) }
        )
      )
      // WP30 P2 (IMGMGR-457): the photograph's context menu (long press; secondary click with a
      // pointer). The loupe image has no long press of its own, unlike a grid tile.
      .contextMenu { photoContextMenu }

      // Chrome prev/next controls ALONGSIDE swipe (spec: "never gesture-only") — overlaid on
      // the image, never the sole way to advance.
      HStack {
        Button {
          store.loupePrevious()
        } label: {
          Label("Previous", systemImage: "chevron.left")
            .labelStyle(.iconOnly)
            .padding(6)
        }
        // WP30 P1: a system-styled button, not a hand-painted circle. Not `.glass`: the gate's
        // no-custom-glass-grep leg bans that style spelling (ADR-N1), so the plan's own fallback,
        // the system bordered style, is what renders.
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .disabled(!store.canLoupeGoPrevious)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityIdentifier("loupePrevious")

        Spacer()

        Button {
          Task { await store.loupeNext() }
        } label: {
          Label("Next", systemImage: "chevron.right")
            .labelStyle(.iconOnly)
            .padding(6)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .disabled(!store.canLoupeGoNext)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityIdentifier("loupeNext")
      }
      .padding(.horizontal, 8)

      // IMGMGR-348's one piece of share feedback, now that Share is a More row (WP30 P1): the
      // prepare shows on the loupe until the sheet presents or the refusal row says why not.
      if share.isPreparing {
        ProgressView()
          .controlSize(.small)
          .accessibilityIdentifier("loupeSharePreparing")
          .padding()
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      }
    }
    .frame(maxHeight: .infinity)
  }

  /// The arbitration invariant: while zoomed a drag PANS, at fit it advances the frame on the
  /// same +/-30 pt threshold the shipped loupe used. Decided by the pure `dragOutcome`, never by
  /// gesture-priority luck — `aHorizontalDragAdvancesAtFitAndPansWhenZoomed` pins it.
  func handleDragEnded(_ translation: CGSize) {
    switch LoupeZoomState.dragOutcome(translation: translation, isZoomed: resolvedZoom.isZoomed) {
    case .pan(let committed):
      mutateZoom {
        $0.pan(to: committed)
        $0.endPan()
      }
    case .advanceNext:
      Task { await store.loupeNext() }
    case .advancePrevious:
      store.loupePrevious()
    case .ignored:
      break
    }
  }

  var mainImageRequest: LoupeImageRequest {
    LoupeImageRequest(imageID: store.focusedImageID, lookID: store.looks.activeLookID)
  }

  func loadMainImage() async {
    let request = mainImageRequest
    guard let image = focusedImage else {
      proxyImage = nil
      renderedAs = nil
      paintedImageID = nil
      return
    }
    let token = ProxyIdentity.token(
      from: image.proxies.additionalProperties[ProxyTier.preview.rawValue]?.url)
    // IMGMGR-382: through the active look when there is one, falling back to the unlooked proxy
    // inside the store (an undecodable looked render included). Still the `.preview` tier.
    let preview = await store.loupePreview(
      imageID: image.id, identityToken: token, decode: { PlatformImage(data: $0) })
    // A load the frame or the look moved on from never paints over the newer one.
    let fresh = LoupeImageRequest.mayPublish(
      requested: request, current: mainImageRequest, isCancelled: Task.isCancelled)
    guard fresh else { return }
    let paint = LoupeImageRequest.paint(
      hasNewImage: preview.image != nil, imageID: image.id, paintedImageID: paintedImageID)
    switch paint {
    case .paint:
      proxyImage = preview.image
      renderedAs = preview.rendering
      paintedImageID = image.id
    case .keep:
      // The bytes on screen are still this photograph's, and the label keeps describing them;
      // the Looks control already says the chosen look is unavailable for it.
      break
    case .clear:
      proxyImage = nil
      renderedAs = nil
      paintedImageID = nil
    }
  }
}

/// What the loupe's main image depends on (IMGMGR-382): the focused frame and the active look.
struct LoupeImageRequest: Hashable, Sendable {
  let imageID: Int?
  let lookID: String?

  /// Whether a finished load may paint: only when it was not cancelled AND the frame and the
  /// look it was asked for are still the ones in front of the reader. Cancellation alone is not
  /// enough — a load can finish in the window before its task is cancelled.
  static func mayPublish(
    requested: LoupeImageRequest, current: LoupeImageRequest, isCancelled: Bool
  ) -> Bool {
    !isCancelled && requested == current
  }

  /// What a fresh load does to the screen. New bytes always paint. A load that produced nothing
  /// KEEPS what is shown when it is the same photograph (a look and its unlooked fallback both
  /// failing must not blank a frame the reader can already see), and clears only when the frame
  /// changed — the old photograph must never stand in for a different one.
  static func paint(hasNewImage: Bool, imageID: Int, paintedImageID: Int?) -> LoupePaint {
    if hasNewImage { return .paint }
    return paintedImageID == imageID ? .keep : .clear
  }
}

/// `LoupeImageRequest.paint`'s answer.
enum LoupePaint: Equatable, Sendable {
  case paint
  case keep
  case clear
}

/// The loupe's own persistent bottom mark bar (spec: "Pick · Dislike · Clear · Undo", placed
/// low — HIG reach favours the bottom). Every control here calls the SAME `GridStore` mutation
/// path the grid's own `ActionBarView` uses — through `applyLoupeMark`, which is `applyMark`
/// plus WP13 P8's advance-on-mark cadence (the advance hangs off the mutation's own COMMITTED
/// answer, never off the button press) — and `undoLastMark`. `isMutatingMark`
/// (BINDING fold addendum) is the store-level guard against a rapid double-tap; disabling every
/// button here while a mutation is in flight is the view-layer half of that same guard, same
/// "disabled visually, guarded at the store independent of that" posture `ActionBarView`'s Pick
/// button already uses for Select-mode exclusion.
///
/// WP30 P1 (IMGMGR-456, p4128 D7): the group reads Dislike · Clear · Pick, a fixed gap, then
/// Undo, on the system bottom bar (`LoupeMarkGroup`) — the glass is the system's, never ours. A
/// verdict tints its icon rather than filling a pill.
struct LoupeMarkGroup: ToolbarContent {
  let store: GridStore

  var body: some ToolbarContent {
    ToolbarSpacer(.flexible, placement: .bottomBar)
    ToolbarItem(placement: .bottomBar) {
      LoupeMarkBar(store: store)
    }
    ToolbarSpacer(.fixed, placement: .bottomBar)
    ToolbarItem(placement: .bottomBar) {
      LoupeUndoButton(store: store)
    }
    ToolbarSpacer(.flexible, placement: .bottomBar)
  }
}

/// Dislike · Clear · Pick, as one bottom-bar item whose container keeps the `loupeMarkBar`
/// identifier.
struct LoupeMarkBar: View {
  @Bindable var store: GridStore

  var body: some View {
    let markState = store.focusedMarkState
    return HStack(spacing: 16) {
      markButton(.dislike, state: markState)

      Button {
        Task { await store.applyLoupeMark(.none) }
      } label: {
        Label("Clear", systemImage: "xmark.circle")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.primary)
      .disabled(store.focusedImageID == nil || store.isMutatingMark)
      .frame(minWidth: 44, minHeight: 44)
      .accessibilityIdentifier("loupeClearButton")

      markButton(.pick, state: markState)
    }
    .labelStyle(.iconOnly)
    .font(.title3)
    .padding(.horizontal, 8)
    // IMGMGR-280: `.contain` FIRST, then the bar's own identifier. Without it this HStack is not
    // an accessibility element of its own, so an identifier put on it propagates DOWN and
    // overrides every child's — the 23:26 gate run dumped all four controls reporting
    // `loupeMarkBar`, `loupeClearButton` included, and a per-button identifier that never
    // surfaces is a lie no test could catch. As a container the bar keeps its own identifier and
    // the buttons keep theirs.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("loupeMarkBar")
  }

  /// IMGMGR-275: Pick and Dislike are the two controls whose meaning depends on the photograph in
  /// front of the reader, so they are built from one function that takes the FOCUSED frame's mark
  /// — never two hand-written buttons that could drift apart. Tap behaviour is unchanged: the
  /// control still applies its own state through `applyLoupeMark` (never a toggle), the same
  /// entry point and the same cadence it has had since WP13 P8.
  @ViewBuilder
  private func markButton(
    _ control: LoupeMarkPresentation.Control,
    state: Components.Schemas.MarkView.StatePayload?
  ) -> some View {
    let isActive = LoupeMarkPresentation.isActive(control, state: state)
    let verdictColor = MarkPalette.color(for: control.markRole)
    Button {
      Task { await store.applyLoupeMark(control.appliedState) }
    } label: {
      Label(control.title, systemImage: LoupeMarkPresentation.symbol(for: control, state: state))
    }
    .buttonStyle(.borderless)
    // WP16 P1 (p3332 decision 5): an ACTIVE verdict reads in its own colour; inactive stays
    // neutral — an always-tinted bar states nothing. WP30 P1: the colour tints the icon itself
    // (Pick green, Dislike red) instead of filling a bordered pill.
    .foregroundStyle(isActive ? AnyShapeStyle(verdictColor) : AnyShapeStyle(.primary))
    .disabled(store.focusedImageID == nil || store.isMutatingMark)
    .frame(minWidth: 44, minHeight: 44)
    .accessibilityIdentifier(control.accessibilityIdentifier)
    .accessibilityValue(LoupeMarkPresentation.accessibilityValue(for: control, state: state))
    .accessibilityAddTraits(isActive ? [.isSelected] : [])
  }
}

/// Undo, after the group's fixed gap: reverts the last mark (`undoLastMark`), the same path the
/// grid's own Undo uses.
struct LoupeUndoButton: View {
  @Bindable var store: GridStore

  var body: some View {
    Button {
      Task { await store.undoLastMark() }
    } label: {
      Label("Undo", systemImage: "arrow.uturn.backward")
    }
    .labelStyle(.iconOnly)
    .font(.title3)
    .disabled(!store.undo.canUndo || store.isMutatingMark)
    .frame(minWidth: 44, minHeight: 44)
    .accessibilityIdentifier("loupeUndoButton")
  }
}

/// How the loupe's two verdict controls READ for the photograph currently in front of the reader
/// (IMGMGR-275, owner report 2026-08-31: "marks cannot be seen" while culling in the loupe). Pure
/// and separate from the view so the state-reflection rule is something a test reads directly —
/// the grid tile's badge has always had this, the loupe never did.
enum LoupeMarkPresentation {
  enum Control: Sendable, Equatable, CaseIterable {
    case pick
    case dislike

    /// IMGMGR-280: each control's OWN identifier, so a test resolves it by identity rather than
    /// by matching the bar's identifier and the button's label together — which is what the
    /// controls were reduced to while the container's identifier shadowed theirs.
    var accessibilityIdentifier: String {
      switch self {
      case .pick: return "loupePickButton"
      case .dislike: return "loupeDislikeButton"
      }
    }

    var title: String {
      switch self {
      case .pick: return "Pick"
      case .dislike: return "Dislike"
      }
    }

    /// What tapping the control WRITES — unchanged by this ticket, and deliberately not derived
    /// from the current state: these buttons apply a verdict, they do not toggle one.
    var appliedState: MarkStateValue {
      switch self {
      case .pick: return .pick
      case .dislike: return .dislike
      }
    }

    fileprivate var baseSymbol: String {
      switch self {
      case .pick: return "hand.thumbsup"
      case .dislike: return "hand.thumbsdown"
      }
    }
  }

  /// Whether this control is the verdict currently ON the focused photograph. Reads the state and
  /// nothing else — never the last button pressed, which would keep showing a verdict after an
  /// advance moved to a different frame.
  static func isActive(
    _ control: Control, state: Components.Schemas.MarkView.StatePayload?
  ) -> Bool {
    switch control {
    case .pick: return state == .pick
    case .dislike: return state == .dislike
    }
  }

  /// The SF Symbol the control draws: the filled variant of its own glyph while it is the current
  /// verdict, the outline otherwise. Same pair the grid tile's badge already uses, so the two
  /// surfaces say the same thing in the same vocabulary.
  static func symbol(
    for control: Control, state: Components.Schemas.MarkView.StatePayload?
  ) -> String {
    isActive(control, state: state) ? "\(control.baseSymbol).fill" : control.baseSymbol
  }

  /// The spoken half of the same signal: a filled glyph is invisible to VoiceOver, so the state
  /// rides the control's accessibility VALUE beside its unchanged label.
  static func accessibilityValue(
    for control: Control, state: Components.Schemas.MarkView.StatePayload?
  ) -> String {
    switch control {
    case .pick: return isActive(control, state: state) ? "Picked" : "Not picked"
    case .dislike: return isActive(control, state: state) ? "Disliked" : "Not disliked"
    }
  }
}

/// WHAT the loupe's filmstrip shows, and whether there is a strip at all — one value, so the rows
/// the strip draws and the decision to draw it cannot come apart.
///
/// IMGMGR-406 (owner decision 2026-09-05, option (a), iPad and iPhone alike): inside a scene the
/// strip is THAT SCENE, not the stream. Culling a burst is a comparison between its own frames,
/// and a strip carrying the loose photographs either side of the band answered a question nobody
/// was asking. On a loose photograph there is no such set, so the strip is not drawn at all and
/// the main image takes the height — an empty band would be a bar that says nothing.
///
/// Flat browse is untouched: the strip is the whole sequence, as it has been since WP12.
///
/// Pure, and computed from state the store already holds, so the rule is a value a test reads
/// rather than a branch inside a `body`.
enum FilmstripScope: Equatable, Sendable {
  /// Flat browse: the shared actionable projection, whole.
  case sequence([Components.Schemas.ImageSummary])
  /// Scene browse, on a member: the open scene's band, in display order.
  case members([Components.Schemas.ImageSummary])
  /// Scene browse, on a loose photograph: no strip.
  case hidden

  var frames: [Components.Schemas.ImageSummary] {
    switch self {
    case .sequence(let images), .members(let images): return images
    case .hidden: return []
    }
  }

  /// Whether the strip is built. The one question `LoupeView.body` asks; deriving it from the
  /// same value as `frames` is what makes "no frames" and "no strip" the same fact.
  var isRendered: Bool {
    switch self {
    case .sequence, .members: return true
    case .hidden: return false
    }
  }

  static func resolve(
    displayMode: GridDisplayMode,
    focusedImageID: Int?,
    openSceneMembers: [Components.Schemas.ImageSummary]?,
    actionableImages: [Components.Schemas.ImageSummary]
  ) -> FilmstripScope {
    switch displayMode {
    case .flat:
      return .sequence(actionableImages)
    case .scene:
      // No focus is the same answer as a loose photograph: there is no scene to show.
      guard focusedImageID != nil, let band = openSceneMembers, !band.isEmpty else {
        return .hidden
      }
      return .members(band)
    }
  }

  /// The same decision, asked of the store — the form both call sites use, so neither of them
  /// assembles the arguments (and neither can assemble them differently).
  @MainActor
  static func resolve(for store: GridStore) -> FilmstripScope {
    var band: [Components.Schemas.ImageSummary]?
    if let focused = store.focusedImageID {
      band = store.openSceneMembers(containing: focused)
    }
    return resolve(
      displayMode: store.displayMode, focusedImageID: store.focusedImageID,
      openSceneMembers: band, actionableImages: store.actionableImages)
  }
}

/// EVERY layout mode since WP13 P9 (IMGMGR-218), the phone included: the grid retained as a
/// filmstrip "so context is never lost" (spec) — the SAME `GridStore` state the grid's own
/// `GridView` reads, never a filmstrip-local pool or cursor. Paging is not this view's job at all
/// since IMGMGR-406: `LoupeView.pageIfNeeded()` drives the store's three pagers from the FOCUSED
/// photograph, so the walk keeps paging on a loose photograph where this view does not exist.
///
/// WP12 established that the strip walks the shared ACTIONABLE projection, never `store.images`
/// and never a collapsed card's cover (ADR-0005 decision 4) — that half stands. IMGMGR-406
/// replaces the other half of the WP12 rule ("in Scene mode it shows the loose photographs and
/// the members of opened scenes"): in Scene mode the strip is now the open scene's band alone,
/// and on a loose photograph there is no strip. `FilmstripScope` above holds that rule.
///
/// WP13 P9: the strip FOLLOWS the focused frame. P8's advance-on-mark moves `focusedImageID` on
/// every committed loupe mark, so a strip that only moved when the reader dragged it would
/// silently stop tracking after the first advance — which on a phone, where the strip is the
/// only context there is, would be worse than no strip. `revealTarget(in:)` names the frame to
/// bring into view and `reveal(_:through:)` is the one seam that brings it.
///
/// Do NOT:
/// - give the strip a cursor, a page, or a paging TRIGGER of its own (IMGMGR-267, IMGMGR-406) —
///   the one trigger is `LoupeView.pageIfNeeded()`, on the focused photograph; a `.task` per
///   thumbnail here would both ask N times per frame and go silent whenever the strip is hidden;
/// - draw a thumbnail as anything but a real Button (IMGMGR-268);
/// - reserve the strip's height when the scope is `.hidden` (IMGMGR-406) — an empty bar is the
///   thing the owner decision removes;
/// - derive the rows from anywhere but `FilmstripScope`: `frames` and "is there a strip" are one
///   decision, and a second source for either is how they start disagreeing.
struct FilmstripView: View {
  @Bindable var store: GridStore
  /// The scroll seam. Production drives the live `ScrollViewProxy`; a test substitutes a
  /// recorder and passes `nil`, because a `ScrollViewProxy` cannot be constructed outside a
  /// rendered `ScrollViewReader`.
  var scroller: FilmstripFocusScroller = .live

  /// The scope this strip is drawing, re-read from the store on every evaluation so a focus move
  /// from a member to a loose photograph (or into another scene) can leave no stale rows behind.
  var scope: FilmstripScope { FilmstripScope.resolve(for: store) }

  /// THE rows the strip walks. In flat browse the shared actionable projection — never
  /// `store.images`, and so never a collapsed card's cover (ADR-0005 decision 4); in Scene mode
  /// the open scene's band, which is a subset of that same projection (IMGMGR-406).
  var frames: [Components.Schemas.ImageSummary] { scope.frames }

  /// The frame the strip must bring into view, or `nil` when there is nothing to reveal.
  ///
  /// Takes the frames it judges against rather than re-reading `frames`: in Scene mode that
  /// property rebuilds the display sequence, and `body` already evaluated it once for the rows.
  /// Fenced to a frame the strip actually HAS a row for — after an advance the store's focus can
  /// name a photograph this strip has not rendered, and `scrollTo` on an absent id reveals
  /// nothing while reading as if it had.
  func revealTarget(in frames: [Components.Schemas.ImageSummary]) -> Int? {
    guard let id = store.focusedImageID, frames.contains(where: { $0.id == id }) else {
      return nil
    }
    return id
  }

  /// The parameterless form the suites read.
  var revealTarget: Int? { revealTarget(in: frames) }

  /// The one place a scroll is asked for; `body`'s `onChange` carries no logic of its own.
  func reveal(_ target: Int?, through proxy: ScrollViewProxy?) {
    guard let target else { return }
    scroller.reveal(proxy, target)
  }

  /// Nothing is emitted for a `.hidden` scope. `LoupeView.body` already declines to build this
  /// view then; this is the SAME decision at the only other place it could be lost — a strip
  /// constructed anywhere else (a test, a future host) cannot draw an empty band either.
  @ViewBuilder
  var body: some View {
    // Bound ONCE: the decision to draw and the rows drawn come from the same value, so a focus
    // move between the two reads cannot produce a strip with somebody else's frames.
    let scope = self.scope
    if scope.isRendered {
      strip(frames: scope.frames)
    }
  }

  private func strip(frames: [Components.Schemas.ImageSummary]) -> some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        LazyHStack(spacing: 4) {
          ForEach(frames, id: \.id) { image in
            let isFocused = store.focusedImageID == image.id
            // IMGMGR-268: a real Button, never `.onTapGesture` on a plain view. The strip's focus
            // action used to exist only as a gesture, so the accessibility tree carried no
            // control for it at all — on Compact, where the strip is the only context there is,
            // that left VoiceOver with an image and nothing to activate. The hit region is
            // unchanged (the thumbnail's own `contentShape`), `.plain` keeps the visual identical,
            // and the focused frame carries the selected trait so the announcement says which one
            // it is.
            Button {
              store.loupeFocus(on: image.id)
            } label: {
              FilmstripThumbnail(image: image, isFocused: isFocused, store: store)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("filmstripThumbnail-\(image.id)")
            .accessibilityLabel(FilmstripThumbnailAccessibility.label(for: image))
            .accessibilityAddTraits(isFocused ? [.isSelected] : [])
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
      }
      .frame(height: 72)
      // WP30 P1 (IMGMGR-456): the strip is CONTENT, not chrome (ADR-N1 "content carries no
      // glass") — no fill in any mode, and the resolved role rides its accessibility value.
      .materialSurface(.content)
      .accessibilityIdentifier("loupeFilmstrip")
      // WP30 P1 round 2: the strip must not TOUCH the bottom safe-area edge. With the mark group
      // on the system bottom bar the strip became the stack's last view, and a scroll view that
      // abuts the safe-area edge extends itself under the bar and the home indicator (gate
      // d3bd8aa: 146 pt on iPad, 158 pt on iPhone, the bar inside its frame, so a swipe on the
      // strip landed on the bar). A gap below it keeps it a 72 pt band above the bar.
      .padding(.bottom, 4)
      .onChange(of: revealTarget(in: frames), initial: true) { _, target in
        reveal(target, through: proxy)
      }
    }
  }
}

/// The filmstrip surface `LoupeView.body` builds — see `LoupeView.filmstrip`. `@MainActor` for
/// the same reason `LoupeZoomControls` is: `.live` closes over SwiftUI view construction, so a
/// nonisolated `static let` of it is not concurrency-safe under `SWIFT_STRICT_CONCURRENCY`.
@MainActor
struct LoupeFilmstripSurface {
  var make: (GridStore) -> AnyView

  static let live = LoupeFilmstripSurface { AnyView(FilmstripView(store: $0)) }
}

/// The strip's scroll seam: given the live proxy and an id, bring that thumbnail into view.
/// `@MainActor` for the same reason as `LoupeFilmstripSurface` above.
@MainActor
struct FilmstripFocusScroller {
  var reveal: (ScrollViewProxy?, Int) -> Void

  static let live = FilmstripFocusScroller { proxy, id in
    withAnimation(.easeOut(duration: 0.2)) { proxy?.scrollTo(id, anchor: .center) }
  }
}

/// What one strip thumbnail ANNOUNCES (IMGMGR-268). Pure, so the wording is a value a test reads
/// rather than a string literal inside a `ForEach`. It names the photograph and, when there is
/// one, the verdict already on it — the same information the thumbnail's own visual state carries
/// for a reader who can see it.
enum FilmstripThumbnailAccessibility {
  static func label(for image: Components.Schemas.ImageSummary) -> String {
    switch image.mark.state {
    case .pick: return "\(image.filename), picked"
    case .dislike: return "\(image.filename), disliked"
    default: return image.filename
    }
  }
}

struct FilmstripThumbnail: View {
  let image: Components.Schemas.ImageSummary
  let isFocused: Bool
  @State private var proxyImage: PlatformImage?
  let store: GridStore
  /// WP13 P11 (IMGMGR-220): the pointer-hover seam, the same one `TileView` and `SceneCardView`
  /// take — the filmstrip is the loupe's own contact sheet and a pointer over it is asking the
  /// same question.
  var hoverEffectInstaller: HoverEffectInstaller = .live

  var body: some View {
    hoverEffectInstaller.apply(cell)
  }

  private var cell: some View {
    ZStack(alignment: .topTrailing) {
      Group {
        if let proxyImage {
          PlatformImageView(image: proxyImage)
            .aspectRatio(contentMode: .fill)
        } else {
          Rectangle().fill(.quaternary)
        }
      }
      .frame(width: 64, height: 64)
      .clipped()
      // P6 (IMGMGR-116, plan item 3.3): "... and on its filmstrip thumbnail in the loupe" —
      // the SAME compact, tile-local recovery indicator `TileView`'s own badge uses.
      if store.changedElsewhereImageIDs.contains(image.id) {
        Image(systemName: "arrow.triangle.2.circlepath")
          .font(.caption2)
          .padding(3)
          .background(.black.opacity(0.55), in: Circle())
          .foregroundStyle(.white)
          .padding(2)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 2)
        .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 2)
    )
    .contentShape(Rectangle())
    .frame(minWidth: 44, minHeight: 44)
    .task(id: "\(image.id)|\(ProxyTier.grid.rawValue)") {
      let token = ProxyIdentity.token(
        from: image.proxies.additionalProperties[ProxyTier.grid.rawValue]?.url)
      if let data = await store.proxyData(imageID: image.id, tier: .grid, identityToken: token),
        let decoded = PlatformImage(data: data)
      {
        proxyImage = decoded
      }
    }
  }
}
