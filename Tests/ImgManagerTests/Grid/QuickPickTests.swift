import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-475 (owner, 2026-09-29: options 1 + 2): "a quick option to pick a photo would be nice,
/// e.g. tap on a photo — unfortunately that is reserved for opening the picture in detail mode."
/// Pure half first: where a tap on a tile's mark corner goes, what it writes, when the corner is
/// there at all, and what the bar's "Tap to Pick" toggle does in each lock state.
@Suite("Quick pick — corner routing and the Tap to Pick toggle (IMGMGR-475)")
struct QuickPickTests {

  @Test("The corner quick-picks only in browse with no lock on; every other state is the tile's")
  func cornerRoutingMatrix() {
    #expect(QuickPickCorner.route(mode: .browse, latchedVerb: nil) == .quickPick)
    // Select keeps selecting: the corner is part of the tile there.
    #expect(QuickPickCorner.route(mode: .select, latchedVerb: nil) == .tile)
    // A latched lock already applies on tap — the corner never adds a second, different write.
    for verb in LatchVerb.allCases {
      #expect(QuickPickCorner.route(mode: .browse, latchedVerb: verb) == .tile)
      #expect(QuickPickCorner.route(mode: .select, latchedVerb: verb) == .tile)
    }
  }

  @Test("The corner toggles Pick: picked -> unmarked, anything else -> picked")
  func cornerTogglesPick() {
    #expect(QuickPickCorner.toggledMark(from: .pick) == MarkStateValue.none)
    #expect(QuickPickCorner.toggledMark(from: MarkStateValue.none) == .pick)
    #expect(QuickPickCorner.toggledMark(from: .dislike) == .pick)
  }

  @Test("The corner is installed only on a displayed tile longer than two targets on each side")
  func cornerInstallBoundary() {
    let side = QuickPickCorner.side
    #expect(side == 44)
    func plan(_ width: CGFloat, _ height: CGFloat) -> TileRenderPlan {
      .display(tier: .grid, size: CGSize(width: width, height: height))
    }
    // Strictly more than two targets: at exactly 88 pt the tile's centre sits on the corner's
    // own edge, and the centre is where a tap focuses/opens.
    #expect(QuickPickCorner.isInstalled(plan: plan(2 * side + 0.5, 2 * side + 0.5), missing: false))
    #expect(!QuickPickCorner.isInstalled(plan: plan(2 * side, 2 * side), missing: false))
    #expect(!QuickPickCorner.isInstalled(plan: plan(2 * side, 400), missing: false))
    #expect(!QuickPickCorner.isInstalled(plan: plan(400, 2 * side), missing: false))
    #expect(!QuickPickCorner.isInstalled(plan: plan(side, side), missing: false))
    #expect(!QuickPickCorner.isInstalled(plan: plan(0, 0), missing: false))
    // No known size, or a photograph that is gone: no corner, the whole cell stays the tile's.
    let roomy = plan(300, 200)
    #expect(QuickPickCorner.isInstalled(plan: roomy, missing: false))
    #expect(QuickPickCorner.isInstalled(plan: roomy, missing: nil))
    #expect(!QuickPickCorner.isInstalled(plan: roomy, missing: true))
    #expect(!QuickPickCorner.isInstalled(plan: .placeholder(reason: .pending), missing: false))
  }

  @Test("The corner speaks the photograph's mark, as the badge it covers would")
  func cornerSpeaksTheMark() {
    #expect(QuickPickCorner.accessibilityValue(for: .pick) == "Picked")
    #expect(QuickPickCorner.accessibilityValue(for: .dislike) == "Disliked")
    #expect(QuickPickCorner.accessibilityValue(for: MarkStateValue.none) == "Not picked")
    #expect(QuickPickCorner.accessibilityIdentifier(imageID: 7) == "tileMarkCorner-7")
  }

  @Test("Tap to Pick latches Pick from idle, exits a Pick lock, and is inert otherwise")
  func toggleActionMatrix() {
    #expect(TapToPickToggle.action(lockState: .idle, mode: .browse) == .latchPick)
    #expect(TapToPickToggle.action(lockState: .latched(.pick), mode: .browse) == .exitLock)
    // A Dislike lock is exited by its own Done; the toggle never silently swaps the verb.
    #expect(TapToPickToggle.action(lockState: .latched(.dislike), mode: .browse) == .inert)
    // Lock entry is disabled in Select (pin e) — the toggle is not even on the Select bar.
    #expect(TapToPickToggle.action(lockState: .idle, mode: .select) == .inert)

    #expect(TapToPickToggle.isOn(.latched(.pick)))
    #expect(!TapToPickToggle.isOn(.idle))
    #expect(!TapToPickToggle.isOn(.latched(.dislike)))
    #expect(TapToPickToggle.title == "Tap to Pick")
    #expect(TapToPickToggle.accessibilityIdentifier == "gridTapToPickToggle")
  }
}

/// The store half: the corner writes through the SAME mark path as the bar (optimistic, undoable),
/// and never touches focus or the loupe.
@MainActor
@Suite("GridStore quick pick (IMGMGR-475)")
struct GridStoreQuickPickTests {

  private func makeImage(
    id: Int, mark: Components.Schemas.MarkView.StatePayload = .none, revision: String = "r0"
  ) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: revision, state: mark, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  /// Photograph 1 picked, 2 unmarked, 3 disliked.
  private func loadedStore() async -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let store = GridStore(service: GridService(client: client))
    await transport.setListImagesPage(
      .init(
        items: [
          makeImage(id: 1, mark: .pick), makeImage(id: 2), makeImage(id: 3, mark: .dislike),
        ], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    return (store, transport)
  }

  private func commits(_ transport: GridStubTransport, imageID: Int) async {
    await transport.setMarkStateOutcome(
      .success(
        .init(applied: 1, requested: 1, revisions: [.init(imageId: imageID, revision: "r1")])))
  }

  private func mark(_ store: GridStore, _ id: Int) -> MarkStateValue? {
    store.images.first(where: { $0.id == id }).map { MarkStateValue($0.mark.state) }
  }

  @Test("Browse: the corner picks an unmarked photograph, undoably, without focusing or opening")
  func cornerPicksWithoutFocusOrLoupe() async {
    let (store, transport) = await loadedStore()
    store.focusedImageID = 1
    await commits(transport, imageID: 2)

    await store.tapMarkCorner(2)

    #expect(mark(store, 2) == .pick)
    #expect(store.focusedImageID == 1)
    #expect(!store.isLoupeOpen)
    #expect(store.pickLock.latchedVerb == nil)
    #expect(store.undo.canUndo)
    #expect(store.undo.entry?.priorStates.map(\.imageID) == [2])
    #expect(store.undo.entry?.appliedState == .pick)
  }

  @Test("Browse: the corner on a picked photograph clears it — pick <-> none")
  func cornerUnpicksAPickedPhotograph() async {
    let (store, transport) = await loadedStore()
    await commits(transport, imageID: 1)
    await store.tapMarkCorner(1)
    #expect(mark(store, 1) == MarkStateValue.none)
  }

  @Test("The FOCUSED tile's corner still picks, and leaves the second tap to the loupe")
  func focusedCornerLeavesTheLoupeToTheTile() async {
    let (store, transport) = await loadedStore()
    store.focusedImageID = 2
    await commits(transport, imageID: 2)

    await store.tapMarkCorner(2)
    #expect(mark(store, 2) == .pick)
    #expect(!store.isLoupeOpen)
    // The bar reads the same projection, so its Pick says so in the same pass (IMGMGR-474).
    #expect(store.markTargetReadout == .uniform(.pick))

    await store.tapTile(2)
    #expect(store.isLoupeOpen)
  }

  @Test("Select: the corner keeps selecting and writes no mark")
  func cornerInSelectSelects() async {
    let (store, _) = await loadedStore()
    store.enterSelectExplicitly()
    await store.tapMarkCorner(2)
    #expect(store.selection.members.contains(2))
    #expect(mark(store, 2) == MarkStateValue.none)
    await store.tapMarkCorner(2)
    #expect(!store.selection.members.contains(2))
  }

  @Test("Latched: the corner applies the LOCK's verb, never the toggle")
  func cornerWhileLatchedAppliesTheLock() async {
    let (store, transport) = await loadedStore()
    // A Pick lock on an already-picked photograph keeps it picked (a toggle would clear it).
    store.lockFromMenu(.pick)
    await commits(transport, imageID: 1)
    await store.tapMarkCorner(1)
    #expect(mark(store, 1) == .pick)
    store.done()

    store.lockFromMenu(.dislike)
    await commits(transport, imageID: 2)
    await store.tapMarkCorner(2)
    #expect(mark(store, 2) == .dislike)
    #expect(store.pickLock.latchedVerb == .dislike)
  }

  @Test("A second corner tap while the first write is in flight is refused, not a flip back")
  func racingCornerTapsWriteOnce() async {
    let (store, transport) = await loadedStore()
    await commits(transport, imageID: 2)
    await transport.holdMarkStateRequests(true)
    let first = Task { await store.tapMarkCorner(2) }
    await transport.waitUntilMarkStateStarted()
    // Optimistic: the tile already reads picked while the request is out.
    #expect(mark(store, 2) == .pick)
    await store.tapMarkCorner(2)
    await transport.releaseMarkState()
    await first.value
    #expect(mark(store, 2) == .pick)
    #expect(store.undo.entry?.appliedState == .pick)
  }

  @Test("Tap to Pick latches the Pick lock (mode-row caption) and a second press exits it")
  func toggleLatchesAndExits() async {
    let (store, transport) = await loadedStore()
    store.toggleTapToPick()
    #expect(store.pickLock.latchedVerb == .pick)
    #expect(
      PickButtonPresentation.for(store.pickLock.state, control: .pick).modeRowCaption
        == PickLockCopy.caption(for: .pick))

    // With the lock on, an ordinary tile tap picks — the mechanics are Pick Lock's, unchanged.
    await commits(transport, imageID: 2)
    await store.tapTile(2)
    #expect(mark(store, 2) == .pick)
    #expect(!store.isLoupeOpen)

    store.toggleTapToPick()
    #expect(store.pickLock.latchedVerb == nil)
  }

  @Test("Tap to Pick does nothing in Select or under a Dislike lock")
  func toggleIsInertOutsideItsStates() async {
    let (store, _) = await loadedStore()
    store.enterSelectExplicitly()
    store.toggleTapToPick()
    #expect(store.pickLock.latchedVerb == nil)
    store.done()

    store.lockFromMenu(.dislike)
    store.toggleTapToPick()
    #expect(store.pickLock.latchedVerb == .dislike)
  }
}
