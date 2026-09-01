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
      // WP13 P5b: the header set arrives from its own fetch AFTER the page, and it is what
      // turns one packing pass into per-section passes — so the row table has to be rebuilt
      // when it lands, or arrow navigation would keep describing the unsectioned layout.
      .onChange(of: store.groupHeaders) { _, _ in publishRows() }
      .toolbar { toolbarContent }
  }

  /// Compact's persistent options row and the transient mode rows, in their pinned order.
  ///
  /// WP13 P4 (IMGMGR-215): the options row sits immediately below the navigation bar — above
  /// the transient mode rows, because it is the one row that is always there. On Regular the
  /// same controls are `.primaryAction` toolbar items (see `toolbarContent`); they are never
  /// rendered in both places at once.
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
          }
        }
      ConflictRecoveryBanner(store: store)
      GridNoticeBanner(store: store)
      MarksCopyBanner(store: store)
      ActionBarView(store: store, openShootWindow: openShootWindow)
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
      }
    }
  #else
    private var debugProbeElement: some View { EmptyView() }
  #endif

  /// WP13 P4 (IMGMGR-215): on Regular the view-option controls are PRIMARY toolbar items. They
  /// used to be `ToolbarItem(placement: .secondaryAction)`, which collapses into the nav bar's
  /// overflow chevron — the gap the owner reported and the audit confirmed in code (/link/3282,
  /// owner feedback (c)). Compact has no room for them beside Account and Info, so there they
  /// are the options row above instead.
  ///
  /// WP13 P5b adds Sort, leading: it is the control a reader reaches for first when asking "how
  /// is this stream arranged", and `SortGroupScreenshotUITests` asserts on both idioms that no
  /// overflow chevron came back as a result.
  @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
    if layoutMode != .compact {
      ToolbarItem(placement: .primaryAction) {
        GridSortControl(store: store)
      }
      ToolbarItem(placement: .primaryAction) {
        GridGroupControl(store: store)
      }
      ToolbarItem(placement: .primaryAction) {
        GridZoomControl(store: store)
      }
      // WP16 P3 (IMGMGR-295), decision 1: the FIFTH primary item. It sits with the view options
      // rather than after the help button because filtering is what a reader reaches for in the
      // same breath as sort and group. Its named risk is that a fifth item tips this bar into an
      // overflow chevron — `FilterPopoverUITests` asserts the chevron's absence with a positive
      // control, the same shape `SortGroupScreenshotUITests` used when Sort became the fourth.
      ToolbarItem(placement: .primaryAction) {
        GridFilterControl(store: store)
      }
      // Regular's route into the shortcut help sheet. The gate's UI leg proved the other two
      // routes are not drivable there — ⌘/ never reached the app on the iPad simulator
      // (no attached hardware keyboard) and the system menu bar is not a surface a UI test
      // can open — so without this the sheet had no chrome path and no rendered evidence on
      // Regular at all. Compact carries the same control in its options row.
      ToolbarItem(placement: .primaryAction) {
        GridShortcutHelpControl(store: store)
      }
    }
  }

  /// The scrollable justified grid, with the live pointer-drag gesture attached through
  /// `pointerGestureInstaller` rather than a bare `.gesture(...)` call — see that property's doc
  /// comment.
  private var scrollArea: some View {
    let content = AnyView(
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
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
              HStack(spacing: 2) {
                ForEach(rowModel.cells, id: \.id) { packed in
                  if let row = rowsByID[packed.id] {
                    cell(for: row, plan: packed.plan)
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
        .padding(2)
      }
      .coordinateSpace(name: "gridSpace")
      .onPreferenceChange(TileFramePreferenceKey.self) { tileFrames = $0 }
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
  private func cell(for row: SceneDisplayRow, plan: TileRenderPlan) -> some View {
    switch row {
    case .image(let image):
      TileView(
        image: image,
        plan: plan,
        isFocused: store.focusedImageID == image.id,
        isSelected: store.selection.members.contains(image.id),
        isSelectMode: store.selection.mode == .select,
        // WP13 P5a (IMGMGR-221): read here, in the one place that builds a tile, so the More
        // menu's toggle and what every tile draws are the same fact.
        showsFilenamePlate: store.preferences.filenamePlates,
        store: store
      )
      .overlay(alignment: .bottomTrailing) { bandHandle(forMember: image.id) }
    case .stack(let stackRow, let isExpanded):
      SceneCardView(row: stackRow, plan: plan, isExpanded: isExpanded, store: store)
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
      paneWidth: paneWidth, targetRowHeight: store.rowHeight.rawValue, displayScale: displayScale
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

/// WP13 P4 (IMGMGR-215): the Group control — ONE definition, rendered either as a Regular
/// `.primaryAction` toolbar item or inside Compact's persistent options row. Its label carries
/// the CURRENT VALUE ("Group: Scene"), which is the discoverability half of this ticket: an
/// icon-only menu behind an overflow chevron is exactly what the owner could not find.
///
/// Scene is a MODE, not a `group_by` wire value (ADR-0005 decision 6) — it calls a different
/// endpoint with a different row vocabulary. It lives in a Group menu anyway because that is
/// where a reader looks for "how is this stream arranged", and because the two entries are
/// mutually exclusive by construction when they share one single-select list.
struct GridGroupControl: View {
  let store: GridStore

  var body: some View {
    Menu {
      // WP13 P5b: ONE single-select list over `GroupingChoice` — None, Scene, then the six
      // offered `group_by` dimensions. Exclusivity is structural: `GroupingChoice` cannot
      // express "Scene and Camera", and every row calls the same coordinator, which is what
      // makes choosing a dimension while Scene is on actually LEAVE Scene (ADR-0005 decision 6)
      // instead of setting a wire parameter the stacks endpoint never reads.
      ForEach(SortGroupOptions.groupingChoices, id: \.self) { choice in
        Button {
          Task { await store.selectGrouping(choice) }
        } label: {
          if store.activeGrouping == choice {
            Label(Self.rowTitle(for: choice), systemImage: "checkmark")
          } else {
            Text(Self.rowTitle(for: choice))
          }
        }
      }
    } label: {
      Label(
        Self.title(for: store.activeGrouping),
        systemImage: Self.isHighlighted(for: store.activeGrouping)
          ? "square.stack.fill" : "square.stack")
    }
    // IMGMGR-256: the control itself is now the "you are in an arrangement" signal — the Scene
    // caption row it replaces is gone. The treatment is VALUE-driven inside one view type (a
    // filled symbol variant, a semibold label, an accent ring drawn as an overlay), never an
    // `if/else` over two different view types: SwiftUI would tear the `Menu` down and rebuild it
    // on every grouping change, closing it mid-interaction. Nothing here changes the control's
    // size, at rest or highlighted.
    .modifier(GroupControlHighlight(isHighlighted: Self.isHighlighted(for: store.activeGrouping)))
    // The value has to stay VISIBLE, not just present in the accessibility label: a nav-bar
    // `Label` renders icon-only by default, and an icon-only menu is precisely what the owner
    // could not find (gap audit /link/3282, owner feedback (c)). Observed on the iPad Pro 13"
    // simulator before this line existed — the two toolbar items showed a box and a 2x2 grid
    // and nothing else. No effect on Compact's options row, where a `Label` in a plain HStack
    // already draws both.
    .labelStyle(.titleAndIcon)
    .accessibilityIdentifier("gridGroupControl")
    // Machine-readable highlight state, and a genuine VoiceOver improvement rather than a probe:
    // "Group: Camera, Active" states in words what the tint states in pixels.
    .accessibilityValue(
      Self.isHighlighted(for: store.activeGrouping) ? "Active" : "Off")
  }

  /// IMGMGR-256: the control renders highlighted whenever ANY arrangement is in force — Scene or
  /// one of the six dimensions — and plain under None. A pure function, so the state is a value
  /// test rather than a screenshot reading.
  static func isHighlighted(for choice: GroupingChoice) -> Bool {
    choice != .none
  }

  /// A pure function so the value-in-label contract is testable without a render host.
  static func title(for choice: GroupingChoice) -> String {
    "Group: \(rowTitle(for: choice))"
  }

  /// One menu row's own words — the same string the label above wraps, so the row a reader
  /// picked and the value they then read back cannot be spelled differently.
  static func rowTitle(for choice: GroupingChoice) -> String {
    switch choice {
    case .none: return "None"
    case .scene: return "Scene"
    case .key(let key): return key.title
    }
  }
}

/// Applies the prominent (tinted) button style only while an arrangement is in force. A
/// `ViewModifier` rather than a `@ViewBuilder if/else` on the whole `Menu`, because the two
/// branches of such an `if` are DIFFERENT view types to SwiftUI: the menu would be torn down and
/// rebuilt on every grouping change, closing itself mid-interaction.
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
          // the label without the control changing width — which is what keeps
          // `SortGroupScreenshotUITests`' no-overflow assertion answering the same question.
          .padding(-3)
      )
  }
}

/// WP13 P5b (IMGMGR-221 part 2): the Sort control — the same shape as `GridGroupControl`, and
/// rendered in the same two places (a Regular `.primaryAction` toolbar item, Compact's persistent
/// options row). Its label carries the CURRENT key AND direction ("Sort: Rating ↓"), because the
/// ticket's own words are "nothing gesture-only" and an icon-only control behind an overflow
/// chevron is what the owner could not find (gap audit /link/3282, owner feedback (c)).
///
/// Six of the server's fifteen keys and both directions (`SortGroupOptions`) — the offered subset
/// is data, so a different six is a one-line change here and in its subset test, never a rework.
struct GridSortControl: View {
  let store: GridStore

  var body: some View {
    Menu {
      Section("Sort by") {
        ForEach(SortGroupOptions.sortKeys, id: \.self) { key in
          Button {
            Task { await store.setSortKey(key) }
          } label: {
            if store.activeSortKey == key {
              Label(key.title, systemImage: "checkmark")
            } else {
              Text(key.title)
            }
          }
        }
      }
      Section("Direction") {
        ForEach(SortGroupOptions.directions, id: \.self) { direction in
          Button {
            Task { await store.setSortDirection(direction) }
          } label: {
            if store.activeDirection == direction {
              Label(direction.title, systemImage: "checkmark")
            } else {
              Text(direction.title)
            }
          }
        }
      }
    } label: {
      Label(
        Self.title(for: store.activeSortKey, direction: store.activeDirection),
        systemImage: "arrow.up.arrow.down")
    }
    .labelStyle(.titleAndIcon)
    .accessibilityIdentifier("gridSortControl")
  }

  static func title(for key: SortKey, direction: SortDirection) -> String {
    "Sort: \(key.title) \(direction.arrow)"
  }
}

/// WP13 P4 (IMGMGR-215): the Zoom control, the same shape as `GridGroupControl` above and the
/// six native row-height steps' one real UI call site (diff-gate round 2, blocker 2). The
/// menu-bar View menu declares the same six steps as ⌘1…⌘6 (`AppCommands.zoomDeclarations`),
/// dispatching to this same `GridStore.setRowHeight`.
struct GridZoomControl: View {
  let store: GridStore

  var body: some View {
    Menu {
      ForEach(GridRowHeight.allCases, id: \.self) { step in
        Button {
          store.setRowHeight(step)
        } label: {
          if store.rowHeight == step {
            Label("\(Int(step.rawValue)) pt", systemImage: "checkmark")
          } else {
            Text("\(Int(step.rawValue)) pt")
          }
        }
      }
    } label: {
      Label(Self.title(for: store.rowHeight), systemImage: "square.grid.2x2")
    }
    .labelStyle(.titleAndIcon)
    .accessibilityIdentifier("gridZoomControl")
  }

  static func title(for step: GridRowHeight) -> String {
    "Zoom: \(Int(step.rawValue)) pt"
  }
}

/// WP13 P4 (IMGMGR-215): Compact's persistent view-options row — one row, two menu buttons
/// each labelled with its current value so the state is readable without opening anything, and
/// (diff-gate r1 blocker 3) the trailing shortcut-help button that is Compact's only route into
/// the help sheet.
/// Deliberately NOT a dense icon filter row (p3220 §2.2 must-not-copy #1) and deliberately not
/// a filter surface: filters live in the Stats segment (`InspectorView`), never in chrome.
struct GridOptionsRow: View {
  let store: GridStore

  var body: some View {
    HStack(spacing: 12) {
      // Each control carries its OWN >=44 pt hit region, the same rule `ActionBarView`
      // already follows — never a single frame on the containing `HStack`.
      GridSortControl(store: store)
        .frame(minHeight: 44)
      GridGroupControl(store: store)
        .frame(minHeight: 44)
      GridZoomControl(store: store)
        .frame(minHeight: 44)
      // WP16 P3 (IMGMGR-295): Compact's copy of the funnel. Icon-only like the help button, so it
      // adds one 44 pt hit region and no value label to a row whose three value-carrying controls
      // already truncate at the tail — the measurement the phase was told to make before letting a
      // fifth control onto this row. `FilterPopoverUITests` asserts the help button is still
      // hittable here, which is the "the row did not overflow" contract in one assertion.
      GridFilterControl(store: store)
        .frame(minHeight: 44)
      Spacer(minLength: 0)
      GridShortcutHelpControl(store: store)
        .frame(minHeight: 44)
    }
    .buttonStyle(.bordered)
    .font(.subheadline)
    // WP13 P5b: Sort joined Group and Zoom on this one row, so three value-carrying labels now
    // share a phone's width. One line each, truncating at the tail, keeps every control's
    // 44 pt hit region and its checkmarked menu reachable — the alternative (a label wrapping
    // to two lines) grows the row and pushes the help button off it.
    .lineLimit(1)
    .truncationMode(.tail)
    .padding(.horizontal)
    .padding(.vertical, 6)
    .background(.thinMaterial)
    // NO `.accessibilityIdentifier` on this HStack: an identifier set on a container OVERRIDES
    // its descendants'. Observed on the iPhone 17 Pro gate leg — both controls came back as
    // `identifier: 'gridOptionsRow'` and neither `gridGroupControl` nor `gridZoomControl`
    // existed, so the row's own two controls were unaddressable. The controls are what anything
    // needs to name; the row is just where they sit on Compact.
  }
}

/// WP13 P4 (IMGMGR-215), diff-gate r1 blocker 3: the chrome path INTO the shortcut help sheet,
/// rendered on both layouts — Compact's options row and Regular's `.primaryAction` toolbar.
/// Every other route the plan names — the menu-bar View menu, `?`, ⌘/ — needs a hardware
/// keyboard or the menu bar, neither of which exists on a phone and neither of which the gate's
/// simulators supplied, so without this the sheet was unreachable and had no rendered evidence.
/// Deliberately NOT a fourth entry in the More menu: that menu's contents are P5a's decided set
/// (IMGMGR-221) and this phase does not get to pre-empt them.
///
/// Calls the same `GridStore.showShortcutHelp()` the `?`/⌘/ declarations dispatch into, so the
/// button and the shortcut cannot drift apart.
struct GridShortcutHelpControl: View {
  let store: GridStore

  var body: some View {
    Button {
      store.showShortcutHelp()
    } label: {
      Label("Keyboard shortcuts", systemImage: "keyboard")
    }
    // Icon-only ON PURPOSE here, unlike Group/Zoom: it carries no value to read, and the row's
    // job is the two view options — this is the help affordance beside them, not a third one.
    .labelStyle(.iconOnly)
    .accessibilityLabel("Keyboard shortcuts")
    .accessibilityIdentifier("gridShortcutHelpControl")
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
    .background(.thinMaterial)
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
      Button("Done") { store.done() }
        .frame(minWidth: 44, minHeight: 44)
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.thinMaterial)
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
}

/// The action bar's geometry as DATA, so the view lays out with the same numbers a test checks
/// it against — no second, drifting declaration.
///
/// Two failures shaped this. Adding Clear made the bar SIX controls and the shipped 24-pt rhythm
/// stopped fitting an iPhone: 6×44 + 5×24 + 2×16 = 416 pt against 402. Then the iPad
/// landscape leg (gate GREEN-8) showed the roomy 376-pt layout does not fit the Regular-3 GRID
/// COLUMN either — the middle column of a three-pane split, whose width this app never pins
/// (`NavigationSplitView` sizes it, `.prominentDetail`). So the bar no longer bets on a width at
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
  /// Pick, Dislike, Clear, Undo, Tag, More.
  static let controlCount = 6
  /// The same bar with Clear folded into the More menu.
  static let foldedControlCount = 5

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

  /// Widest first. `ActionBarView` renders these in this order through `ViewThatFits`, and
  /// `layout(forWidth:)` walks the SAME list — so the arithmetic the tests assert and the tier
  /// the layout system actually picks cannot disagree.
  static let tiers: [ActionBarLayout] = [roomy, tight, folded]

  static func requiredWidth(for layout: ActionBarLayout) -> CGFloat {
    requiredWidth(
      controlCount: layout.controlCount, spacing: layout.spacing,
      horizontalPadding: layout.horizontalPadding)
  }

  /// The narrowest width that still shows all six controls: 6×44 + 5×8 + 2×8 = 320 pt.
  static var sixControlFloor: CGFloat { requiredWidth(for: tight) }

  /// The narrowest width the folded bar needs: 5×44 + 4×8 + 2×8 = 268 pt.
  static var foldedFloor: CGFloat { requiredWidth(for: folded) }

  /// The tier a given width selects — the arithmetic statement of what `ViewThatFits` decides
  /// at run time. Total: the narrowest tier is the answer when nothing fits, because a bar that
  /// must overflow should at least overflow least.
  static func layout(forWidth width: CGFloat) -> ActionBarLayout {
    tiers.first { requiredWidth(for: $0) <= width } ?? folded
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
    ViewThatFits(in: .horizontal) {
      // Derived FROM the list, never a hand-written copy of it beside the list: adding,
      // removing or reordering a tier changes what renders, by construction. Keyed by the
      // tier's own name, never by index (IMGMGR-210).
      ForEach(ActionBarMetrics.tiers, id: \.name) { tier in
        bar(tier)
      }
    }
    .frame(maxWidth: .infinity)
    .background(.bar)
    .sheet(isPresented: $store.isTagEntryPresented) {
      TagEntrySheet(store: store)
    }
    // WP13 P5a: hosted on the OUTER body beside tag entry, never on a `ViewThatFits` child —
    // a sheet declared per tier would be declared three times over.
    .sheet(isPresented: $store.isStatusPresented) {
      StatusSheet(store: store)
    }
    // WP14 P4: hosted here for the same reason the two above are — on the OUTER body, never on a
    // `ViewThatFits` child, which would declare each of them once per tier.
    .sheet(isPresented: $store.isSceneMergePickerPresented) {
      SceneMergePicker(store: store)
    }
    .sceneEditAlert(store: store)
  }

  /// One tier's rendering. Deliberately NOT `.frame(maxWidth: .infinity)`: a child that claims
  /// infinite width always "fits", which would make `ViewThatFits` pick the first one every
  /// time. Its ideal width is its content, which is exactly what has to be compared with the
  /// column.
  @ViewBuilder
  private func bar(_ layout: ActionBarLayout) -> some View {
    HStack(spacing: layout.spacing) {
      latchButton(.pick)
      latchButton(.dislike)
      if !layout.foldsClearIntoMore {
        markControl(.clear)
      }

      Button {
        Task { await store.undoLastMark() }
      } label: {
        Label("Undo", systemImage: "arrow.uturn.backward")
      }
      .buttonStyle(.bordered)
      .disabled(!store.undo.canUndo)
      .accessibilityIdentifier("gridUndoButton")
      .actionBarControlSize()

      Button {
        store.handleTagShortcut()
      } label: {
        Label("Tag", systemImage: "tag")
      }
      .buttonStyle(.bordered)
      .disabled(store.isMarkActionUnavailable)
      .accessibilityIdentifier("gridTagButton")
      .actionBarControlSize()

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
    .labelStyle(.iconOnly)
    .font(.title3)
    .padding(.horizontal, layout.horizontalPadding)
    .padding(.vertical, ActionBarMetrics.verticalPadding)
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
  private func markControl(_ control: ActionBarMarkControl) -> some View {
    Button {
      Task { await store.applyMarkToTarget(control.state) }
    } label: {
      Label(control.title, systemImage: control.systemImage)
    }
    .buttonStyle(.bordered)
    .disabled(store.isMarkActionUnavailable)
    .accessibilityIdentifier(control.accessibilityIdentifier)
    .actionBarControlSize()
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
  private func latchButton(_ verb: LatchVerb) -> some View {
    let control = ActionBarMarkControl.control(for: verb)
    let presentation = PickButtonPresentation.for(store.pickLock.state, control: verb)
    Group {
      if presentation.isProminent {
        Button {
          Task { await store.activateLatchButton(verb) }
        } label: {
          Label(control.title, systemImage: control.systemImage)
        }
        .buttonStyle(.borderedProminent)
      } else {
        Button {
          Task { await store.activateLatchButton(verb) }
        } label: {
          Label(control.title, systemImage: control.systemImage)
        }
        .buttonStyle(.bordered)
      }
    }
    // WP16 P1 (p3332 decision 5): the tint SOURCE moves from the implicit accent colour to the
    // mark palette, for these two verbs only — Clear and Undo are not verdicts and keep theirs.
    // What each button STYLE does with a tint stays the system's business.
    .tint(MarkPalette.color(for: verb.markRole))
    .accessibilityAddTraits(presentation.accessibilitySelected ? .isSelected : [])
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
      .background(.thinMaterial)
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
      .background(.thinMaterial)
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
