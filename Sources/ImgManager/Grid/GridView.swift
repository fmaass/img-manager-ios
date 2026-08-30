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
        Task { await store.applyMarkToTarget(.dislike) }
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
