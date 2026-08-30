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

  var body: some View {
    VStack(spacing: 0) {
      // WP13 P4 (IMGMGR-215): Compact's persistent options row sits immediately below the
      // navigation bar — above the transient mode rows, because it is the one row that is
      // always there. On Regular the same two controls are `.primaryAction` toolbar items
      // (see `.toolbar` below); they are never rendered in both places at once.
      if layoutMode == .compact {
        GridOptionsRow(store: store)
      }
      if store.pickLock.state == .latched {
        PickLockModeRow(store: store)
      }
      if store.displayMode == .scene {
        SceneModeRow(store: store)
      }
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
      ActionBarView(store: store)
    }
    .onChange(of: store.images) { _, _ in publishRows() }
    .onChange(of: store.sceneRows) { _, _ in publishRows() }
    .onChange(of: store.sceneExpanded) { _, _ in publishRows() }
    .onChange(of: store.sceneMembers) { _, _ in publishRows() }
    .onChange(of: store.rowHeight) { _, _ in publishRows() }
    .toolbar {
      // WP13 P4 (IMGMGR-215): on Regular the two view-option controls are PRIMARY toolbar
      // items. They used to be `ToolbarItem(placement: .secondaryAction)`, which collapses
      // into the nav bar's overflow chevron — the gap the owner reported and the audit
      // confirmed in code (/link/3282, owner feedback (c)). Compact has no room for them
      // beside Account and Info, so there they are the options row above instead.
      if layoutMode != .compact {
        ToolbarItem(placement: .primaryAction) {
          GridGroupControl(store: store)
        }
        ToolbarItem(placement: .primaryAction) {
          GridZoomControl(store: store)
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
          ForEach(packedRowModels) { rowModel in
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
        store: store
      )
    case .stack(let stackRow, let isExpanded):
      SceneCardView(row: stackRow, plan: plan, isExpanded: isExpanded, store: store)
    }
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

  /// One rendered grid row with a STABLE identity: its leading cell's display id. See the
  /// ForEach comment in `scrollArea` — index identity is what crashed 0.7.0 (9). An empty
  /// packed row cannot exist (a row exists because tiles were packed into it), and
  /// `packedRowModels` drops one defensively rather than inventing an identity for it.
  private struct PackedRow: Identifiable, Equatable {
    let id: GridDisplayID
    let cells: [PackedTilePlan]
  }

  private var packedRowModels: [PackedRow] {
    packedRows.compactMap { row in row.first.map { PackedRow(id: $0.id, cells: row) } }
  }

  private var packedRows: [[PackedTilePlan]] {
    let rows = displayRows
    let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return JustifiedRowLayout.packWithTierPlan(
      tiles: rows.map { JustifiedTile(id: $0.id, aspectRatio: $0.aspectRatio) },
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

  private func publishRows() {
    store.rows = packedRows.map { $0.map(\.id) }
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
      Button {
        Task { await store.setDisplayMode(.flat) }
      } label: {
        if store.displayMode == .flat {
          Label("None", systemImage: "checkmark")
        } else {
          Text("None")
        }
      }
      Button {
        Task { await store.setDisplayMode(.scene) }
      } label: {
        if store.displayMode == .scene {
          Label("Scene", systemImage: "checkmark")
        } else {
          Text("Scene")
        }
      }
    } label: {
      Label(Self.title(for: store.displayMode), systemImage: "square.stack")
    }
    // The value has to stay VISIBLE, not just present in the accessibility label: a nav-bar
    // `Label` renders icon-only by default, and an icon-only menu is precisely what the owner
    // could not find (gap audit /link/3282, owner feedback (c)). Observed on the iPad Pro 13"
    // simulator before this line existed — the two toolbar items showed a box and a 2x2 grid
    // and nothing else. No effect on Compact's options row, where a `Label` in a plain HStack
    // already draws both.
    .labelStyle(.titleAndIcon)
    .accessibilityIdentifier("gridGroupControl")
  }

  /// A pure function so the value-in-label contract is testable without a render host.
  static func title(for mode: GridDisplayMode) -> String {
    switch mode {
    case .flat: return "Group: None"
    case .scene: return "Group: Scene"
    }
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
      GridGroupControl(store: store)
        .frame(minHeight: 44)
      GridZoomControl(store: store)
        .frame(minHeight: 44)
      Spacer()
      GridShortcutHelpControl(store: store)
        .frame(minHeight: 44)
    }
    .buttonStyle(.bordered)
    .font(.subheadline)
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

/// Scene mode's own persistent caption row, directly above the grid — the same shape and
/// placement `PickLockModeRow` uses for the other mode this screen can be in, so "you are in a
/// mode, and here is the way out" reads identically either way. Never an overlay on a tile.
struct SceneModeRow: View {
  let store: GridStore

  var body: some View {
    HStack {
      Label("Scene view — collapsed scenes are not selectable", systemImage: "square.stack")
        .font(.subheadline)
        .accessibilityIdentifier("sceneModeCaption")
      Spacer()
      Button("Exit") { Task { await store.setDisplayMode(.flat) } }
        .frame(minWidth: 44, minHeight: 44)
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.thinMaterial)
  }
}

/// Fold item 5(b)'s exact caption and placement: a persistent mode row directly above the
/// bottom action bar, `Done` trailing, never overlaying a tile.
struct PickLockModeRow: View {
  let store: GridStore

  var body: some View {
    HStack {
      Text(PickLockCopy.caption)
        .font(.subheadline)
        .accessibilityIdentifier("pickLockCaption")
      Spacer()
      Button("Done") { store.done() }
        .frame(minWidth: 44, minHeight: 44)
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.thinMaterial)
  }
}

/// iPhone: `Pick · Dislike · Undo · Tag · More`. Persistent in every grid layout (P4 Approach).
/// Diff-gate round 2, blocker 2: EACH icon-only control carries its OWN ≥44×44 hit region — the
/// frame is never applied to the containing `HStack` alone.
struct ActionBarView: View {
  @Bindable var store: GridStore

  var body: some View {
    HStack(spacing: 24) {
      let presentation = PickButtonPresentation.for(store.pickLock.state)
      pickButton(presentation: presentation)

      Button {
        guard let id = store.focusedImageID else { return }
        Task { await store.applyMark(.dislike, to: [id]) }
      } label: {
        Label("Dislike", systemImage: "hand.thumbsdown")
      }
      .buttonStyle(.bordered)
      .frame(minWidth: 44, minHeight: 44)

      Button {
        Task { await store.undoLastMark() }
      } label: {
        Label("Undo", systemImage: "arrow.uturn.backward")
      }
      .buttonStyle(.bordered)
      .disabled(!store.undo.canUndo)
      .frame(minWidth: 44, minHeight: 44)

      Button {
        store.handleTagShortcut()
      } label: {
        Label("Tag", systemImage: "tag")
      }
      .buttonStyle(.bordered)
      .disabled(store.tagTargetImageIDs.isEmpty)
      .frame(minWidth: 44, minHeight: 44)

      Menu {
        Button(store.selection.mode == .select ? "Exit Select" : "Select") {
          if store.selection.mode == .select {
            store.done()
          } else {
            store.enterSelectExplicitly()
          }
        }
      } label: {
        Label("More", systemImage: "ellipsis.circle")
      }
      .frame(minWidth: 44, minHeight: 44)
    }
    .labelStyle(.iconOnly)
    .font(.title3)
    .padding()
    .background(.bar)
    .sheet(isPresented: $store.isTagEntryPresented) {
      TagEntrySheet(store: store)
    }
  }

  /// Factored out because `.buttonStyle(_:)` requires a single CONCRETE style per call site —
  /// a ternary between `.borderedProminent` and `.bordered` does not type-check (they are
  /// different concrete `ButtonStyle` types) — so the two presentations are two literal button
  /// declarations sharing the same action/label/menu, branched once here instead.
  @ViewBuilder
  private func pickButton(presentation: PickButtonPresentation) -> some View {
    Group {
      if presentation.isProminent {
        Button {
          Task { await store.activatePickButton() }
        } label: {
          Label("Pick", systemImage: "hand.thumbsup")
        }
        .buttonStyle(.borderedProminent)
      } else {
        Button {
          Task { await store.activatePickButton() }
        } label: {
          Label("Pick", systemImage: "hand.thumbsup")
        }
        .buttonStyle(.bordered)
      }
    }
    .accessibilityAddTraits(presentation.accessibilitySelected ? .isSelected : [])
    .disabled(store.selection.mode == .select)
    .frame(minWidth: 44, minHeight: 44)
    .contextMenu {
      // Gate's unasked issue: the amendment's discoverable visible "Lock Pick" alternative to
      // the undiscoverable double-tap gesture.
      Button("Lock Pick") { store.lockPickFromMenu() }
        .disabled(store.pickLock.state == .latched || store.selection.mode == .select)
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
