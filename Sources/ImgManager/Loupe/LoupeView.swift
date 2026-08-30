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
struct LoupeView: View {
  @Bindable var store: GridStore
  let layoutMode: LayoutMode
  /// The share lane's pre-flight, owned by `RootView` so ONE instance spans the docked and the
  /// full-screen presentations of this same loupe (they are mutually exclusive but swap freely,
  /// and a prepared export must not be lost — or leaked — across that swap).
  let share: ShareExportStore

  /// The production reset adapter; a test substitutes a spy (see the type's own doc comment for
  /// why it is a value and not a view-wrapping closure).
  var zoomInstaller: LoupeZoomInstaller = .live
  /// The production zoom surfaces (chrome twin + gestures); a test substitutes a spy.
  var zoomControls: LoupeZoomControls = .live

  @State private var proxyImage: PlatformImage?
  @State private var zoomModel: LoupeZoomModel
  @State private var imageViewport: CGSize = .zero
  @Environment(\.displayScale) private var displayScale

  init(
    store: GridStore, layoutMode: LayoutMode, share: ShareExportStore,
    zoomModel: LoupeZoomModel = LoupeZoomModel()
  ) {
    self.store = store
    self.layoutMode = layoutMode
    self.share = share
    _zoomModel = State(initialValue: zoomModel)
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
      header(zoomToggle: zoomToggle)
      ShareStatusBar(share: share)
      mainImageArea(zoomToggle: zoomToggle)
      if layoutMode != .compact {
        FilmstripView(store: store)
      }
      ConflictRecoveryBanner(store: store)
      LoupeMarkBar(store: store)
    }
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
      await loadMainImage()
      syncZoomGeometry()
    }
  }

  private func header(zoomToggle: @escaping () -> Void) -> some View {
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

      // The chrome twin for zoom (persistent-chrome rule: zero gesture-only actions). Present in
      // EVERY layout mode, including Compact where the header is at its tightest — the rule is
      // not conditional on there being room.
      zoomControls.makeToggleControl(LoupeZoomControlModel(resolvedZoom), zoomToggle)

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

  func loadMainImage() async {
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
/// SAME `GridStore.actionableImages`/`focusedImageID`, and the SAME serialized `loadMoreIfNeeded`
/// the grid's own `GridView` uses (fold's "one paging path" pivot), never a filmstrip-local
/// cursor.
///
/// WP12: walking the shared actionable projection is what makes the filmstrip agree with the grid
/// in BOTH modes rather than only in flat browse — in Scene mode it shows the loose photographs
/// and the members of opened scenes, in display order, and no collapsed card's cover.
struct FilmstripView: View {
  @Bindable var store: GridStore

  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(spacing: 4) {
        ForEach(store.actionableImages, id: \.id) { image in
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
