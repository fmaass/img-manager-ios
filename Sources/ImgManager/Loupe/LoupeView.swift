import ImgManagerAPI
import SwiftUI

/// The culling surface itself, presented differently per `LayoutMode` BY DESIGN (spec §"Loupe /
/// cull"). One view, branched only on `layoutMode` — never on the device-idiom API, whose very
/// NAME is banned from this tree by a mac-gate absence grep (plan invariant (i)):
///
/// - `.compact`: the filmstrip below the main image, and no full-screen toggle control (the
///   presenting view — `RootView` — always shows this full-screen here already). WP13 P9
///   (IMGMGR-218) removed the filmstrip exclusion this bullet used to record: the phone gets the
///   spec's thumb bar, and it is the SAME `FilmstripView` over the SAME projection the iPad's
///   is, so Scene-mode frame walking is inherited rather than re-implemented.
/// - `.regular2`/`.regular3`: the same filmstrip (same `GridStore.actionableImages`/
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
  /// The production filmstrip surface; a test substitutes a spy. A value adapter for the reason
  /// `LoupeZoomInstaller`'s own doc comment gives: a call site that exists only inside a `body`
  /// cannot be observed any other way, and WP13 P9's whole claim is about WHICH layout modes
  /// reach this one.
  var filmstrip: LoupeFilmstripSurface = .live

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
      filmstrip.make(store)
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

      // WP13 P8 (IMGMGR-214): the advance-on-mark cadence, on or off, HERE — where the culling
      // happens — and not only in the account sheet. The persistent-chrome rule is that no
      // behaviour is reachable solely as a hidden preference or a bare key equivalent; `A`/⌘⇧A
      // are the accelerator forms of this control, never its only surface. Same accessibility
      // shape as the zoom twin beside it (identifier + label + value), so a UI test can read the
      // state back rather than infer it from a glyph.
      Button {
        store.preferences.autoAdvanceOnMark.toggle()
      } label: {
        Image(
          systemName: store.preferences.autoAdvanceOnMark
            ? "forward.end.circle.fill" : "forward.end.circle")
      }
      .frame(minWidth: 44, minHeight: 44)
      .accessibilityIdentifier("loupeAutoAdvanceToggle")
      .accessibilityLabel("Advance After Marking")
      .accessibilityValue(store.preferences.autoAdvanceOnMark ? "On" : "Off")
      .accessibilityHint("Move to the next photograph after each mark")

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
          .accessibilityLabel("Photograph")
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
/// path the grid's own `ActionBarView` uses — through `applyLoupeMark`, which is `applyMark`
/// plus WP13 P8's advance-on-mark cadence (the advance hangs off the mutation's own COMMITTED
/// answer, never off the button press) — and `undoLastMark`. `isMutatingMark`
/// (BINDING fold addendum) is the store-level guard against a rapid double-tap; disabling every
/// button here while a mutation is in flight is the view-layer half of that same guard, same
/// "disabled visually, guarded at the store independent of that" posture `ActionBarView`'s Pick
/// button already uses for Select-mode exclusion.
struct LoupeMarkBar: View {
  @Bindable var store: GridStore

  var body: some View {
    let markState = store.focusedMarkState
    return HStack(spacing: 24) {
      markButton(.pick, state: markState)
      markButton(.dislike, state: markState)

      Button {
        Task { await store.applyLoupeMark(.none) }
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
    Button {
      Task { await store.applyLoupeMark(control.appliedState) }
    } label: {
      Label(control.title, systemImage: LoupeMarkPresentation.symbol(for: control, state: state))
    }
    .buttonStyle(.bordered)
    .tint(isActive ? Color.accentColor : nil)
    .disabled(store.focusedImageID == nil || store.isMutatingMark)
    .frame(minWidth: 44, minHeight: 44)
    // No per-button `accessibilityIdentifier` here: this bar's own identifier is set on the
    // enclosing HStack and PROPAGATES down over every child's (gate run 23:26 dumped all four
    // controls reporting `identifier: 'loupeMarkBar'`, `loupeClearButton` included). One that
    // never surfaces would be a lie a test could not catch, so the controls are resolved by
    // label within the bar instead.
    .accessibilityValue(LoupeMarkPresentation.accessibilityValue(for: control, state: state))
    .accessibilityAddTraits(isActive ? [.isSelected] : [])
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

/// EVERY layout mode since WP13 P9 (IMGMGR-218), the phone included: the grid retained as a
/// filmstrip "so context is never lost" (spec) — the SAME `GridStore.actionableImages`/
/// `focusedImageID`, and the SAME serialized `loadMoreIfNeeded` the grid's own `GridView` uses
/// (fold's "one paging path" pivot), never a filmstrip-local cursor.
///
/// WP12: walking the shared actionable projection is what makes the filmstrip agree with the grid
/// in BOTH modes rather than only in flat browse — in Scene mode it shows the loose photographs
/// and the members of opened scenes, in display order, and no collapsed card's cover.
///
/// WP13 P9: the strip FOLLOWS the focused frame. P8's advance-on-mark moves `focusedImageID` on
/// every committed loupe mark, so a strip that only moved when the reader dragged it would
/// silently stop tracking after the first advance — which on a phone, where the strip is the
/// only context there is, would be worse than no strip. `revealTarget(in:)` names the frame to
/// bring into view and `reveal(_:through:)` is the one seam that brings it.
struct FilmstripView: View {
  @Bindable var store: GridStore
  /// The scroll seam. Production drives the live `ScrollViewProxy`; a test substitutes a
  /// recorder and passes `nil`, because a `ScrollViewProxy` cannot be constructed outside a
  /// rendered `ScrollViewReader`.
  var scroller: FilmstripFocusScroller = .live

  /// THE projection the strip walks: the shared actionable one, never `store.images` — which is
  /// empty in Scene mode — and so never a collapsed card's cover (ADR-0005 decision 4).
  var frames: [Components.Schemas.ImageSummary] { store.actionableImages }

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

  /// The strip's paging hook: the store's own pagers, and nothing else. Named so the Do-NOT
  /// ("no second paging path, no filmstrip-local cursor" — WP8 P5's pivot) is one function a
  /// diff can read, rather than a closure buried in a row modifier.
  ///
  /// IMGMGR-267: this is EXACTLY `GridView.page(from:)`, asked of a photograph. It used to be the
  /// flat pager alone, which returns early unless `displayMode == .flat` — so in Scene mode the
  /// strip walked the loaded pool and, at the tail, simply stopped, while the grid behind it went
  /// on paging. The three questions ("page the flat grid", "page the scene stream", "page THIS
  /// scene's membership") are each a no-op in the wrong mode by the store's own guards, so asking
  /// all three here adds no second path — it makes the strip ask the same ones the grid does.
  func pageIfNeeded(around image: Components.Schemas.ImageSummary) async {
    await store.loadMoreIfNeeded(currentItemID: image.id)
    await store.loadMoreSceneMembersIfNeeded(afterMemberID: image.id)
    await store.loadMoreScenesIfNeeded(currentRowID: .image(image.id))
  }

  /// The one place a scroll is asked for; `body`'s `onChange` carries no logic of its own.
  func reveal(_ target: Int?, through proxy: ScrollViewProxy?) {
    guard let target else { return }
    scroller.reveal(proxy, target)
  }

  var body: some View {
    let frames = self.frames
    return ScrollViewReader { proxy in
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
            .task(id: image.id) { await pageIfNeeded(around: image) }
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
      }
      .frame(height: 72)
      .background(.bar)
      .accessibilityIdentifier("loupeFilmstrip")
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
