import ImgManagerAPI
import SwiftUI

/// The culling surface itself, presented differently per `LayoutMode` BY DESIGN (spec §"Loupe /
/// cull"). One view, branched only on `layoutMode` — never on the device-idiom API, whose very
/// NAME is banned from this tree by a mac-gate absence grep (plan invariant (i)):
///
/// - `.compact`: no filmstrip, no full-screen toggle control (the presenting view —
///   `RootView` — always shows this full-screen here already).
/// - `.regular2`/`.regular3`: a filmstrip below the main image (same `GridStore.images`/
///   `loadMoreIfNeeded`, never a filmstrip-local page — fold's "one paging path" pivot) and a
///   full-screen toggle button in the header.
///
/// Pixels: `.preview` tier only (spec: "the loupe never requests originals") — this view never
/// requests `.grid` for its own main image (the filmstrip's thumbnails do, same as `TileView`).
struct LoupeView: View {
  @Bindable var store: GridStore
  let layoutMode: LayoutMode
  /// The share lane's pre-flight, owned by `RootView` so ONE instance spans the docked and the
  /// full-screen presentations of this same loupe (they are mutually exclusive but swap freely,
  /// and a prepared export must not be lost — or leaked — across that swap).
  let share: ShareExportStore
  @State private var proxyImage: PlatformImage?

  private var focusedImage: Components.Schemas.ImageSummary? {
    guard let id = store.focusedImageID else { return nil }
    return store.images.first { $0.id == id }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      ShareStatusBar(share: share)
      mainImageArea
      if layoutMode != .compact {
        FilmstripView(store: store)
      }
      ConflictRecoveryBanner(store: store)
      LoupeMarkBar(store: store)
    }
    .task(id: store.focusedImageID) {
      // A prepared export names the photograph it was made from, so it never outlives that
      // photograph being the focused one — the temp file is deleted the moment focus moves
      // (gate correction 4), not left behind for whatever the user shares next.
      share.finish()
      await loadMainImage()
    }
  }

  private var header: some View {
    HStack {
      Button {
        store.closeLoupe()
      } label: {
        Image(systemName: "xmark")
      }
      .frame(minWidth: 44, minHeight: 44)
      .accessibilityIdentifier("loupeClose")

      Spacer()

      // Always visible, in every loupe state (spec) — including when `focusedImage` is nil
      // (nothing loaded yet), which `LoupeFidelityLabel.label(sourceKind:)`'s own `nil` branch
      // already renders as the SAME visible fallback a present-but-unrecognized value would.
      Text(LoupeFidelityLabel.label(sourceKind: focusedImage?.sourceKind))
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("loupeFidelityLabel")

      Spacer()

      // Both idioms — on Compact this is the only trailing control, which is exactly the point:
      // sharing is reachable from persistent chrome on the phone too, not just where there is
      // room for a toolbar full of things.
      ShareControl(share: share, image: focusedImage)

      if layoutMode != .compact {
        Button {
          store.toggleLoupeFullScreen()
        } label: {
          Image(
            systemName: store.isLoupeFullScreen
              ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityIdentifier("loupeFullScreenToggle")
      }
    }
    .padding(.horizontal)
  }

  private var mainImageArea: some View {
    ZStack {
      Group {
        if let proxyImage {
          PlatformImageView(image: proxyImage)
            .aspectRatio(contentMode: .fit)
        } else {
          Rectangle().fill(.quaternary)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(swipeGesture)
      .accessibilityIdentifier("loupeImage")

      // Chrome prev/next controls ALONGSIDE swipe (spec: "never gesture-only") — overlaid on
      // the image, never the sole way to advance.
      HStack {
        Button {
          store.loupePrevious()
        } label: {
          Image(systemName: "chevron.left")
            .padding()
            .background(.black.opacity(0.35), in: Circle())
            .foregroundStyle(.white)
        }
        .disabled(!store.canLoupeGoPrevious)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityIdentifier("loupePrevious")

        Spacer()

        Button {
          Task { await store.loupeNext() }
        } label: {
          Image(systemName: "chevron.right")
            .padding()
            .background(.black.opacity(0.35), in: Circle())
            .foregroundStyle(.white)
        }
        .disabled(!store.canLoupeGoNext)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityIdentifier("loupeNext")
      }
      .padding(.horizontal, 8)
    }
    .frame(maxHeight: .infinity)
  }

  private var swipeGesture: some Gesture {
    DragGesture(minimumDistance: 30)
      .onEnded { value in
        if value.translation.width < -30 {
          Task { await store.loupeNext() }
        } else if value.translation.width > 30 {
          store.loupePrevious()
        }
      }
  }

  private func loadMainImage() async {
    guard let image = focusedImage else {
      proxyImage = nil
      return
    }
    let token = ProxyIdentity.token(
      from: image.proxies.additionalProperties[ProxyTier.preview.rawValue]?.url)
    if let data = await store.proxyData(imageID: image.id, tier: .preview, identityToken: token),
      let decoded = PlatformImage(data: data)
    {
      proxyImage = decoded
    } else {
      proxyImage = nil
    }
  }
}

/// The loupe's own persistent bottom mark bar (spec: "Pick · Dislike · Clear · Undo", placed
/// low — HIG reach favours the bottom). Every control here calls the SAME `GridStore` mutation
/// path the grid's own `ActionBarView` uses (`applyMark`/`undoLastMark`) — `isMutatingMark`
/// (BINDING fold addendum) is the store-level guard against a rapid double-tap; disabling every
/// button here while a mutation is in flight is the view-layer half of that same guard, same
/// "disabled visually, guarded at the store independent of that" posture `ActionBarView`'s Pick
/// button already uses for Select-mode exclusion.
struct LoupeMarkBar: View {
  @Bindable var store: GridStore

  var body: some View {
    HStack(spacing: 24) {
      Button {
        guard let id = store.focusedImageID else { return }
        Task { await store.applyMark(.pick, to: [id]) }
      } label: {
        Label("Pick", systemImage: "hand.thumbsup")
      }
      .buttonStyle(.bordered)
      .disabled(store.focusedImageID == nil || store.isMutatingMark)
      .frame(minWidth: 44, minHeight: 44)

      Button {
        guard let id = store.focusedImageID else { return }
        Task { await store.applyMark(.dislike, to: [id]) }
      } label: {
        Label("Dislike", systemImage: "hand.thumbsdown")
      }
      .buttonStyle(.bordered)
      .disabled(store.focusedImageID == nil || store.isMutatingMark)
      .frame(minWidth: 44, minHeight: 44)

      Button {
        guard let id = store.focusedImageID else { return }
        Task { await store.applyMark(.none, to: [id]) }
      } label: {
        Label("Clear", systemImage: "xmark.circle")
      }
      .buttonStyle(.bordered)
      .disabled(store.focusedImageID == nil || store.isMutatingMark)
      .frame(minWidth: 44, minHeight: 44)
      .accessibilityIdentifier("loupeClearButton")

      Button {
        Task { await store.undoLastMark() }
      } label: {
        Label("Undo", systemImage: "arrow.uturn.backward")
      }
      .buttonStyle(.bordered)
      .disabled(!store.undo.canUndo || store.isMutatingMark)
      .frame(minWidth: 44, minHeight: 44)
    }
    .labelStyle(.iconOnly)
    .font(.title3)
    .padding()
    .background(.bar)
    .accessibilityIdentifier("loupeMarkBar")
  }
}

/// Regular-2/3 only: the grid retained as a filmstrip "so context is never lost" (spec) — the
/// SAME `GridStore.images`/`focusedImageID`, and the SAME serialized `loadMoreIfNeeded` the
/// grid's own `GridView` uses (fold's "one paging path" pivot), never a filmstrip-local
/// cursor.
struct FilmstripView: View {
  @Bindable var store: GridStore

  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(spacing: 4) {
        ForEach(store.images, id: \.id) { image in
          FilmstripThumbnail(
            image: image, isFocused: store.focusedImageID == image.id, store: store
          )
          .onTapGesture { store.loupeFocus(on: image.id) }
          .task(id: image.id) { await store.loadMoreIfNeeded(currentItemID: image.id) }
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
    }
    .frame(height: 72)
    .background(.bar)
    .accessibilityIdentifier("loupeFilmstrip")
  }
}

struct FilmstripThumbnail: View {
  let image: Components.Schemas.ImageSummary
  let isFocused: Bool
  @State private var proxyImage: PlatformImage?
  let store: GridStore

  var body: some View {
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
