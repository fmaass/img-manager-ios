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

  @Test("The corner focuses and quick-picks only in browse with no lock on; else it is the tile's")
  func cornerRoutingMatrix() {
    #expect(QuickPickCorner.route(mode: .browse, latchedVerb: nil) == .focusAndQuickPick)
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

  @Test("The corner claims only a tap on its own square, never one the touch radius carried in")
  func cornerClaimsOnlyItsSquare() {
    let side = QuickPickCorner.side
    #expect(QuickPickCorner.claimsTap(at: CGPoint(x: side / 2, y: side / 2)))
    #expect(QuickPickCorner.claimsTap(at: .zero))
    #expect(QuickPickCorner.claimsTap(at: CGPoint(x: side - 0.5, y: side - 0.5)))
    // The iPad gate's tile-centre tap on a 103 pt tile, in the corner's coordinates: 8 pt to its
    // leading side and 7.5 pt below it.
    #expect(!QuickPickCorner.claimsTap(at: CGPoint(x: -8, y: side + 7.5)))
    #expect(!QuickPickCorner.claimsTap(at: CGPoint(x: side / 2, y: side)))
    #expect(!QuickPickCorner.claimsTap(at: CGPoint(x: -0.5, y: side / 2)))
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

  @Test("The corner speaks every status the badges it covers would draw")
  func cornerSpeaksTheBadges() {
    #expect(QuickPickCorner.accessibilityValue(mark: .pick) == "Picked")
    #expect(QuickPickCorner.accessibilityValue(mark: .dislike) == "Disliked")
    #expect(QuickPickCorner.accessibilityValue(mark: MarkStateValue.none) == "Not picked")
    #expect(
      QuickPickCorner.accessibilityValue(
        mark: .pick, isEdited: true, isGood: true, isChangedElsewhere: true)
        == "Picked, Edited, Good, Changed elsewhere")
    #expect(
      QuickPickCorner.accessibilityValue(mark: MarkStateValue.none, isGood: true)
        == "Not picked, Good")
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

  @Test("Browse: the corner focuses and picks in one pass, undoably, never opening the loupe")
  func cornerFocusesAndPicksWithoutTheLoupe() async {
    let (store, transport) = await loadedStore()
    store.focusedImageID = 1
    await commits(transport, imageID: 2)
    await transport.holdMarkStateRequests(true)

    let tap = Task { await store.tapMarkCorner(2) }
    await transport.waitUntilMarkStateStarted()
    // While the write is still out: the badge's source and the bar's readout already agree on
    // photograph 2 (AC 3 — the same frame, not after the round trip).
    #expect(store.focusedImageID == 2)
    #expect(mark(store, 2) == .pick)
    #expect(store.markTargetReadout == .uniform(.pick))
    #expect(!store.isLoupeOpen)
    await transport.releaseMarkState()
    await tap.value

    #expect(mark(store, 2) == .pick)
    #expect(store.focusedImageID == 2)
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

  @Test("A tap the corner receives outside its square is the tile's: focus, then the loupe")
  func cornerHandsATapOutsideItsSquareToTheTile() async {
    let (store, transport) = await loadedStore()
    store.focusedImageID = 1
    await commits(transport, imageID: 2)
    // Where the iPad gate's tap on a 103 pt tile's centre landed, in the corner's coordinates.
    let tileBody = CGPoint(x: -8, y: QuickPickCorner.side + 7.5)

    await store.tapReceivedByMarkCorner(2, at: tileBody, tileSize: Self.gateTile)
    #expect(store.focusedImageID == 2)
    #expect(mark(store, 2) == MarkStateValue.none)
    #expect(!store.isLoupeOpen)

    await store.tapReceivedByMarkCorner(2, at: tileBody, tileSize: Self.gateTile)
    #expect(store.isLoupeOpen)
    #expect(mark(store, 2) == MarkStateValue.none)
  }

  /// The iPad gate's 103 pt tile (lane-m, fce41c8), the size the corner-tap cases lay it on.
  private static let gateTile = CGSize(width: 103.5, height: 103)

  /// Who owns a tap at (`x`, `y`) in the corner's coordinates on the gate's 103 pt tile.
  private static func owner(_ x: CGFloat, _ y: CGFloat) -> QuickPickCorner.TapOwner {
    QuickPickCorner.tapOwner(at: CGPoint(x: x, y: y), tileSize: gateTile)
  }

  @Test("Only a tap inside the corner's own tile is that tile's; one from a neighbour is dropped")
  func cornerDropsATapOutsideItsTile() {
    let side = QuickPickCorner.side
    let leadingEdge = side - Self.gateTile.width
    let bottomEdge = Self.gateTile.height
    #expect(Self.owner(side / 2, side / 2) == .corner)
    #expect(Self.owner(-8, side + 7.5) == .tile)
    #expect(Self.owner(leadingEdge, 0) == .tile)
    #expect(Self.owner(side - 0.5, bottomEdge - 0.5) == .tile)
    // Just past each edge of the owning tile: a neighbour's or the gap, never this tile's.
    #expect(Self.owner(leadingEdge - 0.5, side + 7.5) == .dropped)
    #expect(Self.owner(side, side / 2) == .dropped)
    #expect(Self.owner(side / 2, -0.5) == .dropped)
    #expect(Self.owner(-8, bottomEdge) == .dropped)
  }

  @Test("A neighbour's tap the corner received never marks or focuses the corner's photograph")
  func cornerNeverAppliesANeighboursTapToItsTile() async {
    let (store, transport) = await loadedStore()
    store.focusedImageID = 1
    await commits(transport, imageID: 2)
    // A touch on the next tile's edge, 4 pt past this tile's trailing edge, that the touch
    // radius handed to this tile's corner.
    let neighbour = CGPoint(x: QuickPickCorner.side + 4, y: QuickPickCorner.side / 2)

    await store.tapReceivedByMarkCorner(2, at: neighbour, tileSize: Self.gateTile)
    #expect(store.focusedImageID == 1)
    #expect(mark(store, 2) == MarkStateValue.none)
    #expect(!store.isLoupeOpen)

    // Under a latched Tap to Pick the same tap would be a wrong-photograph write.
    store.toggleTapToPick()
    #expect(store.pickLock.latchedVerb == .pick)
    await store.tapReceivedByMarkCorner(2, at: neighbour, tileSize: Self.gateTile)
    #expect(mark(store, 2) == MarkStateValue.none)
    #expect(store.focusedImageID == 1)
  }

  @Test("A tap on the corner's own square is the corner's quick pick")
  func cornerKeepsATapOnItsSquare() async {
    let (store, transport) = await loadedStore()
    store.focusedImageID = 1
    await commits(transport, imageID: 2)

    let centre = CGPoint(x: QuickPickCorner.side / 2, y: QuickPickCorner.side / 2)
    await store.tapReceivedByMarkCorner(2, at: centre, tileSize: Self.gateTile)
    #expect(mark(store, 2) == .pick)
    #expect(store.focusedImageID == 2)
    #expect(!store.isLoupeOpen)
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
    // IMGMGR-586 keeps this refusal: the same photograph's own write is still out. Returning
    // here at all proves it was not queued (a queued tap would wait for the held request).
    await store.tapMarkCorner(2)
    #expect(store.laneWaiterCount == 0, "the repeat tap on the same photograph was queued")
    await transport.releaseMarkState()
    await first.value
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == 1)
    #expect(mark(store, 2) == .pick)
    #expect(store.undo.entry?.appliedState == .pick)
  }

  @Test("IMGMGR-586: a corner tap on another photograph while a write is in flight lands after it")
  func cornerTapOnAnotherPhotoIsQueued() async {
    let (store, transport) = await loadedStore()
    await commits(transport, imageID: 2)
    await transport.holdMarkStateRequests(true)
    let first = Task { await store.tapMarkCorner(2) }
    await transport.waitUntilMarkStateStarted()
    // Photograph 3 reads Dislike, so its corner tap asks for Pick.
    let second = Task { await store.tapMarkCorner(3) }
    for _ in 0..<10_000 where store.laneWaiterCount < 1 { await Task.yield() }
    #expect(store.laneWaiterCount == 1, "the tap on another photograph was dropped, not queued")
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == 1)
    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    await first.value
    await second.value
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == 2)
    #expect(await transport.lastMarkStateRequest?.imageIds == [3])
    #expect(await transport.lastMarkStateRequest?.state == .pick)
    #expect(mark(store, 2) == .pick)
    #expect(mark(store, 3) == .pick)
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
