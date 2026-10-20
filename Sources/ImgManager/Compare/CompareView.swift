import ImgManagerAPI
import SwiftUI

/// WP30 P3 (IMGMGR-458): Compare 2-up, iPad only. The docked loupe's detail container swaps to
/// this view while `GridStore.isCompareOpen` (plan decision 5) — no navigation push — and Back
/// swaps it back, focused on the current left image.
///
/// Chrome: a system toolbar of three groups (Back · title · Pin, Info, More) and the decision
/// cluster on the system bottom bar (Keep left · Both · Keep right, a fixed gap, Undo). The scene
/// strip below the panes is CONTENT (`MaterialPolicy` `.content`), never glass (ADR-N1).
struct CompareView: View {
  @Bindable var store: GridStore
  /// The loupe's own chrome inputs: the Info toggle drives the one inspector, which shows the
  /// focused photograph — the left image, which Compare keeps focused.
  let chrome: LoupeChrome

  @State private var zoom = CompareZoomSync()

  var body: some View {
    let session = store.compareSession
    let zoomKey = CompareZoomKey(left: session?.left, right: session?.right)
    return VStack(spacing: 0) {
      if let session {
        HStack(spacing: 2) {
          ComparePane(store: store, pane: .left, imageID: session.left, zoom: $zoom)
          ComparePane(store: store, pane: .right, imageID: session.right, zoom: $zoom)
        }
        CompareStrip(store: store, session: session)
      }
      ConflictRecoveryBanner(store: store)
      UnsavedMarksBanner(store: store)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("compareContent")
    .toolbar {
      ToolbarItemGroup(placement: .topBarLeading) {
        Button {
          store.closeCompare()
        } label: {
          Label("Back", systemImage: "chevron.backward")
        }
        .accessibilityIdentifier("compareBack")
      }
      ToolbarItemGroup(placement: .principal) {
        Text(session?.title ?? "Compare")
          .font(.headline)
          .lineLimit(1)
          .accessibilityIdentifier("compareTitle")
      }
      ToolbarItemGroup(placement: .primaryAction) {
        pinButton(isPinned: session?.isPinned ?? false)
        if let info = chrome.info {
          Button {
            info.toggle()
          } label: {
            Label("Info", systemImage: "info.circle")
          }
          .accessibilityAddTraits(info.isPresented ? [.isSelected] : [])
          .accessibilityIdentifier("compareInfoButton")
        }
        moreMenu
      }
      CompareDecisionGroup(store: store)
    }
    .navigationBarTitleDisplayMode(.inline)
    // IMGMGR-495: ⌘0's target while Compare is mounted — both panes, through the pair's own toggle
    // (`CompareZoomSync.toggleAll`). The grid's keys stay nil here (decision 7); this one does not.
    .focusedSceneValue(\.viewerZoomCommand, ViewerZoomCommand(toggle: { zoom.toggleAll() }))
    .onChange(of: zoomKey, initial: true) { _, key in
      zoom.show(left: key.left, right: key.right)
    }
  }

  /// Pin: a toggle; its state is the accessibility value and the selected trait.
  private func pinButton(isPinned: Bool) -> some View {
    Button {
      store.compareSetPinned(!isPinned)
    } label: {
      Label("Pin", systemImage: isPinned ? "pin.fill" : "pin")
    }
    .disabled(store.isMutatingMark)
    .accessibilityValue(isPinned ? "On" : "Off")
    .accessibilityAddTraits(isPinned ? [.isSelected] : [])
    .accessibilityIdentifier("comparePinButton")
  }

  /// More: Zoom Fit · 100% · Sync zoom ✓ — the chrome twins of the panes' pinch and double-tap.
  private var moreMenu: some View {
    Menu {
      Button {
        zoom.resetToFit()
      } label: {
        Label("Zoom to Fit", systemImage: "arrow.down.right.and.arrow.up.left")
      }
      .accessibilityIdentifier("compareZoomFit")
      Button {
        zoom.zoomToOneToOne()
      } label: {
        Label("Zoom to 100%", systemImage: "1.magnifyingglass")
      }
      .accessibilityIdentifier("compareZoomOneToOne")
      Toggle(isOn: $zoom.isSynced) {
        Label("Sync zoom", systemImage: "link")
      }
      .accessibilityValue(zoom.isSynced ? "On" : "Off")
      .accessibilityIdentifier("compareSyncZoom")
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .accessibilityIdentifier("compareMoreMenu")
  }
}

/// The pair the zoom follows: a change on either side resets both panes to fit.
private struct CompareZoomKey: Equatable {
  let left: Int?
  let right: Int?
}

/// The decision cluster on the system bottom bar: the three verbs, a fixed gap, then Undo.
struct CompareDecisionGroup: ToolbarContent {
  let store: GridStore

  var body: some ToolbarContent {
    ToolbarSpacer(.flexible, placement: .bottomBar)
    ToolbarItem(placement: .bottomBar) {
      CompareDecisionBar(store: store)
    }
    ToolbarSpacer(.fixed, placement: .bottomBar)
    ToolbarItem(placement: .bottomBar) {
      CompareUndoButton(store: store)
    }
    ToolbarSpacer(.flexible, placement: .bottomBar)
  }
}

/// Keep left · Both · Keep right. Disabled in the end state and while any mark write is in
/// flight; each verb is ONE compound mark (`GridStore.compareDecide`).
struct CompareDecisionBar: View {
  @Bindable var store: GridStore

  var body: some View {
    let canDecide = store.compareSession.map { !$0.isExhausted } ?? false
    return HStack(spacing: 16) {
      ForEach(CompareVerb.allCases, id: \.self) { verb in
        Button {
          Task { await store.compareDecide(verb) }
        } label: {
          Label(verb.title, systemImage: verb.systemImage)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .disabled(!canDecide || store.isMutatingMark)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityIdentifier(verb.accessibilityIdentifier)
      }
    }
    .labelStyle(.titleAndIcon)
    .padding(.horizontal, 8)
    // IMGMGR-280: `.contain` FIRST, then the container's identifier, so the verbs keep theirs.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("compareDecisionBar")
  }
}

/// Compare's Undo: the store's one slot; the panes come back only on a full restore.
struct CompareUndoButton: View {
  @Bindable var store: GridStore

  var body: some View {
    Button {
      Task { await store.compareUndo() }
    } label: {
      Label("Undo", systemImage: "arrow.uturn.backward")
    }
    .labelStyle(.iconOnly)
    .font(.title3)
    .disabled(!store.undo.canUndo || store.isMutatingMark)
    .frame(minWidth: 44, minHeight: 44)
    .accessibilityIdentifier("compareUndo")
  }
}

/// One pane: the preview proxy of an explicit image id, loaded through the loupe's own
/// primitive (`GridStore.proxyData`) — never bound to `focusedImageID`. Pinch, double-tap and
/// drag drive `CompareZoomSync`; at fit a horizontal drag on the right pane steps its candidate
/// (the swipe whose chrome twin is the strip).
/// Which load owns a pane (fold round 1, B3). `.task(id:)` cancels a superseded load, but
/// cancellation does not stop an in-flight `proxyData` from answering — a slow answer for the
/// previous image can arrive AFTER the current one and would paint the wrong photograph. Every
/// load takes a ticket; a completion publishes only when it is still the latest ticket, was not
/// cancelled, and its image still owns the pane.
struct ComparePaneLoadGate: Equatable, Sendable {
  struct Ticket: Equatable, Sendable {
    let serial: Int
    let imageID: Int?
  }

  private(set) var serial = 0

  mutating func begin(_ imageID: Int?) -> Ticket {
    serial += 1
    return Ticket(serial: serial, imageID: imageID)
  }

  func accepts(_ ticket: Ticket, currentImageID: Int?, isCancelled: Bool) -> Bool {
    !isCancelled && ticket.serial == serial && ticket.imageID == currentImageID
  }
}

struct ComparePane: View {
  let store: GridStore
  let pane: CompareZoomSync.Pane
  let imageID: Int?
  @Binding var zoom: CompareZoomSync

  @State private var proxyImage: PlatformImage?
  @State private var loadGate = ComparePaneLoadGate()
  @State private var viewport: CGSize = .zero
  @Environment(\.displayScale) private var displayScale

  private var paneName: String { pane == .left ? "Left" : "Right" }

  private var image: Components.Schemas.ImageSummary? {
    guard let imageID else { return nil }
    return store.actionableImages.first { $0.id == imageID }
  }

  var body: some View {
    let drawn = zoom.rendered(pane)
    return LoupeZoomControls.live.attachGestures(AnyView(content(drawn)), handlers)
      .task(id: imageID) { await load() }
  }

  private func content(_ drawn: CompareZoomSync.Rendered) -> some View {
    Group {
      if let proxyImage {
        PlatformImageView(image: proxyImage)
          .aspectRatio(contentMode: .fit)
      } else if imageID == nil {
        ContentUnavailableView("No more candidates", systemImage: "checkmark.circle")
      } else {
        Rectangle().fill(.quaternary)
      }
    }
    .scaleEffect(drawn.scale)
    .offset(drawn.offset)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(imageID.map { String($0) } ?? "none")
    .accessibilityIdentifier(pane == .left ? "compareLeftPane" : "compareRightPane")
    .onGeometryChange(for: CGSize.self) {
      $0.size
    } action: { size in
      viewport = size
      syncGeometry()
    }
  }

  private var accessibilityLabel: String {
    guard let image else { return "\(paneName): no more candidates" }
    let magnification = zoom.magnificationDescription(pane)
    return "\(paneName) photograph, \(image.filename), zoom \(magnification)"
  }

  private var handlers: LoupeZoomGestureHandlers {
    LoupeZoomGestureHandlers(
      onToggle: { zoom.toggle(pane) },
      onMagnify: { zoom.magnify(pane, to: $0) },
      onMagnifyEnded: { zoom.endMagnify() },
      onDrag: { translation in dragChanged(translation) },
      onDragEnded: { translation in dragEnded(translation) }
    )
  }

  private func dragChanged(_ translation: CGSize) {
    guard zoom.isZoomed(pane) else { return }
    zoom.pan(pane, by: translation)
  }

  /// The loupe's own arbitration (`LoupeZoomState.dragOutcome`): zoomed pans, at fit a drag
  /// past the threshold steps the RIGHT pane's candidate (the left pane does not step).
  private func dragEnded(_ translation: CGSize) {
    switch LoupeZoomState.dragOutcome(translation: translation, isZoomed: zoom.isZoomed(pane)) {
    case .pan(let committed):
      zoom.pan(pane, by: committed)
      zoom.endPan()
    case .advanceNext:
      if pane == .right { store.compareStepRight(forward: true) }
    case .advancePrevious:
      if pane == .right { store.compareStepRight(forward: false) }
    case .ignored:
      break
    }
  }

  /// The image this pane shows NOW, read live from the store — `imageID` on a view value that a
  /// task captured is the value it started with, which is exactly what B3 must not trust.
  private var liveImageID: Int? {
    let session = store.compareSession
    return pane == .left ? session?.left : session?.right
  }

  private func load() async {
    let ticket = loadGate.begin(imageID)
    proxyImage = nil
    guard let image else {
      syncGeometry()
      return
    }
    let token = ProxyIdentity.token(
      from: image.proxies.additionalProperties[ProxyTier.preview.rawValue]?.url)
    let data = await store.proxyData(imageID: image.id, tier: .preview, identityToken: token)
    let owns = loadGate.accepts(ticket, currentImageID: liveImageID, isCancelled: Task.isCancelled)
    guard owns else { return }
    if let data, let decoded = PlatformImage(data: data) { proxyImage = decoded }
    syncGeometry()
  }

  private func syncGeometry() {
    var pixels = CGSize.zero
    if let proxyImage {
      #if canImport(UIKit)
        pixels = CGSize(
          width: proxyImage.size.width * proxyImage.scale,
          height: proxyImage.size.height * proxyImage.scale)
      #else
        pixels = proxyImage.size
      #endif
    }
    let geometry = CompareZoomSync.Geometry(
      proxyPixels: pixels, viewport: viewport, displayScale: displayScale)
    zoom.updateGeometry(pane, geometry)
  }
}

/// The scene strip: the candidates as Buttons (IMGMGR-268), the current pair highlighted, the
/// left image's thumbnail disabled so a duplicate pair is unreachable. A tap sets the right pane —
/// the chrome twin of the right pane's swipe. Content, not chrome: no fill in any mode, and the
/// resolved role rides its accessibility value.
struct CompareStrip: View {
  @Bindable var store: GridStore
  let session: CompareSession

  var body: some View {
    let frames = self.frames
    return ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        LazyHStack(spacing: 4) {
          ForEach(frames, id: \.id) { image in
            thumbnail(image)
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
      }
      .frame(height: 72)
      .materialSurface(.content)
      .accessibilityIdentifier("compareStrip")
      .padding(.bottom, 4)
      .onChange(of: session.right, initial: true) { _, right in
        guard let right else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(right, anchor: .center) }
      }
    }
  }

  /// The candidates as the store holds them now (their marks are server state, read live).
  private var frames: [Components.Schemas.ImageSummary] {
    var pool: [Int: Components.Schemas.ImageSummary] = [:]
    for image in store.actionableImages where pool[image.id] == nil {
      pool[image.id] = image
    }
    return session.candidates.compactMap { pool[$0] }
  }

  private func thumbnail(_ image: Components.Schemas.ImageSummary) -> some View {
    let isInPair = image.id == session.left || image.id == session.right
    return Button {
      store.compareShowOnRight(image.id)
    } label: {
      FilmstripThumbnail(image: image, isFocused: isInPair, store: store)
    }
    .buttonStyle(.plain)
    .disabled(image.id == session.left || store.isMutatingMark)
    .accessibilityIdentifier("compareStripThumbnail-\(image.id)")
    .accessibilityLabel(FilmstripThumbnailAccessibility.label(for: image))
    .accessibilityAddTraits(isInPair ? [.isSelected] : [])
  }
}

/// Plan decision 7: while Compare is open the scene publishes NO keyboard actions, so every
/// menu-bar, grid and loupe key command is disabled (`AppCommands` disables each entry on nil).
/// The one exception is ⌘0 (IMGMGR-495), which dispatches into `ViewerZoomCommand` — published
/// by `CompareView` itself — rather than into these actions.
enum CompareKeyboardIsolation {
  static func published(_ actions: GridKeyboardActions, isCompareOpen: Bool)
    -> GridKeyboardActions?
  {
    isCompareOpen ? nil : actions
  }
}
