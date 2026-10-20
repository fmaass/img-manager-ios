import ImgManagerAPI
import SwiftUI

/// WP31 P1 (IMGMGR-460): Triage's words and its swipe rule, pure so a test reads them directly.
enum TriageCopy {
  /// Plan decision 2: position, never "reviewed"/"left" — "i of N", with a dash while the
  /// photograph on screen is not in the loaded pool.
  static func position(_ index: Int?, of total: Int) -> String {
    let shown = index.map { String($0) } ?? "–"
    return "\(shown) of \(total)"
  }
}

/// The swipe → verdict rule: left Dislike, right Pick, up Skip, by the dominant axis and past a
/// distance threshold. A downward or short drag decides nothing.
enum TriageSwipe {
  static let threshold: CGFloat = 60

  static func verdict(for translation: CGSize) -> TriageVerdict? {
    if abs(translation.width) >= abs(translation.height) {
      if translation.width <= -threshold { return .dislike }
      if translation.width >= threshold { return .pick }
      return nil
    }
    return translation.height <= -threshold ? .skip : nil
  }
}

/// WP31 P1 (IMGMGR-460): the Triage screen — a full-bleed photograph, a header Back · "<shoot> ·
/// i of N" · a progress bar, and a bottom row Dislike · Skip · Pick with Undo below.
///
/// Every gesture has a visible twin (the chrome-twin rule, p3220 decision 9): a swipe and its
/// button call the same `perform(_:)`, which calls the same `TriageSession.decide(_:)`. Presented
/// as a `fullScreenCover` at Compact by `RootView`, beside the loupe's cover — no back-swipe can
/// swallow a horizontal drag here.
struct TriageView: View {
  let store: GridStore
  let shootTitle: String
  /// The grid breadcrumb's count (plan decision 2); the loaded pool's size when there is none.
  let totalCount: Int?
  /// The pass ended — Back, or the last photograph decided. The host closes the cover and, for a
  /// pass with at least one action, presents the Pass Summary over the grid (WP31 P2).
  let onPassEnded: (TriagePassResult) -> Void

  @State private var session: TriageSession
  /// The preview ON SCREEN, tied to the photograph it was loaded for (review B1): when its id is
  /// not the cursor's the photo area shows a placeholder, never the previous photograph.
  @State private var preview: TriagePreview?
  /// WP31 P2 review round 3: holds the pass's Handoff activity and keeps it current.
  @State private var advertiser = TriageActivityAdvertiser(source: "triage")

  init(
    store: GridStore, shootTitle: String, totalCount: Int?,
    onPassEnded: @escaping (TriagePassResult) -> Void
  ) {
    self.store = store
    self.shootTitle = shootTitle
    self.totalCount = totalCount
    self.onPassEnded = onPassEnded
    _session = State(initialValue: TriageSession(store: store))
  }

  private var total: Int { totalCount ?? store.actionableImages.count }

  private var cursorImage: Components.Schemas.ImageSummary? {
    guard let id = session.cursor else { return nil }
    return store.actionableImages.first { $0.id == id }
  }

  var body: some View {
    VStack(spacing: 0) {
      debugProbeElement
      header
      photo
      // IMGMGR-586: Triage is a full-screen cover, so the grid's own banner is hidden behind it.
      UnsavedMarksBanner(store: store)
      controls
    }
    .sensoryFeedback(.selection, trigger: session.committedMarks)
    .task(id: session.cursor) { await loadImage() }
    .onChange(of: session.result) { _, result in
      if let result { onPassEnded(result) }
    }
    // WP31 P2 (IMGMGR-461), plan decision 5: Triage keeps its Handoff activity current while
    // the pass is open, so the iPad offers the app at the pass's position — made current on
    // appearance and on every position change, resigned when the pass ends or the cover goes
    // (review round 3: owned by `TriageActivityAdvertiser`, not `.userActivity`).
    .onAppear { advertiser.advertise(advertisedHandoff) }
    .onChange(of: advertisedHandoff) { _, payload in advertiser.advertise(payload) }
    .onDisappear {
      advertiser.end()
      session.close()
    }
  }

  /// The payload to keep current: the pass's own, and nothing once the pass has ended.
  private var advertisedHandoff: TriageActivity? {
    session.isClosed ? nil : handoff
  }

  /// WP31 P2 (IMGMGR-461): the pass's Handoff payload — the grid's shoot and the continuation
  /// position (plan decision 4), with its index in the live pool as information only.
  private var handoff: TriageActivity? {
    TriageActivity.advertised(
      folderID: store.query.folderID, tier: store.query.sourceTier,
      imageID: session.continuationImageID, pool: store.actionableImages.map(\.id),
      completed: session.completed)
  }

  private var header: some View {
    VStack(spacing: 6) {
      HStack(spacing: 8) {
        Button {
          session.close()
        } label: {
          Label("Back", systemImage: "chevron.left")
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityIdentifier("triageBack")
        Spacer(minLength: 0)
        Text(shootTitle)
          .font(.headline)
          .lineLimit(1)
        Text("·")
          .accessibilityHidden(true)
        Text(TriageCopy.position(session.position, of: total))
          .font(.headline)
          .monospacedDigit()
          .accessibilityIdentifier("triagePosition")
        Spacer(minLength: 0)
      }
      ProgressView(value: Double(session.position ?? 0), total: Double(max(total, 1)))
        .accessibilityIdentifier("triageProgress")
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
  }

  /// The preview the photo area shows: the cursor's, or none — never the previous photograph's
  /// while the cursor's is still loading (review B1). One value for the view AND its DEBUG probe
  /// (IMGMGR-502), so the probe reports what is rendered rather than a second reading of it.
  private var shownPreview: TriagePreview? {
    guard let preview, preview.imageID == session.cursor else { return nil }
    return preview
  }

  private var photo: some View {
    Group {
      if let shownPreview {
        if let image = shownPreview.image {
          PlatformImageView(image: image)
            .aspectRatio(contentMode: .fit)
        } else {
          Text("No preview")
            .foregroundStyle(.secondary)
        }
      } else {
        ProgressView()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .clipped()
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 24)
        .onEnded { value in
          if let verdict = TriageSwipe.verdict(for: value.translation) { perform(verdict) }
        }
    )
    .accessibilityElement()
    .accessibilityIdentifier("triagePhoto")
    .accessibilityLabel("Photograph")
    .accessibilityValue(shownFilename)
  }

  private var controls: some View {
    VStack(spacing: 8) {
      HStack(spacing: 32) {
        decisionButton(.dislike, title: "Dislike", symbol: "xmark", id: "triageDislike")
        decisionButton(.skip, title: "Skip", symbol: "arrow.up", id: "triageSkip")
        decisionButton(.pick, title: "Pick", symbol: "checkmark", id: "triagePick")
      }
      Button("Undo") {
        Task { await session.undo() }
      }
      .disabled(!session.canUndo)
      .frame(minWidth: 44, minHeight: 44)
      .accessibilityIdentifier("triageUndo")
    }
    .padding(.top, 12)
    .padding(.bottom, 8)
  }

  /// One verdict's twin: the same `perform(_:)` its swipe calls.
  private func decisionButton(
    _ verdict: TriageVerdict, title: String, symbol: String, id: String
  ) -> some View {
    Button {
      perform(verdict)
    } label: {
      Label(title, systemImage: symbol)
        .labelStyle(.iconOnly)
        .font(.title2)
        .frame(width: 48, height: 48)
    }
    // Not `.glass`: the gate's no-custom-glass-grep leg bans that spelling (ADR-N1); the system
    // bordered circle is the loupe's own fallback.
    .buttonStyle(.bordered)
    .buttonBorderShape(.circle)
    .tint(Self.tint(for: verdict))
    .disabled(!session.canDecide)
    .frame(minWidth: 64, minHeight: 64)
    .accessibilityIdentifier(id)
  }

  private static func tint(for verdict: TriageVerdict) -> Color? {
    switch verdict {
    case .pick: return MarkPalette.color(for: .pick)
    case .dislike: return MarkPalette.color(for: .dislike)
    case .skip: return nil
    }
  }

  private func perform(_ verdict: TriageVerdict) {
    Task { await session.decide(verdict) }
  }

  /// The loupe's preview loading (`LoupeView.loadMainImage`): the `.preview` tier through the
  /// store's proxy cache, no zoom.
  ///
  /// The preview is recorded WITH its id and only then reported to the session, so the session's
  /// "displayed" photograph is always the one on screen (review B1). A failed load still shows —
  /// and reports — the "No preview" placeholder for THAT id, so the pass is never stuck.
  private func loadImage() async {
    guard let image = cursorImage else { return }
    let token = ProxyIdentity.token(
      from: image.proxies.additionalProperties[ProxyTier.preview.rawValue]?.url)
    let data = await store.proxyData(imageID: image.id, tier: .preview, identityToken: token)
    guard session.cursor == image.id else { return }
    preview = TriagePreview(imageID: image.id, image: data.flatMap { PlatformImage(data: $0) })
    session.didDisplay(image.id)
  }

  /// The photograph on screen, named — empty while the cursor's preview is still loading.
  private var shownFilename: String {
    guard let image = cursorImage, session.displayedImageID == image.id else { return "" }
    return image.filename
  }

  /// EVIDENCE, fixture-only (`GridView.debugProbeElement`'s pattern): the mark writes the fixture
  /// transport has served, INSIDE the cover — the grid's probes are under it. Plan P1
  /// verification (2): Skip leaves this unchanged.
  #if DEBUG
    @ViewBuilder private var debugProbeElement: some View {
      if DebugStubLaunch.isActive {
        Text("debugProbeMarks")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe.marks")
          .accessibilityValue("markWrites=\(DebugProbe.shared.markWrites)")
        // WP31 P2 (IMGMGR-461): the activity this cover's advertiser made current.
        Text("debugProbeActivity")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe.activity")
          .accessibilityValue(DebugProbe.shared.activity)
        // IMGMGR-502: what the photo area renders — `loading` (the spinner), `<id>:image` or
        // `<id>:none` (the "No preview" placeholder) — read off `shownPreview`, the value the
        // photo itself renders from. The photo's own element collapses its children, so the
        // placeholder text is not separately visible to a UI test.
        Text("debugProbeTriagePreview")
          .font(.system(size: 1))
          .foregroundStyle(.clear)
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
          .accessibilityIdentifier("debugProbe.triagePreview")
          .accessibilityValue(previewProbeValue)
        // IMGMGR-502 review r1: under `-UITestHoldPreviewOf <id>` only, how many preview
        // answers the fixture is parking, and the control a UI test taps to let them through
        // (`DebugPreviewHold`). A real, tappable button, so the release is an explicit signal
        // from the test rather than a timer in the transport.
        if DebugStubLaunch.holdsAPreview {
          Text("debugProbeHeldPreviews")
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityIdentifier("debugProbe.heldPreviews")
            .accessibilityValue("heldPreviews=\(DebugProbe.shared.heldPreviews)")
          Button("Release held preview") {
            Task { await DebugPreviewHold.shared.release() }
          }
          .font(.caption2)
          .frame(minWidth: 44, minHeight: 44)
          .accessibilityIdentifier("debugReleaseHeldPreview")
        }
      }
    }

    private var previewProbeValue: String {
      guard let shownPreview else { return "loading" }
      return "\(shownPreview.imageID):\(shownPreview.image == nil ? "none" : "image")"
    }
  #else
    private var debugProbeElement: some View { EmptyView() }
  #endif
}

/// A loaded preview and the photograph it belongs to (review B1).
struct TriagePreview {
  let imageID: Int
  let image: PlatformImage?
}

/// WP31 P1 (IMGMGR-460): the Compact grid bar's way into Triage, disabled while the scope holds
/// no photograph.
struct GridTriageControl: View {
  let store: GridStore

  static let accessibilityIdentifier = "gridTriageButton"

  var body: some View {
    Button {
      store.openTriage()
    } label: {
      Label("Triage", systemImage: "rectangle.stack")
    }
    .disabled(!store.canOpenTriage)
    .accessibilityIdentifier(Self.accessibilityIdentifier)
  }
}
