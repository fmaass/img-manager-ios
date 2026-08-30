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
      // Pinned order: the Scene row above the mode row, the mode row above the recovery banner,
      // the banner above the action bar. At most ONE of the two mode rows can ever render —
      // Pick Lock and Select are mutually exclusive in `GridStore` (`enterSelectExplicitly` and
      // `longPressTile` both unlatch first), and the `else if` makes that a structural fact of
      // this view rather than a coincidence two independent `if`s would let drift apart.
      if store.displayMode == .scene {
        SceneModeRow(store: store)
      }
      if store.pickLock.state == .latched {
        PickLockModeRow(store: store)
      } else if store.selection.mode == .select {
        SelectModeRow(store: store)
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
      ToolbarItem(placement: .secondaryAction) {
        // Scene is a MODE, not a `group_by` wire value — it calls a different endpoint with a
        // different row vocabulary. It lives in a Group menu anyway because that is where a
        // reader looks for "how is this stream arranged", and because the two entries are
        // mutually exclusive by construction when they share one single-select list.
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
          Label("Group", systemImage: "square.stack")
        }
        .accessibilityIdentifier("gridGroupMenu")
      }
      ToolbarItem(placement: .secondaryAction) {
        // Diff-gate round 2, blocker 2: the six native row-height steps must be reachable —
        // this is their one real UI call site.
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
          Label("Zoom", systemImage: "square.grid.2x2")
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

/// The action bar's geometry as DATA, so the view lays out with the same numbers a test checks
/// it against — no second, drifting declaration. Adding Clear made the bar SIX controls, and the
/// shipped 24-pt rhythm no longer fits: 6×44 + 5×24 + 2×16 = 416 pt against a 402-pt Compact
/// width, which clips the edge controls out of their required 44-pt reachable region. The gap is
/// 16 pt instead, for 376 pt, and `ActionBarMetricsTests` fails if that stops being true.
enum ActionBarMetrics {
  /// The narrowest Compact width this app targets — the gate's own iPhone destination
  /// (iPhone 17 Pro, 402 pt portrait). A bar that fits here fits every wider layout.
  static let narrowestCompactWidth: CGFloat = 402
  /// Fold item 4: every control keeps its OWN — never the row's — 44×44 hit region.
  static let minimumControlSide: CGFloat = 44
  static let horizontalPadding: CGFloat = 16
  static let verticalPadding: CGFloat = 16
  static let controlSpacing: CGFloat = 16
  /// Pick, Dislike, Clear, Undo, Tag, More. Kept beside the layout it describes; the retained
  /// screenshot test asserts each of the six is present AND hittable at Compact width, which is
  /// what catches a seventh control being added without re-checking this arithmetic.
  static let controlCount = 6

  /// The width the bar needs for `controlCount` controls at `spacing`, all at their minimum
  /// side, including both paddings.
  static func requiredWidth(
    controlCount: Int = ActionBarMetrics.controlCount,
    spacing: CGFloat = ActionBarMetrics.controlSpacing
  ) -> CGFloat {
    CGFloat(controlCount) * minimumControlSide
      + CGFloat(max(controlCount - 1, 0)) * spacing
      + 2 * horizontalPadding
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
}

/// iPhone: `Pick · Dislike · Clear · Undo · Tag · More`. Persistent in every grid layout (P4
/// Approach). Clear joined it in WP13 P1: the ticket names Pick/Dislike/Clear as the Select-mode
/// actions, and the grid bar had no Clear — its only chrome surface was the loupe's mark bar.
/// Diff-gate round 2, blocker 2: EACH icon-only control carries its OWN ≥44×44 hit region — the
/// frame is never applied to the containing `HStack` alone.
struct ActionBarView: View {
  @Bindable var store: GridStore

  var body: some View {
    HStack(spacing: ActionBarMetrics.controlSpacing) {
      let presentation = PickButtonPresentation.for(store.pickLock.state)
      pickButton(presentation: presentation)

      markControl(.dislike)
      markControl(.clear)

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

      Menu {
        Button(store.selection.mode == .select ? "Exit Select" : "Select") {
          if store.selection.mode == .select {
            store.done()
          } else {
            store.enterSelectExplicitly()
          }
        }
        // Identified because its LABEL changes with the mode, and because a menu item inside a
        // popover is not addressable by label on every idiom (Regular-3 — see
        // SelectModeScreenshotUITests).
        .accessibilityIdentifier("gridSelectCommand")
      } label: {
        Label("More", systemImage: "ellipsis.circle")
      }
      // Named, because "More" is not unique on screen: Compact collapses the nav bar's own
      // secondaryAction toolbar items into an overflow control with the same label, and a UI
      // test that matched on the label alone could drive the wrong one.
      .accessibilityIdentifier("gridMoreMenu")
      .actionBarControlSize()
    }
    .labelStyle(.iconOnly)
    .font(.title3)
    .padding(.horizontal, ActionBarMetrics.horizontalPadding)
    .padding(.vertical, ActionBarMetrics.verticalPadding)
    .background(.bar)
    .sheet(isPresented: $store.isTagEntryPresented) {
      TagEntrySheet(store: store)
    }
  }

  /// The two plain mark controls (Dislike, Clear). Pick is not one of them only because its
  /// presentation branches on the lock state, which needs two literal `Button` declarations
  /// (see `pickButton`) — it still takes its title, symbol and STATE from the same table.
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
  @ViewBuilder
  private func pickButton(presentation: PickButtonPresentation) -> some View {
    let pick = ActionBarMarkControl.pick
    Group {
      if presentation.isProminent {
        Button {
          Task { await store.activatePickButton() }
        } label: {
          Label(pick.title, systemImage: pick.systemImage)
        }
        .buttonStyle(.borderedProminent)
      } else {
        Button {
          Task { await store.activatePickButton() }
        } label: {
          Label(pick.title, systemImage: pick.systemImage)
        }
        .buttonStyle(.bordered)
      }
    }
    .accessibilityAddTraits(presentation.accessibilitySelected ? .isSelected : [])
    // Select mode alone no longer disables Pick — it is the phase's whole point. What stays
    // disabled is Pick LOCK entry, in the context menu below and in the store's own guard.
    .disabled(store.isPickControlDisabled)
    .actionBarControlSize()
    .accessibilityIdentifier(pick.accessibilityIdentifier)
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
