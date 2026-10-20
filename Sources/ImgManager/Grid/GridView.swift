import ImgManagerAPI
import SwiftUI

/// The contact-sheet grid: justified rows, the Pick Lock mode row when latched, and the
/// persistent bottom action bar. Present in every layout mode — Compact and Regular alike
/// (the inspector is what differs by layout mode, not this view).
///
/// Diff-gate round 2, blocker 2: renders EXACTLY `packWithTierPlan`'s output — the tier and
/// size it renders a tile at are the same tier and size that resolver computed from the tile's
/// real justified (row-level, never-upscale-capped) edge. There is no second, independent size
/// computation anywhere in this file.
struct GridView: View {
  @Bindable var store: GridStore
  /// WP13 P4 (IMGMGR-215): where the two view-option controls live. Resolved ONCE by
  /// `RootView` from measured width plus `horizontalSizeClass` and passed down — never
  /// re-derived here, and never from the device-idiom API (plan invariant (i)).
  let layoutMode: LayoutMode
  @Environment(\.displayScale) private var displayScale
  @State private var paneWidth: CGFloat = 0
  @State private var tileFrames: [GridDisplayID: CGRect] = [:]

  /// Injectable factory for the live pointer-drag gesture bridge (diff-gate round 3, blocker 2):
  /// `.live` is the only installer the running app ever uses; a test substitutes a spy so the
  /// wiring itself — not just the recognizer/mapper/hit-test/store-routing pieces underneath it,
  /// which are already independently tested — is provably exercised by `body`. Deleting the call
  /// site below (the old bare `.gesture(PrimaryPointerDragGesture(...))` block) now turns that
  /// test RED instead of leaving every existing test green.
  var pointerGestureInstaller: PointerGestureInstaller = .live

  /// WP13 P11 (IMGMGR-220): the scene-level window action, read at the deepest view that can see
  /// it and handed down to the More menu. Production always uses it; `openShootWindowOverride` is
  /// the test-only seam (a unit test has no scene, so `openWindow` cannot be constructed there),
  /// exactly the shape `pointerGestureInstaller` already uses.
  @Environment(\.openWindow) private var openWindow
  var openShootWindowOverride: ShootWindowOpener?

  private var openShootWindow: ShootWindowOpener {
    if let openShootWindowOverride { return openShootWindowOverride }
    // The action is copied into a LOCAL before the closure is formed: `OpenWindowAction` is
    // `Sendable` (SDK 26.5 swiftinterface, probed), but `self` is a view struct and capturing it
    // in a `@Sendable` closure is not what this needs to keep alive.
    let open = openWindow
    return ShootWindowOpener { value in open(value: value) }
  }

  /// WP13 P5b: `body` is the composition plus its modifiers; the stack itself and the chrome
  /// rows above it are their own declarations. Not a style choice — adding one more `.onChange`
  /// to the single flat expression this used to be tipped the type checker over its budget
  /// ("unable to type-check this expression in reasonable time", GridView.swift:50, gate run
  /// 02:38). Each piece now checks on its own.
  var body: some View {
    stack
      .onChange(of: store.images) { _, _ in publishRows() }
      .onChange(of: store.sceneRows) { _, _ in publishRows() }
      .onChange(of: store.sceneExpanded) { _, _ in publishRows() }
      .onChange(of: store.sceneMembers) { _, _ in publishRows() }
      .onChange(of: store.rowHeight) { _, _ in publishRows() }
      // IMGMGR-551 (R3-7): Justified ↔ Square moves every row break, so the navigation rows are
      // rebuilt from the new packing exactly as for a size step.
      .onChange(of: store.layoutStyle) { _, _ in publishRows() }
      // WP13 P5b: the header set arrives from its own fetch AFTER the page, and it is what
      // turns one packing pass into per-section passes — so the row table has to be rebuilt
      // when it lands, or arrow navigation would keep describing the unsectioned layout.
      .onChange(of: store.groupHeaders) { _, _ in publishRows() }
  }

  /// Compact's persistent options row and the transient mode rows, in their pinned order.
  ///
  /// WP13 P4 (IMGMGR-215): the options row sits immediately below the navigation bar — above
  /// the transient mode rows, because it is the one row that is always there. On Regular the
  /// same controls are `.primaryAction` toolbar items (see `ShellToolbarLayout`); they are never
  /// rendered in both places at once, which is what `WorkspaceChromePlacement` states as a
  /// value rather than leaving as a rule two call sites have to remember.
  ///
  /// Pinned order: the mode row above the recovery banner, the banner above the action bar.
  /// IMGMGR-256 removed the Scene caption row that used to sit above the mode row — Scene now
  /// shows itself through the Group control's highlighted state instead. At most ONE mode row
  /// can ever render — a lock and Select
  /// are mutually exclusive in `GridStore` (`enterSelectExplicitly` and `longPressTile` both
  /// unlatch first), and the `else if` makes that a structural fact of this view rather than a
  /// coincidence two independent `if`s would let drift apart. Pick Lock and Dislike Lock cannot
  /// both render because `latchedVerb` is one value, not two flags.
  @ViewBuilder private var chromeRows: some View {
    // Renders EXACTLY `GridChromeRows.rows(...)`, in its order, and holds no second list — the
    // same "declare it, then render the declaration" discipline `GridMoreMenu.entries` and
    // `AppCommands.declarations` already follow. It is what makes "Scene mode adds no banner row
    // of its own" (IMGMGR-256) a value test rather than a reading of a `@ViewBuilder`.
    ForEach(GridChromeRows.rows(layoutMode: layoutMode, store: store), id: \.self) { row in
      switch row {
      case .options:
        GridOptionsRow(store: store)
      case .pickLock(let verb):
        PickLockModeRow(store: store, verb: verb)
      case .select:
        SelectModeRow(store: store)
      }
    }
  }

  private var stack: some View {
    VStack(spacing: 0) {
      debugProbeElement
      chromeRows
      scrollArea
        .onGeometryChange(for: CGFloat.self) {
          $0.size.width
        } action: { width in
          paneWidth = width
          publishRows()
        }
        .overlay {
          if displayRows.isEmpty && !store.isLoadingPage {
            ContentUnavailableView("No photographs", systemImage: "photo.on.rectangle")
              // R3-12: drawn over the black canvas, so it takes the canvas's dark scheme.
              .environment(\.colorScheme, .dark)
          }
        }
      ConflictRecoveryBanner(store: store)
      GridNoticeBanner(store: store)
      MarksCopyBanner(store: store)
      ActionBarView(
        store: store, openShootWindow: openShootWindow,
        carriesMore: WorkspaceChromePlacement.actionBarCarriesMore(for: layoutMode))
    }
  }

  /// EVIDENCE, fixture-only, WP16 P2 (IMGMGR-298): how many `/api/facets` requests this launch
  /// has served, published where a UI test can read it. The counter has to reach the SCREEN,
  /// because `DebugStubTransport` is an `actor` and an accessibility value is read synchronously
  /// — and it has to re-publish on change, which is what reading an `@Observable` property inside
  /// a view body buys: the dependency is registered, so SwiftUI re-renders this element when the
  /// count moves. Without it the phase's observation (the facets fetch runs while the inspector
  /// has NEVER been on screen) has no mechanism at all.
  ///
  /// Two DECLARATIONS rather than one `#if` inside the builder, so no conditional compilation
  /// sits inside a result builder: in Release the property is an `EmptyView` and `DebugProbe`
  /// does not exist. Even in Debug it renders only under the fixture launch argument, exactly
  /// like `tierProbeValue` and `sceneCardProbeValue`, which are empty outside it. It takes no
  /// hits, so it cannot intercept a tap meant for the grid.
  #if DEBUG
    @ViewBuilder private var debugProbeElement: some View {
      if DebugStubLaunch.isActive {
        Text("debugProbe")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe")
          .accessibilityValue("facetsRequests=\(DebugProbe.shared.facetsRequests)")
        // IMGMGR-347, its OWN element rather than a second half of the value above: the facets
        // probe is read with a full-string `MATCHES` predicate, so appending to its value would
        // break that test rather than extend this one.
        Text("debugProbeAbsorb")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe.absorb")
          .accessibilityValue("absorbRequests=\(DebugProbe.shared.absorbRequests)")
        // WP29 P4 (IMGMGR-455): the split/extract wire calls, on an element of their own for the
        // same reason as the absorb probe above.
        Text("debugProbeSceneEdit")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe.sceneEdit")
          .accessibilityValue(
            "sceneEdits=\(DebugProbe.shared.sceneEdits.joined(separator: "; "))")
        // IMGMGR-485: the tag edits, on an element of their own for the same reason.
        Text("debugProbeTagEdits")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe.tagEdits")
          .accessibilityValue("tagEdits=\(DebugProbe.shared.tagEdits.joined(separator: "; "))")
        // IMGMGR-551 (R3-7): the mark writes the fixture transport has served, readable on the
        // grid (`debugProbe.marks` lives inside the Triage cover only), so a UI test counts the
        // wire writes one grid gesture made. Same value shape as that probe.
        Text("debugProbeGridMarks")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe.gridMarks")
          .accessibilityValue("markWrites=\(DebugProbe.shared.markWrites)")
        // IMGMGR-539: the gutter and the Tile overlays the grid hands its tiles, read from the
        // same calls `scrollArea` and `cell(for:plan:)` make — corroboration for the wiring
        // test, which measures the rendered gaps and reads each tile's drawn badges itself.
        Text("debugProbeGridChrome")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe.gridChrome")
          .accessibilityValue(gridChromeProbeValue)
      }
    }

    private var gridChromeProbeValue: String {
      let gutter = Int(GridGutter.spacing(for: store.rowHeight))
      let overlays = TileOverlaySet(preferences: store.preferences)
      let flags: [(String, Bool)] = [
        ("marks", overlays.marks), ("edited", overlays.edited),
        ("lightroomRating", overlays.lightroomRating), ("sourceKind", overlays.sourceKind),
        ("filename", overlays.filename),
      ]
      let on = flags.filter { $0.1 }.map { $0.0 }
      // IMGMGR-551 (R3-7): the layout in force, appended LAST so every reader of the existing
      // prefix keeps its shape.
      let layout = store.layoutStyle.rawValue
      return "gutter=\(gutter);overlays=\(on.joined(separator: ","));layout=\(layout)"
    }
  #else
    private var debugProbeElement: some View { EmptyView() }
  #endif

  // WP28 P2 (IMGMGR-449): the five view-option controls used to be declared here as five
  // `ToolbarItem(placement: .primaryAction)`s, with Info declared separately around this view.
  // All six are now ONE `ToolbarItemGroup` whose membership and order `ShellToolbarLayout` states
  // (WP13 P4 made them primary items rather than overflow ones; WP16 P3 put Filter first;
  // IMGMGR-390 decided which bar they ride through `WorkspaceChromePlacement`). `WorkspaceContent`
  // attaches the group, because Info belongs to the inspector topology it owns.

  /// The scroll position, translated between what `ScrollView` deals in (a row id) and what
  /// survives a rebuild (a photograph) — `GridScrollAnchor` carries the argument for why those
  /// are not the same thing.
  ///
  /// IMGMGR-473: RECORDED from the visible targets and RESTORED once, never bound. A
  /// `.scrollPosition(id:)` binding hands SwiftUI an id it keeps re-applying, and a mark inside an
  /// open scene was enough to make it re-snap the anchored row's top to the viewport's top — the
  /// whole grid dropped by however much of that row was cut off (+43.33 pt at 402x874). Nothing
  /// here scrolls except `restoreOrRecordScrollAnchor`'s one restore, so no later update can.
  ///
  /// The one-shot is per `ScrollView` lifetime (re-armed on disappear) and is consumed by the
  /// first visibility report that can act on it, before that report is recorded: a fresh
  /// `ScrollView` reports its top rows first, and recording them would overwrite the anchor it has
  /// yet to restore. While the saved photograph's page is still loading it stays armed
  /// (`GridScrollAnchor.restoreStep`).
  @State private var scrollAnchorRestored = false

  private func restoreOrRecordScrollAnchor(
    visible: [GridRenderRowID], proxy: ScrollViewProxy
  ) {
    guard !visible.isEmpty else { return }
    let topmost = GridScrollAnchor.topmostPhotograph(visible: visible, frames: tileFrames)
    if !scrollAnchorRestored {
      let step = GridScrollAnchor.restoreStep(
        saved: store.gridScrollAnchor, topmost: topmost, rows: renderRows,
        isLoading: store.isLoadingPage)
      switch step {
      case .wait:
        return
      case .scroll(let target):
        scrollAnchorRestored = true
        proxy.scrollTo(target, anchor: .top)
        return
      case .record:
        scrollAnchorRestored = true
      }
    }
    // A report with no tile row (headers only) keeps the last photograph, as the binding did.
    guard let topmost else { return }
    store.gridScrollAnchor = topmost
  }

  /// The packing inputs, and nothing a mark can move (`GridPackingKey`).
  private var packingKey: GridPackingKey {
    GridPackingKey(store: store, paneWidth: paneWidth, displayScale: displayScale)
  }

  /// A repack inside the same `ScrollView` (width, thumbnail size, sections) moves every row
  /// break, so the remembered photograph is put back at the top of the viewport in the NEW
  /// packing — what the old binding did by re-resolving on every pass, now done only when the
  /// packing actually changed. Runs from `onChange`, inside the update that changed the key and
  /// before the new layout's visibility report could record the rows now at the old offset.
  private func restoreAfterRepack(proxy: ScrollViewProxy) {
    let saved = store.gridScrollAnchor
    guard let target = GridScrollAnchor.row(containing: saved, in: renderRows) else { return }
    proxy.scrollTo(target, anchor: .top)
  }

  /// The scrollable justified grid, with the live pointer-drag gesture attached through
  /// `pointerGestureInstaller` rather than a bare `.gesture(...)` call — see that property's doc
  /// comment.
  private var scrollArea: some View {
    // R3-12: the same gutter the packer subtracts (`renderRows`), so the rendered gaps match.
    let gutter = GridGutter.spacing(for: store.rowHeight)
    let content = AnyView(
      ScrollViewReader { scrollProxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: gutter) {
            // Rows are identified by their LEADING cell's display id, never by index: with
            // index identity, a row-count shrink (entering/leaving Scene mode, collapsing a
            // stack) can leave SwiftUI evaluating a stale row body whose index no longer
            // exists, and the `packedRows[rowIndex]` subscript traps — the 0.7.0 (9) Scene
            // crash (EXC_BREAKPOINT in ForEachChild.updateValue, GridView.swift:115). A
            // leading-cell id is unique per layout (each cell packs into exactly one row)
            // and moves with its row across repacks, so diffing stays coherent.
            // WP13 P5b: the sequence is `GridRenderRow`, so a section header and a packed tile
            // row are the SAME `ForEach`'s elements with their own stable, non-index identities
            // (a header's is its group key; a tile row's stays its leading cell's display id).
            ForEach(renderRows) { renderRow in
              switch renderRow {
              case .header(let header):
                GroupSectionHeaderView(header: header)
              case .tiles(let rowModel):
                HStack(spacing: gutter) {
                  ForEach(rowModel.cells, id: \.id) { packed in
                    if let row = rowsByID[packed.id] {
                      cell(for: row, plan: packed.plan, cropsToFill: rowModel.squareEdge != nil)
                        // IMGMGR-551 (R3-7): a square row frames EVERY cell — display,
                        // placeholder, tombstone, scene card — at its edge, BEFORE the frame
                        // publisher below, so hit-testing records the square bounds.
                        .modifier(SquareCellFrame(edge: rowModel.squareEdge))
                        .background(
                          GeometryReader { proxy in
                            Color.clear.preference(
                              key: TileFramePreferenceKey.self,
                              value: [packed.id: proxy.frame(in: .named("gridSpace"))])
                          }
                        )
                        .onTapGesture { Task { await store.tapCell(packed.id) } }
                        .onLongPressGesture(minimumDuration: 0.5) {
                          store.longPressCell(packed.id)
                        }
                        .task(id: packed.id) { await page(from: packed.id) }
                    }
                  }
                }
              }
            }
          }
          .scrollTargetLayout()
          // The packer subtracts this on both sides (`GridGutter.packingWidth`).
          .padding(GridGutter.contentInset)
          // IMGMGR-469: at Regular the photographs continue under the floating sidebar. On the
          // scroll CONTENT only, never on a control or the bar (ADR-N1 Amendment 1).
          .gridBackgroundExtension(for: layoutMode)
        }
        // R3-12: a pure-black canvas behind the photographs, under the safe areas the content
        // already uses. The dark scheme is scoped to the scroll content, so headers and
        // placeholders (semantic styles) stay legible on black in light mode; the chrome rows,
        // the bar and the banners keep the system's scheme.
        .background(.black)
        .environment(\.colorScheme, .dark)
        // WP16 P2 (IMGMGR-298): the offset is kept in STORE-owned state, so it survives this view
        // being rebuilt — see `GridStore.gridScrollAnchor` for why the view cannot keep it itself.
        // IMGMGR-473: recorded here and restored once, never bound (see `scrollAnchorRestored`).
        // Near-zero threshold: a mostly clipped top row still counts as visible, so the recorded
        // photograph is the topmost PARTIALLY visible row, as the binding reported it.
        .onScrollTargetVisibilityChange(idType: GridRenderRowID.self, threshold: 0.01) { visible in
          restoreOrRecordScrollAnchor(visible: visible, proxy: scrollProxy)
        }
        .onChange(of: packingKey) { _, _ in restoreAfterRepack(proxy: scrollProxy) }
        .onDisappear { scrollAnchorRestored = false }
        .coordinateSpace(name: "gridSpace")
        .onPreferenceChange(TileFramePreferenceKey.self) { tileFrames = $0 }
      }
    )
    return pointerGestureInstaller.attach(
      content,
      { point in
        // WP12: a TYPED hit. A drag that crosses a scene card resolves to `.stack`, which the
        // store's drag lane cannot turn into a mark or a selection entry — the card contributes
        // nothing, exactly as it contributes nothing to `actionableImages`.
        guard let hitID = GridHitTest.displayID(at: point, in: tileFrames) else { return }
        Task { await store.pointerDragCrossed(hitID) }
      },
      { store.beginPointerDrag() }
    )
  }

  @ViewBuilder
  private func cell(
    for row: SceneDisplayRow, plan: TileRenderPlan, cropsToFill: Bool
  ) -> some View {
    switch row {
    case .image(let image):
      // IMGMGR-475: the quick-pick corner, only where it leaves the tile's centre to the tile.
      let cornerTileSize = QuickPickCorner.installedTileSize(plan: plan, missing: image.missing)
      let hasMarkCorner = cornerTileSize != nil
      TileView(
        image: image,
        plan: plan,
        isFocused: store.focusedImageID == image.id,
        isSelected: store.selection.members.contains(image.id),
        isSelectMode: store.selection.mode == .select,
        // WP13 P5a (IMGMGR-221): read here, in the one place that builds a tile, so the More
        // menu's toggle and what every tile draws are the same fact.
        showsFilenamePlate: store.preferences.filenamePlates,
        store: store,
        hasMarkCorner: hasMarkCorner,
        // R3-5 (IMGMGR-539): the Tile overlays toggles, read here for the same reason.
        overlays: TileOverlaySet(preferences: store.preferences),
        cropsToFill: cropsToFill
      )
      .overlay(alignment: .bottomTrailing) { bandHandle(forMember: image.id) }
      .overlay(alignment: .topTrailing) {
        if let cornerTileSize {
          MarkCornerTarget(
            imageID: image.id,
            tileSize: cornerTileSize,
            spokenValue: QuickPickCorner.accessibilityValue(
              mark: MarkStateValue(image.mark.state), isEdited: image.hasEdit == true,
              isGood: image.lightroom.good == true,
              isChangedElsewhere: store.changedElsewhereImageIDs.contains(image.id)),
            store: store)
        }
      }
    case .stack(let stackRow, let isExpanded):
      SceneCardView(
        row: stackRow, plan: plan, isExpanded: isExpanded, store: store, cropsToFill: cropsToFill
      )
      // Empty outside the DEBUG screenshot fixture, exactly like `tierProbeValue` on the More
      // control and for the same reason: the inline picks ship on Regular only (a measured
      // product decision — see `showsInlinePicks`), so the screenshot test has to STATE which
      // layout this destination resolved to and assert the branch the app actually took,
      // rather than infer a device — which the mac-gate's own idiom grep forbids outright.
      .accessibilityValue(sceneCardProbeValue)
      // IMGMGR-240: a SIBLING of the card, never a child — see `SceneExpandHandle`.
      .overlay(alignment: .bottomTrailing) {
        SceneExpandHandle(stackID: stackRow.stackId, isExpanded: isExpanded, store: store)
      }
      .overlay(alignment: .bottomLeading) { inlinePicks(for: stackRow) }
      .task(id: inlinePicksTaskID(for: stackRow)) {
        guard showsInlinePicks, stackRow.pickedCount >= 1 else { return }
        await store.loadInlinePicksIfNeeded(stackID: stackRow.stackId)
      }
    }
  }

  /// The close control for an OPEN band (IMGMGR-240).
  ///
  /// A band has no card to hang a control on — that is what replacing the card costs — so the
  /// handle is drawn over the band's LEADING member, the position the card's own handle occupied
  /// a moment before. Rendered for that one member and nothing else, so an open scene has exactly
  /// one handle however many rows its members reflow across.
  @ViewBuilder
  private func bandHandle(forMember imageID: Int) -> some View {
    if let stackID = bandLeads[imageID] {
      SceneExpandHandle(stackID: stackID, isExpanded: true, store: store)
    }
  }

  private var bandLeads: [Int: Int] {
    SceneRowBuilder.bandLeadMembers(expanded: store.sceneExpanded, members: store.sceneMembers)
  }

  /// IMGMGR-261, iPad-first (AC 3). The RULE lives in `SceneInlinePicksPolicy`, which is where
  /// the measurement behind it is written down and where a test pins the table directly.
  private var showsInlinePicks: Bool {
    SceneInlinePicksPolicy.isShown(
      layoutMode: layoutMode, isEnabled: store.preferences.picksInGroups)
  }

  @ViewBuilder
  private func inlinePicks(for row: Components.Schemas.StackBrowseStackRow) -> some View {
    if showsInlinePicks, let picks = store.sceneInlinePicks[row.stackId], !picks.isEmpty {
      SceneInlinePicksStrip(stackID: row.stackId, picks: picks, store: store)
    }
  }

  /// Re-runs the read when the SWITCH moves, when the scene's own pick count changes, or when a
  /// write DROPPED the cached summary (`refreshScenesFor`) — never on every body pass, and never
  /// at all while the preference is off.
  ///
  /// The third term is what makes an invalidated card refill itself. A count alone cannot: a
  /// batch that picks one member and un-picks another leaves `picked_count` unmoved while every
  /// thumbnail changes. Flipping back once the read lands is not a loop — the second run finds
  /// the entry present and returns immediately.
  private func inlinePicksTaskID(for row: Components.Schemas.StackBrowseStackRow) -> String {
    let hasSummary = store.sceneInlinePicks[row.stackId] != nil
    return "inlinePicks|\(row.stackId)|\(showsInlinePicks)|\(row.pickedCount)|\(hasSummary)"
  }

  private var sceneCardProbeValue: String {
    #if DEBUG
      guard DebugStubLaunch.isActive else { return "" }
      let layout: String
      switch layoutMode {
      case .compact: layout = "compact"
      case .regular2: layout = "regular2"
      case .regular3: layout = "regular3"
      }
      return "layout=\(layout) inlinePicks=\(showsInlinePicks)"
    #else
      return ""
    #endif
  }

  /// Appear-driven paging, routed by the cell's own kind. Each call is a no-op in the wrong mode
  /// (the store guards both), so the three questions — "page the flat grid", "page the scene
  /// stream", "page THIS scene's membership" — are asked at the one place that knows a cell just
  /// appeared, rather than needing three separate trigger mechanisms in the view.
  private func page(from id: GridDisplayID) async {
    if let imageID = id.imageID {
      await store.loadMoreIfNeeded(currentItemID: imageID)
      await store.loadMoreSceneMembersIfNeeded(afterMemberID: imageID)
    }
    await store.loadMoreScenesIfNeeded(currentRowID: id)
  }

  /// The one sequence this view renders, in both modes. Flat browse is the degenerate case of the
  /// same shape — every row an `.image` — so there is ONE packing pass, ONE frame dictionary and
  /// ONE gesture routing table rather than a parallel set per mode.
  private var displayRows: [SceneDisplayRow] {
    switch store.displayMode {
    case .flat: return store.images.map(SceneDisplayRow.image)
    case .scene: return store.sceneDisplayRows
    }
  }

  private var rowsByID: [GridDisplayID: SceneDisplayRow] {
    Dictionary(displayRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// The rendered sequence: section headers (when the server has vouched for them) interleaved
  /// with packed tile rows. Ungrouped, this is ONE packing pass over the whole stream and no
  /// headers at all — byte-for-byte the shipped behaviour. Grouped, `GridSectionLayout` packs
  /// each section on its own, so no justified row straddles a boundary.
  private var renderRows: [GridRenderRow] {
    let rows = displayRows
    let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return GridSectionLayout.renderRows(
      rows: rows,
      groupBy: store.activeGrouping.groupByKey,
      headers: store.groupHeaders,
      timezone: store.groupTimezone,
      paneWidth: GridGutter.packingWidth(forPane: paneWidth),
      targetRowHeight: store.rowHeight.rawValue, displayScale: displayScale,
      spacing: GridGutter.spacing(for: store.rowHeight),
      layout: store.layoutStyle
    ) { displayID, tier in
      guard let row = byID[displayID] else { return .missing }
      switch row {
      case .image(let image): return store.availability(for: image, tier: tier)
      // A card draws its representative, so its pixel availability IS the representative's.
      case .stack(let stackRow, _):
        return store.availability(for: stackRow.representative, tier: tier)
      }
    }
  }

  /// Arrow navigation's row table — TILE rows only. A header is not a photograph, so it never
  /// enters `GridStore.rows` (nor `actionableImages`, which this view does not feed at all);
  /// `GridRenderRow.packedRow` is the one way tiles come back out, which keeps that true by
  /// construction rather than by remembering to filter here.
  private func publishRows() {
    store.rows = GridSectionLayout.navigationRows(renderRows)
  }
}

/// WP13 P5b (IMGMGR-221 part 2): one section header, rendered from `GET /api/image-groups`'s own
/// `label`, `count` and (for a time key) `timezone`. Nothing here is computed from the loaded
/// page — a page holds part of a group, so a client-side tally would print the page's number
/// under the section's name.
///
/// DISPLAY-ONLY, the same boundary a collapsed scene card holds: not selectable, not focusable,
/// not arrow-navigable, and carrying no mark affordance. `allowsHitTesting(false)` makes that a
/// property of the view rather than of every gesture remembering to skip it.
struct GroupSectionHeaderView: View {
  let header: GroupHeaderRow

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(header.label)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
      Text("\(header.count)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      if let timezone = header.timezone {
        // Estate ADR-0007 (/link/2553): a rendered local time names its zone. Only the time
        // keys carry one; the server sends `timezone: null` for camera/lens/iso/location.
        Text(timezone)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 4)
    .padding(.top, 10)
    .padding(.bottom, 2)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(header.label), \(header.count) photographs")
    .accessibilityIdentifier("gridSectionHeader")
    .allowsHitTesting(false)
  }
}

/// One row of the grid's chrome stack, as a VALUE. WP13 P11 / IMGMGR-256.
///
/// Declared so the pinned order and — more to the point — what Scene mode does and does not add
/// are assertable without a render host. `GridView.chromeRows` renders exactly this list and holds
/// no second copy of it.
/// IMGMGR-256: there is NO Scene case here. Scene mode adds no chrome row of its own — the Group
/// control's highlighted state is what says "you are in an arrangement", and the behaviour the
/// removed caption described (a collapsed scene is not selectable, ADR-0005) is unchanged and
/// still proved by `GridStoreSceneTests`' boundary suite.
enum GridChromeRow: Hashable, Sendable {
  case options
  case pickLock(LatchVerb)
  case select
}

enum GridChromeRows {
  /// At most ONE mode row can render: a lock and Select are mutually exclusive in `GridStore`
  /// (`enterSelectExplicitly` and `longPressTile` both unlatch first), and `latchedVerb` is one
  /// value rather than two flags — the `else` below makes that a structural fact of the
  /// declaration rather than a coincidence two independent `if`s would let drift apart.
  @MainActor
  static func rows(layoutMode: LayoutMode, store: GridStore) -> [GridChromeRow] {
    var rows: [GridChromeRow] = []
    if layoutMode == .compact {
      rows.append(.options)
    }
    if let latchedVerb = store.pickLock.latchedVerb {
      rows.append(.pickLock(latchedVerb))
    } else if store.selection.mode == .select {
      rows.append(.select)
    }
    return rows
  }
}

/// WP14 (IMGMGR-251, IMGMGR-204/-250): the two states that used to happen in complete silence.
///
/// `lastPageLoadError` had no rendering consumer anywhere in the app sources — a failed reload
/// left the previous query's photographs standing with nothing to say so, and the reader had no
/// way to ask for another attempt. A write that lost ids to a racing refresh said even less.
/// Both are declared here as VALUES, in the same "declare it, then render the declaration"
/// shape `GridChromeRows` uses, so what the reader is actually told is a value test rather than
/// a reading of a `@ViewBuilder`.
enum GridNotice: Hashable, Sendable {
  /// The rows for the current query did not arrive; what is on screen is the previous query's.
  case pageLoadFailed
  /// Photographs a submitted write was no longer able to cover by the time it ran.
  case droppedWrites(count: Int)

  var message: String {
    switch self {
    case .pageLoadFailed:
      return "Couldn't load these photographs. Showing the last ones that loaded."
    case .droppedWrites(let count):
      return count == 1
        ? "1 photograph left this view before its mark was written — it was not written."
        : "\(count) photographs left this view before their marks were written — they were not written."
    }
  }

  var accessibilityIdentifier: String {
    switch self {
    case .pageLoadFailed: return "pageLoadErrorNotice"
    case .droppedWrites: return "droppedWritesNotice"
    }
  }
}

enum GridNotices {
  /// Ordered most-blocking first: a stream that is not the one the reader asked for outranks a
  /// write that covered fewer photographs than it was asked to.
  @MainActor
  static func notices(store: GridStore) -> [GridNotice] {
    var notices: [GridNotice] = []
    if store.lastPageLoadError != nil {
      notices.append(.pageLoadFailed)
    }
    if !store.droppedWriteIDs.isEmpty {
      notices.append(.droppedWrites(count: store.droppedWriteIDs.count))
    }
    return notices
  }
}

/// Renders EXACTLY `GridNotices.notices(store:)`, in its order, and holds no second list —
/// non-modal and beside the mark bar, the posture `ConflictRecoveryBanner` established (plan item
/// 3.7: "no alerts, no auto-opening popovers, no modality anywhere in this flow").
struct GridNoticeBanner: View {
  @Bindable var store: GridStore

  var body: some View {
    ForEach(GridNotices.notices(store: store), id: \.self) { notice in
      HStack(spacing: 12) {
        Label(notice.message, systemImage: "exclamationmark.triangle")
          .font(.footnote)
        Spacer()
        switch notice {
        case .pageLoadFailed:
          // The retry a reader had no way to ask for: `fullReload` is the same "same scope,
          // fresh data" entry point the foreground hook uses.
          Button("Retry") { Task { await store.fullReload() } }
            .font(.footnote)
            .disabled(store.isLoadingPage)
        case .droppedWrites:
          Button("Dismiss") { store.dismissDroppedWriteNotice() }
            .font(.footnote)
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 6)
      .background(.red.opacity(0.12))
      .accessibilityIdentifier(notice.accessibilityIdentifier)
    }
  }
}

/// Applies the prominent (tinted) button style only while an arrangement is in force. A
/// `ViewModifier` rather than a `@ViewBuilder if/else` on the whole control, because the two
/// branches of such an `if` are DIFFERENT view types to SwiftUI: the control would be torn down
/// and rebuilt on every grouping change, dismissing what it presents. WP29 P2 (IMGMGR-453): worn
/// by `GridArrangeControl`, which took over the removed Group control's IMGMGR-256 signal.
struct GroupControlHighlight: ViewModifier {
  let isHighlighted: Bool

  func body(content: Content) -> some View {
    content
      .fontWeight(isHighlighted ? .semibold : nil)
      .overlay(
        Capsule(style: .continuous)
          .strokeBorder(Color.accentColor.opacity(isHighlighted ? 0.9 : 0), lineWidth: 2)
          // Negative padding on an OVERLAY's own content: an overlay is laid out inside the
          // parent's frame and never propagates a size back, so the ring can sit just outside
          // the label without the control changing width, so the highlight never reflows the bar.
          .padding(-3)
      )
  }
}

/// WP13 P4 (IMGMGR-215): Compact's persistent view-options row. It reads Arrange · Filter ·
/// Triage: the Arrange control (WP29 P2, IMGMGR-453; its popover holds sort, grouping and
/// thumbnail size), the funnel, and the way into Triage (IMGMGR-462). IMGMGR-464 (WP32 P2)
/// removed the trailing keyboard-glyph "?" per the owner ruling of 2026-10-02: the shortcut sheet
/// opens with ⌘/ or `?` on a hardware keyboard and from the iPad menu bar, never from chrome.
/// Deliberately NOT a dense icon filter row (p3220 §2.2 must-not-copy #1) and deliberately not
/// a filter surface: filters live in the Stats segment (`InspectorView`), never in chrome.
struct GridOptionsRow: View {
  let store: GridStore

  var body: some View {
    HStack(spacing: 12) {
      // WP29 P1 (IMGMGR-452): the row renders `ShellToolbarLayout.compactOptionsRow` and holds
      // no second list, so "no identifier twice across the bar, this row and More" is a unit
      // test. Each control carries its OWN >=44 pt hit region, the same rule `ActionBarView`
      // already follows — never a single frame on the containing `HStack`.
      ForEach(ShellToolbarLayout.compactOptionsRow, id: \.self) { control in
        optionControl(control)
          .frame(minHeight: 44)
      }
      // The spacer that stood before the removed "?" (IMGMGR-464) now closes the row, so the
      // controls keep their leading positions and the row still spans the width.
      Spacer(minLength: 0)
    }
    .buttonStyle(.bordered)
    .font(.subheadline)
    // One line each, truncating at the tail, keeps every control's 44 pt hit region reachable —
    // the alternative (a label wrapping to two lines) grows the row and pushes its last control
    // off it.
    .lineLimit(1)
    .truncationMode(.tail)
    .padding(.horizontal)
    .padding(.vertical, 6)
    .chromeFill(.thinMaterial)
    // IMGMGR-509: `.contain` FIRST, then the row's identifier — the IMGMGR-280 order
    // `loupeMarkBar` and `compareDecisionBar` already follow. An identifier set on this HStack
    // WITHOUT `.contain` overrides its descendants': observed on the iPhone 17 Pro gate leg, both
    // controls came back as `identifier: 'gridOptionsRow'` and did not exist by their own names.
    // As a container the row keeps its identifier and the controls keep theirs, so a UI test can
    // find `gridTriageButton` INSIDE the row (`OptionsRowFitUITests`, the Triage helpers) rather
    // than anywhere in the app.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(Self.accessibilityIdentifier)
  }

  /// IMGMGR-509: the row's container identifier (see the note at the end of `body`).
  static let accessibilityIdentifier = "gridOptionsRow"

  /// One declared control. WP16 P3 (IMGMGR-295): the funnel is icon-only; `FilterPopoverUITests`
  /// asserts the row's last control (Triage since IMGMGR-464) is still hittable here — the "the
  /// row did not overflow" contract.
  @ViewBuilder
  private func optionControl(_ control: ShellToolbarControl) -> some View {
    switch control {
    case .arrange: GridArrangeControl(store: store)
    case .filter: GridFilterControl(store: store)
    // IMGMGR-462 (WP31 P3): the way into Triage, moved here from the navigation bar, where a
    // long title collapsed it into the bar's "More" overflow. The same control — identifier
    // `gridTriageButton`, disabled while nothing is actionable, `openTriage()` — and a visible
    // title and icon (the bordered row style shows both), so it is chrome, never a gesture.
    case .triage: GridTriageControl(store: store)
    // Not options-row members (`ShellToolbarLayout.compactOptionsRow`).
    case .info, .select, .more: EmptyView()
    }
  }
}

/// WP29 P1 (IMGMGR-452): Select, as a bar command — the same title, action and identifier the
/// More menu's Select row shipped with (`gridSelectCommand`), declared once here now that the
/// row is gone. Its title states the way OUT while Select is on, never a second "Select".
enum GridSelectCommand {
  static let accessibilityIdentifier = "gridSelectCommand"
  static let systemImage = "checkmark.circle"

  @MainActor
  static func title(_ store: GridStore) -> String {
    store.selection.mode == .select ? "Exit Select" : "Select"
  }

  @MainActor
  static func run(_ store: GridStore) {
    if store.selection.mode == .select {
      store.done()
    } else {
      store.enterSelectExplicitly()
    }
  }
}

/// WP29 P1 (IMGMGR-452): the bar's Select — Regular's trailing group, Compact's navigation bar
/// beside Info (`ShellToolbarLayout`).
struct GridSelectControl: View {
  let store: GridStore

  var body: some View {
    Button {
      GridSelectCommand.run(store)
    } label: {
      Label(GridSelectCommand.title(store), systemImage: GridSelectCommand.systemImage)
    }
    .accessibilityIdentifier(GridSelectCommand.accessibilityIdentifier)
  }
}

/// Fold item 5(b)'s exact caption and placement: a persistent mode row directly above the
/// bottom action bar, `Done` trailing, never overlaying a tile.
///
/// WP13 P2: ONE row for both locks, rendering the LATCHED VERB's own caption — a second row type
/// for Dislike would be two places for one rule, and the reader would have no way to tell from
/// the row which mark a tap is about to apply. The identifier is verb-neutral for the same
/// reason; the caption text is what distinguishes the two, and it is what the tests assert.
struct PickLockModeRow: View {
  let store: GridStore
  let verb: LatchVerb

  var body: some View {
    HStack {
      Text(PickLockCopy.caption(for: verb))
        .font(.subheadline)
        .accessibilityIdentifier("lockModeCaption")
      Spacer()
      Button("Done") { store.done() }
        .frame(minWidth: 44, minHeight: 44)
        // Named because "Done" is not unique on screen (a system keyboard accessory carries the
        // same label), and a UI test that matched on the label alone could drive the wrong one.
        .accessibilityIdentifier("lockModeDone")
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .chromeFill(.thinMaterial)
  }
}

/// Select mode's own persistent row, structurally identical to `PickLockModeRow` — same
/// `.thinMaterial` band, same `Done` trailing at ≥44×44, never overlaying a tile — so "you are in a
/// mode, here is what it acts on, and here is the way out" reads the same for every mode this
/// screen can be in. Before this row, the only exit from Select was an item in the More menu.
///
/// The count is stated at N = 0 too ("0 selected"), never replaced by an instructional caption
/// that hides it: an empty Select is exactly the state where every mark control refuses to
/// write, so the number is the thing that explains why they are dim. The instruction is a
/// second, subordinate line.
struct SelectModeRow: View {
  let store: GridStore

  var body: some View {
    HStack {
      Text(SelectCopy.caption(selectedCount: store.selectedCount))
        .font(.subheadline)
        .accessibilityIdentifier("selectModeCaption")
        .accessibilityValue("\(store.selectedCount)")
      if store.selectedCount == 0 {
        Text(SelectCopy.emptyHint)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("selectModeEmptyHint")
      }
      Spacer()
      // WP28 P4 (IMGMGR-451): the 44 pt sits on the LABEL, with a shape to hit — a frame outside
      // a borderless button grows only its layout slot, and the census measured the text alone
      // (40.5 × 20.5 pt, gate on bd47740). Nothing is drawn in it, so the row looks the same.
      Button {
        store.done()
      } label: {
        Text("Done")
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
      }
      .accessibilityIdentifier("selectModeDone")
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .chromeFill(.thinMaterial)
  }
}

extension View {
  /// Every bar control keeps its OWN — never the row's — 44×44 hit region (fold item 4),
  /// sized from the same constant the bar's width arithmetic uses, so no control can be given a
  /// target `ActionBarMetrics.requiredWidth` did not account for.
  fileprivate func actionBarControlSize() -> some View {
    let side = ActionBarMetrics.minimumControlSide
    return frame(minWidth: side, minHeight: side)
  }
}

/// How the action bar lays out at one width. A value type, not three properties read off the
/// view, so `ActionBarMetrics.layout(forWidth:)` is a pure function a test can walk tier by tier.
struct ActionBarLayout: Equatable {
  /// Only for evidence: the DEBUG fixture stamps it onto the More control's accessibility value
  /// so a gate attachment can say which tier actually rendered instead of leaving it to be
  /// inferred from pixel arithmetic.
  var name: String
  var spacing: CGFloat
  var horizontalPadding: CGFloat
  var controlCount: Int
  /// Below the six-control floor, Clear moves INTO the More menu — still a chrome control with
  /// its own identifier and disabled rule, never a gesture-only action, and never a control
  /// squeezed under 44 pt.
  var foldsClearIntoMore: Bool
  /// WP29 P1 (IMGMGR-452): whether this bar renders More. False on every Regular tier, where
  /// More is the grid bar's own item (`WorkspaceChromePlacement.actionBarCarriesMore`).
  var carriesMore: Bool = true
  /// WP29 P4 (IMGMGR-455): the Select bar — `… · Tag · Scene ‖ Undo` (`SelectBarLayout`).
  var selecting: Bool = false
  /// IMGMGR-475 review round 1: whether Tap to Pick shows its title beside its icon. Only where
  /// the width allows (`ActionBarMetrics.toggleTitleAllowance` is counted for it); icon-only on
  /// every tight or folded tier.
  var showsToggleTitle: Bool = false

  /// The controls this tier renders, in order — the one list `ActionBarView` walks.
  var controls: [SelectBarControl] {
    SelectBarLayout.controls(
      selecting: selecting, carriesMore: carriesMore, foldsClearIntoMore: foldsClearIntoMore)
  }
}

/// The action bar's geometry as DATA, so the view lays out with the same numbers a test checks
/// it against — no second, drifting declaration.
///
/// Two failures shaped this. Adding Clear made the bar SIX controls and the shipped 24-pt rhythm
/// stopped fitting an iPhone: 6×44 + 5×24 + 2×16 = 416 pt against 402. Then the iPad
/// landscape leg (gate GREEN-8) showed the roomy 376-pt layout does not fit the Regular-3 GRID
/// COLUMN either — the middle column of a three-pane split, whose width this app never pins
/// (`NavigationSplitView` sized it; since WP28 P3 the system inspector column narrows it).
/// So the bar no longer bets on a width at
/// all: it measures the one it is given and picks a tier — roomy, tight, or tight-with-Clear-
/// folded — each of which keeps every control at its full 44 pt.
enum ActionBarMetrics {
  /// The narrowest Compact width this app targets — the gate's own iPhone destination
  /// (iPhone 17 Pro, 402 pt portrait).
  static let narrowestCompactWidth: CGFloat = 402
  /// The narrowest WINDOW that resolves Regular-3, taken from the layout's own constant rather
  /// than restated here. The app pins no COLUMN widths — `NavigationSplitView` sizes them —
  /// so the grid column's share of this window is system-chosen.
  static let narrowestRegular3Window: CGFloat = LayoutResolver.regular3Threshold

  /// The grid column's actual width at Regular-3, MEASURED rather than guessed: the gate's
  /// landscape geometry attachment (GREEN-10, iPad Pro 13" landscape, window 1376×1032) shows
  /// the bar's six controls laid out to 374 pt with `Pick`'s frame at x = -13.5. A centred
  /// 374-pt row whose left edge lands at -29.5 (16 pt of padding before Pick) sits in a column
  /// of 374 - 2×29.5 = 315 pt. Recorded so the tier this column selects is a test, not a
  /// hypothesis; the runtime measurement is what the bar actually uses.
  static let measuredRegular3GridColumn: CGFloat = 315
  /// Fold item 4: every control keeps its OWN — never the row's — 44×44 hit region. This is
  /// the one number no tier is allowed to shrink.
  static let minimumControlSide: CGFloat = 44
  static let horizontalPadding: CGFloat = 16
  static let verticalPadding: CGFloat = 16
  static let controlSpacing: CGFloat = 16
  /// The narrow tier's gap and padding. Chosen so six full-size controls still fit 320 pt.
  static let tightSpacing: CGFloat = 8
  static let tightHorizontalPadding: CGFloat = 8
  /// Pick, Tap to Pick, Dislike, Clear, Undo, Tag, More — IMGMGR-475 added Tap to Pick beside
  /// Pick, which moved the 402-pt iPhone from the roomy tier to the tight one at rest.
  static let controlCount = 7
  /// The same bar with Clear folded into the More menu.
  static let foldedControlCount = 6
  /// IMGMGR-475: the narrowest gap any tier uses — six controls at it still fit the measured
  /// 315-pt Regular-3 column (6×44 + 5×4 + 2×8 = 300).
  static let narrowestSpacing: CGFloat = 4

  /// The width the bar needs for `controlCount` controls at `spacing`, all at their minimum
  /// side, including both paddings.
  static func requiredWidth(
    controlCount: Int = ActionBarMetrics.controlCount,
    spacing: CGFloat = ActionBarMetrics.controlSpacing,
    horizontalPadding: CGFloat = ActionBarMetrics.horizontalPadding
  ) -> CGFloat {
    CGFloat(controlCount) * minimumControlSide
      + CGFloat(max(controlCount - 1, 0)) * spacing
      + 2 * horizontalPadding
  }

  static let roomy = ActionBarLayout(
    name: "roomy", spacing: controlSpacing, horizontalPadding: horizontalPadding,
    controlCount: controlCount, foldsClearIntoMore: false)
  static let tight = ActionBarLayout(
    name: "tight", spacing: tightSpacing, horizontalPadding: tightHorizontalPadding,
    controlCount: controlCount, foldsClearIntoMore: false)
  static let folded = ActionBarLayout(
    name: "folded", spacing: tightSpacing, horizontalPadding: tightHorizontalPadding,
    controlCount: foldedControlCount, foldsClearIntoMore: true)
  /// IMGMGR-475: 6×44 + 5×4 + 2×8 = 300 pt — the folded bar at the narrowest gap, so the Compact
  /// bar still has a tier inside the measured 315-pt column (the folded tier alone is 320).
  static let foldedTight = ActionBarLayout(
    name: "folded-tight", spacing: narrowestSpacing, horizontalPadding: tightHorizontalPadding,
    controlCount: foldedControlCount, foldsClearIntoMore: true)

  /// IMGMGR-475 review round 1: the room Tap to Pick's visible title takes beyond its 44-pt
  /// slot — "Tap to Pick" in `.subheadline` plus the icon gap, rounded up. `ViewThatFits` still
  /// measures the real control, so an underestimate only ever picks a narrower tier.
  static let toggleTitleAllowance: CGFloat = 96

  /// WP29 P1 (IMGMGR-452): Regular's bar without More — Pick, Tap to Pick (IMGMGR-475),
  /// Dislike, Clear, Undo, Tag.
  static let regularControlCount = 6
  /// IMGMGR-475 review round 1: the roomy Regular bar with Tap to Pick's title shown —
  /// 376 + 96 = 472 pt.
  static let regularTitled = ActionBarLayout(
    name: "regular-titled", spacing: controlSpacing, horizontalPadding: horizontalPadding,
    controlCount: regularControlCount, foldsClearIntoMore: false, carriesMore: false,
    showsToggleTitle: true)
  /// 6×44 + 5×16 + 2×16 = 376 pt.
  static let regularRoomy = ActionBarLayout(
    name: "regular-roomy", spacing: controlSpacing, horizontalPadding: horizontalPadding,
    controlCount: regularControlCount, foldsClearIntoMore: false, carriesMore: false)
  /// 6×44 + 5×4 + 2×8 = 300 pt — inside the measured 315-pt Regular-3 column with the inspector
  /// expanded, so no Regular tier ever needs to fold Clear (at the 8-pt gap it would be 320).
  static let regularTight = ActionBarLayout(
    name: "regular-tight", spacing: narrowestSpacing, horizontalPadding: tightHorizontalPadding,
    controlCount: regularControlCount, foldsClearIntoMore: false, carriesMore: false)

  /// WP29 P4 (IMGMGR-455): the Select bar's tiers. Compact carries seven controls
  /// (`Pick · Dislike · Clear · Tag · Scene · More ‖ Undo`), six with Clear folded; Regular six,
  /// without More. The spacer before Undo is one more HStack child, so one more gap.
  static let selectControlCount = 7
  static let selectFoldedControlCount = 6
  static let regularSelectControlCount = 6
  /// The tight Regular Select tier's gap: 6×44 + 6×4 + 2×8 = 304 pt, inside the measured
  /// 315-pt Regular-3 column with the inspector expanded.
  static let regularSelectTightSpacing: CGFloat = narrowestSpacing

  /// 7×44 + 7×16 + 2×16 = 452 pt.
  static let selectRoomy = ActionBarLayout(
    name: "select-roomy", spacing: controlSpacing, horizontalPadding: horizontalPadding,
    controlCount: selectControlCount, foldsClearIntoMore: false, selecting: true)
  /// 7×44 + 7×8 + 2×8 = 380 pt — inside the 402-pt iPhone.
  static let selectTight = ActionBarLayout(
    name: "select-tight", spacing: tightSpacing, horizontalPadding: tightHorizontalPadding,
    controlCount: selectControlCount, foldsClearIntoMore: false, selecting: true)
  /// 6×44 + 6×8 + 2×8 = 328 pt, Clear in More under its bar identifier.
  static let selectFolded = ActionBarLayout(
    name: "select-folded", spacing: tightSpacing, horizontalPadding: tightHorizontalPadding,
    controlCount: selectFoldedControlCount, foldsClearIntoMore: true, selecting: true)
  /// 6×44 + 6×16 + 2×16 = 392 pt.
  static let regularSelectRoomy = ActionBarLayout(
    name: "regular-select-roomy", spacing: controlSpacing, horizontalPadding: horizontalPadding,
    controlCount: regularSelectControlCount, foldsClearIntoMore: false, carriesMore: false,
    selecting: true)
  static let regularSelectTight = ActionBarLayout(
    name: "regular-select-tight", spacing: regularSelectTightSpacing,
    horizontalPadding: tightHorizontalPadding, controlCount: regularSelectControlCount,
    foldsClearIntoMore: false, carriesMore: false, selecting: true)

  static let selectTiers: [ActionBarLayout] = [selectRoomy, selectTight, selectFolded]
  static let regularSelectTiers: [ActionBarLayout] = [regularSelectRoomy, regularSelectTight]

  /// Widest first. `ActionBarView` renders these in this order through `ViewThatFits`, and
  /// `layout(forWidth:)` walks the SAME list — so the arithmetic the tests assert and the tier
  /// the layout system actually picks cannot disagree.
  static let tiers: [ActionBarLayout] = [roomy, tight, folded, foldedTight]

  /// WP29 P1: the Regular tiers, widest first — the bar without More, and no fold.
  static let regularTiers: [ActionBarLayout] = [regularTitled, regularRoomy, regularTight]

  /// The tier list for a bar that does or does not carry More.
  static func tiers(carriesMore: Bool, selecting: Bool = false) -> [ActionBarLayout] {
    switch (carriesMore, selecting) {
    case (true, false): return tiers
    case (false, false): return regularTiers
    case (true, true): return selectTiers
    case (false, true): return regularSelectTiers
    }
  }

  /// The spacer before Undo (Select only) is one more HStack child, so it adds one gap.
  static func requiredWidth(for layout: ActionBarLayout) -> CGFloat {
    requiredWidth(
      controlCount: layout.controlCount, spacing: layout.spacing,
      horizontalPadding: layout.horizontalPadding)
      + (layout.controls.contains(.spacer) ? layout.spacing : 0)
      + (layout.showsToggleTitle ? toggleTitleAllowance : 0)
  }

  /// The narrowest width that still shows every at-rest Compact control, Clear included:
  /// 7×44 + 6×8 + 2×8 = 372 pt (IMGMGR-475; 320 with six controls before Tap to Pick).
  static var unfoldedFloor: CGFloat { requiredWidth(for: tight) }

  /// The narrowest width the folded bar needs: 6×44 + 5×4 + 2×8 = 300 pt.
  static var foldedFloor: CGFloat { requiredWidth(for: foldedTight) }

  /// The tier a given width selects — the arithmetic statement of what `ViewThatFits` decides
  /// at run time. Total: the narrowest tier is the answer when nothing fits, because a bar that
  /// must overflow should at least overflow least.
  static func layout(
    forWidth width: CGFloat, carriesMore: Bool = true, selecting: Bool = false
  ) -> ActionBarLayout {
    let list = tiers(carriesMore: carriesMore, selecting: selecting)
    return list.first { requiredWidth(for: $0) <= width } ?? list[list.count - 1]
  }
}

/// The three mark controls of the bar, as DATA. The point is the `state` property: a button that
/// named its own target state inline could be wired to the wrong one and every store-level test
/// would stay green (diff-gate round 1). The view renders from this table and
/// `clearAppliesToTheSelectionFromTheGridBar` writes through `ActionBarMarkControl.clear.state`,
/// so the button and its test cannot name different states.
enum ActionBarMarkControl: CaseIterable {
  case pick, dislike, clear

  var state: MarkStateValue {
    switch self {
    case .pick: return .pick
    case .dislike: return .dislike
    case .clear: return MarkStateValue.none
    }
  }

  var title: String {
    switch self {
    case .pick: return "Pick"
    case .dislike: return "Dislike"
    case .clear: return "Clear"
    }
  }

  var systemImage: String {
    switch self {
    case .pick: return "hand.thumbsup"
    case .dislike: return "hand.thumbsdown"
    // The loupe's own Clear already uses this symbol; one vocabulary for one verb.
    case .clear: return "xmark.circle"
    }
  }

  var accessibilityIdentifier: String { "grid\(title)Button" }

  /// The control that writes a given latch verb's mark. WP13 P2: the bar's two latch-capable
  /// buttons are rendered from this table exactly as before, so a verb can never be drawn with
  /// the wrong title, symbol or identifier.
  static func control(for verb: LatchVerb) -> ActionBarMarkControl {
    switch verb {
    case .pick: return .pick
    case .dislike: return .dislike
    }
  }

  /// The chrome twin for the double-tap latch gesture, in this control's own context menu:
  /// "Lock Pick" (shipped) and "Lock Dislike" (WP13 P2). Derived from `title` so the menu entry
  /// and the button can never name different verbs.
  var lockMenuTitle: String { "Lock \(title)" }
}

/// iPhone: `Pick · Dislike · Clear · Undo · Tag · More`. Persistent in every grid layout (P4
/// Approach). Clear joined it in WP13 P1: the ticket names Pick/Dislike/Clear as the Select-mode
/// actions, and the grid bar had no Clear — its only chrome surface was the loupe's mark bar.
/// Diff-gate round 2, blocker 2: EACH icon-only control carries its OWN ≥44×44 hit region — the
/// frame is never applied to the containing `HStack` alone.
struct ActionBarView: View {
  @Bindable var store: GridStore
  /// WP13 P11: forwarded straight through to `GridMoreMenuContent` — the bar itself never opens
  /// a window, it only carries the menu that does.
  let openShootWindow: ShootWindowOpener
  /// WP29 P1 (IMGMGR-452): `WorkspaceChromePlacement.actionBarCarriesMore` — true at Compact,
  /// false at Regular, where More is the grid bar's own item.
  var carriesMore: Bool = true

  /// Widest tier first — straight out of `ActionBarMetrics.tiers` — and the LAYOUT SYSTEM
  /// picks, not a measurement this view took. Every per-tier difference (its gap, its padding,
  /// whether Clear folds into the More menu) is data on the tier, so `bar(_:)` renders any
  /// entry of that list and there is nothing left for a hardcoded child to drift from.
  ///
  /// Two measured attempts failed the same way. A bar that overflows its column reports its own
  /// overflowing width, and plumbing `GridView`'s pane width in changed nothing: the gate's
  /// landscape attachment shows byte-identical geometry across both, a 16-pt (roomy) rhythm with
  /// `Pick` at x = -13.5 in a ~315-pt Regular-3 grid column. `ViewThatFits` asks the question the
  /// right way round — it proposes the CONTAINER's width to each child and takes the first that
  /// fits — so there is no first pass with a default width, no state to arrive late, and no way
  /// for the bar to paint wider than what it was handed.
  var body: some View {
    // IMGMGR-474: read ONCE per render and handed to every tier, rather than re-derived per
    // control per tier — it walks the actionable projection.
    let readout = store.markTargetReadout
    ViewThatFits(in: .horizontal) {
      // Derived FROM the list, never a hand-written copy of it beside the list: adding,
      // removing or reordering a tier changes what renders, by construction. Keyed by the
      // tier's own name, never by index (IMGMGR-210).
      ForEach(
        ActionBarMetrics.tiers(
          carriesMore: carriesMore, selecting: store.selection.mode == .select),
        id: \.name
      ) { tier in
        bar(tier, readout: readout)
      }
    }
    .frame(maxWidth: .infinity)
    .chromeFill(.bar)
    // WP30 P2 (IMGMGR-457): the grid hosts tag entry only while the loupe is closed; while it is
    // open the loupe hosts it (`TagEntryHost`), so the one flag never presents two sheets.
    .sheet(
      isPresented: Binding(
        get: { store.presentsTagEntry(on: .grid) },
        set: { store.isTagEntryPresented = $0 })
    ) {
      TagEntrySheet(store: store)
    }
    // WP13 P5a: hosted on the OUTER body beside tag entry, never on a `ViewThatFits` child —
    // a sheet declared per tier would be declared three times over.
    .sheet(isPresented: $store.isStatusPresented) {
      StatusSheet(store: store)
    }
    // WP14 P4: hosted here for the same reason the two above are — on the OUTER body, never on a
    // `ViewThatFits` child, which would declare each of them once per tier.
    // WP29 P4 (IMGMGR-455): Scene ▸ is the only opener of both pickers, so both re-check the
    // selection's agreement right before their shipped submit (R4-B1).
    .sheet(isPresented: $store.isSceneMergePickerPresented) {
      SceneMergePicker(
        store: store, submissionGuard: SceneSelectionAgreement.pickerGuard(for: .mergeFocusedScene))
    }
    // IMGMGR-347: the absorb's own target sheet, hosted beside its sibling for the same reason.
    .sheet(isPresented: $store.isSceneAbsorbPickerPresented) {
      SceneMergePicker(
        store: store, kind: .absorbLoosePhotograph,
        submissionGuard: SceneSelectionAgreement.pickerGuard(for: .absorbLoosePhotograph))
    }
    .sceneEditAlert(store: store)
  }

  /// One tier's rendering. Deliberately NOT `.frame(maxWidth: .infinity)`: a child that claims
  /// infinite width always "fits", which would make `ViewThatFits` pick the first one every
  /// time. Its ideal width is its content, which is exactly what has to be compared with the
  /// column.
  @ViewBuilder
  private func bar(_ layout: ActionBarLayout, readout: MarkTargetReadout) -> some View {
    HStack(spacing: layout.spacing) {
      // WP29 P4 (IMGMGR-455): the tier's own control list (`SelectBarLayout`), in order — at
      // rest exactly the shipped order, in Select `… · Tag · Scene (· More) ‖ Undo`.
      ForEach(layout.controls, id: \.self) { control in
        barControl(control, layout: layout, readout: readout)
      }
    }
    .labelStyle(.iconOnly)
    .font(.title3)
    .padding(.horizontal, layout.horizontalPadding)
    .padding(.vertical, ActionBarMetrics.verticalPadding)
  }

  @ViewBuilder
  private func barControl(
    _ control: SelectBarControl, layout: ActionBarLayout, readout: MarkTargetReadout
  ) -> some View {
    switch control {
    case .pick:
      latchButton(.pick, readout: readout)
    case .tapToPick:
      tapToPickToggle(showsTitle: layout.showsToggleTitle)
    case .dislike:
      latchButton(.dislike, readout: readout)
    case .clear:
      markControl(.clear, readout: readout)
    case .spacer:
      Spacer(minLength: 0)
    case .scene:
      sceneMenu()
    case .undo:
      Button {
        Task { await store.undoLastMark() }
      } label: {
        Label("Undo", systemImage: "arrow.uturn.backward")
      }
      .buttonStyle(.bordered)
      .disabled(!store.undo.canUndo)
      .accessibilityIdentifier("gridUndoButton")
      .actionBarControlSize()

    case .tag:
      Button {
        store.handleTagShortcut()
      } label: {
        Label("Tag", systemImage: "tag")
      }
      .buttonStyle(.bordered)
      .disabled(store.isMarkActionUnavailable)
      .accessibilityIdentifier("gridTagButton")
      .actionBarControlSize()

    case .more:
      // WP29 P1 (IMGMGR-452): only where the bar carries More — Compact. At Regular More is
      // the grid bar's own item (`GridToolbarMoreMenu`), never rendered twice.
      if layout.carriesMore {
        // WP13 P5a (IMGMGR-221): the decided set, rendered from `GridMoreMenu.entries` and from
        // nothing else — this view holds no second list of what the menu contains. It stays the
        // OVERFLOW: the action bar is at its 6-control limit (`ActionBarMetrics`) and Regular's
        // toolbar already carries three `.primaryAction` items, so no entry here becomes a bar
        // control.
        Menu {
          // WP13 P5a (IMGMGR-221) + P1 (IMGMGR-212), resolved as ONE composition: the decided
          // More set renders from `GridMoreMenu.entries`, and the fold is what the Clear ROW's
          // identity keys off — never a second Clear row beside it.
          GridMoreMenuContent(
            store: store, foldsClearIntoMore: layout.foldsClearIntoMore,
            openShootWindow: openShootWindow)
        } label: {
          Label("More", systemImage: "ellipsis.circle")
            // WP28 P4 (IMGMGR-451): this menu draws no capsule, so its hit target is the glyph
            // alone unless the label itself is sized — the `.actionBarControlSize()` below sits
            // OUTSIDE the control and grows only the layout slot. The same 44 pt, on the label,
            // with a shape to hit: nothing is drawn in it, so the bar looks the same.
            .actionBarControlSize()
            .contentShape(Rectangle())
        }
        // Named, because "More" is not unique on screen: Compact collapses the nav bar's own
        // secondaryAction toolbar items into an overflow control with the same label, and a UI
        // test that matched on the label alone could drive the wrong one.
        .accessibilityIdentifier("gridMoreMenu")
        // EVIDENCE, fixture-only: whichever tier `ViewThatFits` chose is the one that renders, so
        // the chosen child stamps its own name here and a gate attachment can report the tier
        // instead of inferring it from pixel deltas. Never set outside the DEBUG fixture launch.
        .accessibilityValue(tierProbeValue(layout))
        .actionBarControlSize()
      }
    }
  }

  /// WP29 P4 (IMGMGR-455): Scene ▸ — the scene edits' one touch home, rendered from
  /// `SelectBarSceneMenu.entries` through the More menu's own row view. The label is sized like
  /// More's (it draws no capsule either), so its hit region is the full 44 pt.
  private func sceneMenu() -> some View {
    Menu {
      ForEach(SelectBarSceneMenu.entries) { entry in
        GridMoreMenuItem(
          entry: entry, store: store, foldsClearIntoMore: false, openShootWindow: openShootWindow)
      }
    } label: {
      Label(SelectBarSceneMenu.title, systemImage: SelectBarSceneMenu.systemImage)
        .actionBarControlSize()
        .contentShape(Rectangle())
    }
    .accessibilityIdentifier(SelectBarSceneMenu.accessibilityIdentifier)
    .actionBarControlSize()
  }

  /// Empty outside the DEBUG screenshot fixture, so nothing about production accessibility
  /// changes: an empty accessibility value is what an unset one already is.
  private func tierProbeValue(_ layout: ActionBarLayout) -> String {
    #if DEBUG
      return DebugStubLaunch.isActive ? "tier=\(layout.name)" : ""
    #else
      return ""
    #endif
  }

  /// The one plain mark control (Clear). Pick and Dislike are not among them because each
  /// branches its presentation on the lock state, which needs two literal `Button` declarations
  /// (see `latchButton`) — all three still take their title, symbol and STATE from the same
  /// table.
  @ViewBuilder
  private func markControl(_ control: ActionBarMarkControl, readout: MarkTargetReadout)
    -> some View
  {
    let presentation = ActionBarMarkPresentation.for(
      control, lockState: store.pickLock.state, readout: readout)
    Button {
      Task { await store.applyMarkToTarget(control.state) }
    } label: {
      markLabel(control, presentation)
    }
    .buttonStyle(.bordered)
    // IMGMGR-474: Clear is selected when the target is unmarked. "No mark" has no mark colour, so
    // its selected fill is the accent it always carried; unselected, the fill is neutral.
    .tint(presentation.fillTint.color)
    .accessibilityAddTraits(presentation.isSelected ? .isSelected : [])
    .accessibilityValue(presentation.accessibilityValue)
    .disabled(store.isMarkActionUnavailable)
    .accessibilityIdentifier(control.accessibilityIdentifier)
    .actionBarControlSize()
  }

  /// IMGMGR-474: the icon a mark control draws for its presentation — the filled glyph while the
  /// target carries this mark, and a small badge while only part of a mixed selection does. The
  /// title stays the accessibility label; the state rides the control's value and trait.
  private func markLabel(
    _ control: ActionBarMarkControl, _ presentation: ActionBarMarkPresentation
  ) -> some View {
    MarkControlLabel(title: control.title, presentation: presentation)
  }

  /// The identifier goes on the node that CARRIES THE FRAME — after `.actionBarControlSize()`,
  /// so the element XCUITest resolves is the sized one. It sat on the wrapping `Group` first and
  /// then on the two concrete `Button`s, and the iPad leg reported the identical "Activation
  /// point invalid and no suggested hit points based on element frame" both times (gate GREEN-7
  /// and GREEN-8), which is what a frameless element looks like from the harness.
  ///
  /// Factored out because `.buttonStyle(_:)` requires a single CONCRETE style per call site —
  /// a ternary between `.borderedProminent` and `.bordered` does not type-check (they are
  /// different concrete `ButtonStyle` types) — so the two presentations are two literal button
  /// declarations sharing the same action/label/menu, branched once here instead.
  ///
  /// WP13 P2 (IMGMGR-222) makes this ONE builder for both latch-capable controls rather than a
  /// Pick-shaped one and a copy: the verb decides the store action, the presentation and the
  /// context-menu twin's title, so Dislike Lock cannot drift from Pick Lock by construction. No
  /// control is added to the bar — `ActionBarMetrics` is untouched and the six-control tiers are
  /// unchanged; Dislike simply stops being a plain button.
  @ViewBuilder
  private func latchButton(_ verb: LatchVerb, readout: MarkTargetReadout) -> some View {
    let control = ActionBarMarkControl.control(for: verb)
    // IMGMGR-474: the latch half is `PickButtonPresentation` unchanged; the readout half says
    // what the target already carries (filled glyph + selected, or the mixed badge).
    let presentation = ActionBarMarkPresentation.for(
      control, lockState: store.pickLock.state, readout: readout)
    Group {
      if presentation.isProminent {
        Button {
          Task { await store.activateLatchButton(verb) }
        } label: {
          markLabel(control, presentation)
        }
        .buttonStyle(.borderedProminent)
      } else {
        Button {
          Task { await store.activateLatchButton(verb) }
        } label: {
          markLabel(control, presentation)
        }
        .buttonStyle(.bordered)
      }
    }
    // WP16 P1 (p3332 decision 5): the tint SOURCE moves from the implicit accent colour to the
    // mark palette, for these two verbs only — Clear and Undo are not verdicts and keep theirs.
    // What each button STYLE does with a tint stays the system's business.
    // IMGMGR-474 review round 1: the FILL now says whether the control is selected — neutral
    // while plain, the mark colour while selected (`.bordered`) or latched (`.borderedProminent`,
    // solid). The glyph keeps the mark colour in both bordered states (`MarkControlLabel`), so
    // decision 5 still holds for the verb itself.
    .tint(presentation.fillTint.color)
    .accessibilityAddTraits(presentation.isSelected ? .isSelected : [])
    .accessibilityValue(presentation.accessibilityValue)
    // Select mode alone no longer disables these — it is P1's whole point. What stays disabled
    // is LOCK entry, in the context menu below and in the store's own guard.
    .disabled(store.isLatchControlDisabled)
    .actionBarControlSize()
    .accessibilityIdentifier(control.accessibilityIdentifier)
    .contextMenu {
      // Gate's unasked issue: the amendment's discoverable visible alternative to the
      // undiscoverable double-tap gesture — now on both controls (persistent-chrome rule: every
      // gesture has a chrome twin). Disabled while EITHER lock is on, which is the mutual
      // exclusion made visible rather than merely enforced.
      Button(control.lockMenuTitle) { store.lockFromMenu(verb) }
        .disabled(store.pickLock.latchedVerb != nil || store.selection.mode == .select)
    }
  }
}

extension ActionBarView {
  /// IMGMGR-475 option 1: the visible "Tap to Pick" toggle — Pick Lock surfaced as a control of
  /// its own beside Pick. It carries the same unmistakable pair the latched Pick does (solid
  /// `.borderedProminent` fill + the selected trait) while on, and the mode row's caption and Done
  /// appear exactly as for any Pick Lock. Disabled where it is inert (`TapToPickToggle.action`):
  /// under a Dislike lock, whose Done exits it. Never on the Select bar (`SelectBarLayout`).
  @ViewBuilder
  func tapToPickToggle(showsTitle: Bool) -> some View {
    let isOn = TapToPickToggle.isOn(store.pickLock.state)
    let isInert =
      TapToPickToggle.action(lockState: store.pickLock.state, mode: store.selection.mode) == .inert
    let label = Label(
      TapToPickToggle.title,
      systemImage: isOn ? "\(TapToPickToggle.systemImage).fill" : TapToPickToggle.systemImage)
    Group {
      if isOn {
        Button {
          store.toggleTapToPick()
        } label: {
          label
        }
        .buttonStyle(.borderedProminent)
      } else {
        Button {
          store.toggleTapToPick()
        } label: {
          label
        }
        .buttonStyle(.bordered)
      }
    }
    // Innermost style wins over the bar's `.iconOnly`, so only this control can show its title.
    .labelStyle(TapToPickLabelStyle(showsTitle: showsTitle))
    .tint(MarkPalette.color(for: LatchVerb.pick.markRole))
    .accessibilityLabel(TapToPickToggle.title)
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .accessibilityValue(isOn ? "On" : "Off")
    .disabled(isInert)
    .actionBarControlSize()
    .accessibilityIdentifier(TapToPickToggle.accessibilityIdentifier)
  }
}

/// IMGMGR-475 review round 1: Tap to Pick's label — icon and visible title on a tier that
/// counted room for it, the icon alone everywhere else. A system label style, no custom material.
struct TapToPickLabelStyle: LabelStyle {
  let showsTitle: Bool

  @ViewBuilder
  func makeBody(configuration: Configuration) -> some View {
    if showsTitle {
      HStack(spacing: 6) {
        configuration.icon
        configuration.title.font(.subheadline)
      }
    } else {
      configuration.icon
    }
  }
}

/// IMGMGR-474: a bar mark control's label — the filled glyph while the target carries this mark,
/// a small badge while only part of a mixed selection does, and the control's own colour on the
/// glyph in both bordered states. The title stays the accessibility label; the state rides the
/// control's value and trait. The colour override is dropped while DISABLED so the system's own
/// dimming still reads, exactly as it did before the override existed.
struct MarkControlLabel: View {
  let title: String
  let presentation: ActionBarMarkPresentation
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    let label = Label {
      Text(title)
    } icon: {
      Image(systemName: presentation.systemImage)
        .overlay(alignment: .topTrailing) {
          if presentation.showsMixedBadge {
            Image(systemName: ActionBarMarkPresentation.mixedBadgeSymbol)
              .font(.caption2.weight(.bold))
              .offset(x: 6, y: -6)
              .accessibilityHidden(true)
          }
        }
    }
    if isEnabled, let glyph = presentation.glyphTint {
      label.foregroundStyle(glyph.color)
    } else {
      label
    }
  }
}

/// WP13 P5a (IMGMGR-221): what "Copy for Lightroom" just did, stated where the reader is —
/// non-modal, same shape as `ConflictRecoveryBanner` beside it, never an alert. The text is
/// built by `MarksExportCopy.confirmation`, which is where the endpoint's real scope ("the
/// whole marked set, not the browse scope") and its truncation flag are turned into words.
struct MarksCopyBanner: View {
  @Bindable var store: GridStore

  var body: some View {
    if let message = store.marksCopyMessage {
      HStack(spacing: 12) {
        Label(message, systemImage: "doc.on.clipboard")
          .font(.footnote)
          .accessibilityIdentifier("marksCopyMessage")
        Spacer()
        Button("Dismiss") { store.dismissMarksCopyMessage() }
          .font(.footnote)
      }
      .padding(.horizontal)
      .padding(.vertical, 6)
      .chromeFill(.thinMaterial)
    }
  }
}

/// P6 (IMGMGR-116): the compact, non-modal 409 recovery surface (plan item 3.7 — "no alerts, no
/// auto-opening popovers, no modality anywhere in this flow"), shown beside the mark bar in BOTH
/// the grid (here, above `ActionBarView`) and the loupe (`LoupeView.swift`, above
/// `LoupeMarkBar`). Nil `conflictRecovery` renders nothing.
struct ConflictRecoveryBanner: View {
  @Bindable var store: GridStore

  var body: some View {
    switch store.conflictRecovery {
    case nil:
      EmptyView()
    case .reading:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Checking for changes elsewhere…")
          .font(.footnote)
      }
      .padding(.horizontal)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .chromeFill(.thinMaterial)
      .accessibilityIdentifier("conflictRecoveryReading")
    case .identified:
      HStack(spacing: 12) {
        Label("Changed elsewhere", systemImage: "arrow.triangle.2.circlepath")
          .font(.footnote)
        Spacer()
        Button("Keep Server Version") { store.dismissConflictRecovery() }
          .font(.footnote)
        Button("Apply Again") { Task { await store.applyConflictAgain() } }
          .font(.footnote)
          .buttonStyle(.borderedProminent)
          .disabled(store.isMutatingMark)
      }
      .padding(.horizontal)
      .padding(.vertical, 6)
      .background(.orange.opacity(0.15))
      .accessibilityIdentifier("conflictRecoveryIdentified")
    case .readFailed:
      HStack(spacing: 12) {
        Label("Couldn't refresh", systemImage: "exclamationmark.triangle")
          .font(.footnote)
        Spacer()
        Button("Retry Refresh") { Task { await store.retryConflictRefresh() } }
          .font(.footnote)
          .disabled(store.isMutatingMark)
      }
      .padding(.horizontal)
      .padding(.vertical, 6)
      .background(.red.opacity(0.12))
      .accessibilityIdentifier("conflictRecoveryReadFailed")
    }
  }
}

struct TagEntrySheet: View {
  let store: GridStore
  @State private var tag = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        TextField("Tag", text: $tag)
      }
      .navigationTitle("Add tag")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") {
            let targets = store.tagTargetImageIDs
            let value = tag
            dismiss()
            Task { await store.addTag(value, to: targets) }
          }
          .disabled(tag.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
  }
}

/// IMGMGR-551 (R3-7): a Square-layout row's cell frame — `edge × edge` — or, for a justified row
/// (`edge == nil`), the identity, so a justified cell is laid out exactly as before.
///
/// Deliberately NOT clipped: the cell's own overlays — the focus ring, the expanded card's stroke —
/// straddle its edge and draw in full, as in justified. What could overflow clips itself instead:
/// the centre-cropped photograph and scene-card cover (`CentreCrop`, after their own `size` frame);
/// placeholders and tombstones are rectangles that fill the proposed frame and cannot overflow.
private struct SquareCellFrame: ViewModifier {
  let edge: CGFloat?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let edge {
      content.frame(width: edge, height: edge)
    } else {
      content
    }
  }
}
