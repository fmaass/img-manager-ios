import ImgManagerAPI
import SwiftUI

/// The contact-sheet grid: justified rows, the Pick Lock mode row when latched, and the
/// persistent bottom action bar. Present in every layout mode — Compact and Regular alike
/// (the inspector is what differs by layout mode, not this view).
struct GridView: View {
  @Bindable var store: GridStore
  @Environment(\.displayScale) private var displayScale
  @State private var paneWidth: CGFloat = 0

  var body: some View {
    VStack(spacing: 0) {
      if store.pickLock.state == .latched {
        PickLockModeRow(store: store)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(packedRows.indices, id: \.self) { rowIndex in
            HStack(spacing: 2) {
              ForEach(packedRows[rowIndex], id: \.imageID) { packed in
                if let image = imagesByID[packed.imageID] {
                  TileView(
                    image: image,
                    plan: plan(for: image),
                    isFocused: store.focusedImageID == image.id,
                    isSelected: store.selection.members.contains(image.id),
                    isSelectMode: store.selection.mode == .select,
                    store: store
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
  }

  private var imagesByID: [Int: Components.Schemas.ImageSummary] {
    Dictionary(uniqueKeysWithValues: store.images.map { ($0.id, $0) })
  }

  private var packedRows: [[PackedTile]] {
    JustifiedRowLayout.pack(
      tiles: store.images.map { JustifiedTile(imageID: $0.id, aspectRatio: $0.aspectRatio ?? 1.0) },
      paneWidth: paneWidth, targetRowHeight: store.rowHeight.rawValue)
  }

  private func publishRows() {
    store.rows = packedRows.map { $0.map(\.imageID) }
  }

  private func plan(for image: Components.Schemas.ImageSummary) -> TileRenderPlan {
    GridTierResolver.plan(
      aspectRatio: image.aspectRatio ?? 1.0, rowHeight: store.rowHeight,
      displayScale: displayScale,
      availability: { store.availability(for: image, tier: $0) })
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
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.thinMaterial)
  }
}

/// iPhone: `Pick · Dislike · Undo · Tag · More`. Persistent in every grid layout (P4 Approach).
struct ActionBarView: View {
  @Bindable var store: GridStore

  var body: some View {
    HStack(spacing: 24) {
      Button {
        Task { await store.activatePickButton() }
      } label: {
        Label("Pick", systemImage: "hand.thumbsup")
      }
      .accessibilityAddTraits(store.pickLock.state == .latched ? .isSelected : [])
      .tint(store.pickLock.state == .latched ? .accentColor : nil)
      .disabled(store.selection.mode == .select)

      Button {
        guard let id = store.focusedImageID else { return }
        Task { await store.applyMark(.dislike, to: [id]) }
      } label: {
        Label("Dislike", systemImage: "hand.thumbsdown")
      }

      Button {
        Task { await store.undoLastMark() }
      } label: {
        Label("Undo", systemImage: "arrow.uturn.backward")
      }
      .disabled(!store.undo.canUndo)

      Button {
        store.handleTagShortcut()
      } label: {
        Label("Tag", systemImage: "tag")
      }
      .disabled(store.tagTargetImageIDs.isEmpty)

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
    }
    .labelStyle(.iconOnly)
    .font(.title3)
    .frame(minHeight: 44)
    .padding()
    .background(.bar)
    .sheet(isPresented: $store.isTagEntryPresented) {
      TagEntrySheet(store: store)
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
