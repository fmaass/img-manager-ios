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
  @State private var tileFrames: [Int: CGRect] = [:]

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
      scrollArea
        .onGeometryChange(for: CGFloat.self) {
          $0.size.width
        } action: { width in
          paneWidth = width
          publishRows()
        }
        .overlay {
          if store.images.isEmpty && !store.isLoadingPage {
            ContentUnavailableView("No photographs", systemImage: "photo.on.rectangle")
          }
        }
      ActionBarView(store: store)
    }
    .onChange(of: store.images) { _, _ in publishRows() }
    .onChange(of: store.rowHeight) { _, _ in publishRows() }
    .toolbar {
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
          ForEach(packedRows.indices, id: \.self) { rowIndex in
            HStack(spacing: 2) {
              ForEach(packedRows[rowIndex], id: \.imageID) { packed in
                if let image = imagesByID[packed.imageID] {
                  TileView(
                    image: image,
                    plan: packed.plan,
                    isFocused: store.focusedImageID == image.id,
                    isSelected: store.selection.members.contains(image.id),
                    isSelectMode: store.selection.mode == .select,
                    store: store
                  )
                  .background(
                    GeometryReader { proxy in
                      Color.clear.preference(
                        key: TileFramePreferenceKey.self,
                        value: [packed.imageID: proxy.frame(in: .named("gridSpace"))])
                    }
                  )
                  .onTapGesture { Task { await store.tapTile(image.id) } }
                  .onLongPressGesture(minimumDuration: 0.5) {
                    store.longPressTile(image.id)
                  }
                  .task(id: image.id) {
                    await store.loadMoreIfNeeded(currentItemID: image.id)
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
        guard let hitID = GridHitTest.imageID(at: point, in: tileFrames) else { return }
        Task { await store.pointerDragCrossed(hitID) }
      },
      { store.beginPointerDrag() }
    )
  }

  private var imagesByID: [Int: Components.Schemas.ImageSummary] {
    Dictionary(uniqueKeysWithValues: store.images.map { ($0.id, $0) })
  }

  private var packedRows: [[PackedTilePlan]] {
    JustifiedRowLayout.packWithTierPlan(
      tiles: store.images.map { JustifiedTile(imageID: $0.id, aspectRatio: $0.aspectRatio ?? 1.0) },
      paneWidth: paneWidth, targetRowHeight: store.rowHeight.rawValue, displayScale: displayScale
    ) { imageID, tier in
      guard let image = imagesByID[imageID] else { return .missing }
      return store.availability(for: image, tier: tier)
    }
  }

  private func publishRows() {
    store.rows = packedRows.map { $0.map(\.imageID) }
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
