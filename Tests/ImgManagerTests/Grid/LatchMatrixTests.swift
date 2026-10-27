import CoreGraphics
import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-552 (R3 P18): every way to mark a photograph, in every grid state, writes exactly the
/// mark requests it means — never two, never the latch's verb where it does not apply, never a
/// card. The unit half of the latch matrix; `LatchMatrixUITests` is the same matrix on the real
/// surface.
///
/// The latch rules are the design record's R3-17 (BookStack page 4336): "The latch survives
/// scroll, grouping, filter and size changes and a scene round trip; it ends with Done, leaving
/// the folder, or Select." The survival and exit tests at the end assert exactly that sentence,
/// with every latch made through an entry point a reader has (the bar's double press, Tap to
/// Pick), never `forceLatch`.
///
/// Each cell drives the SAME store entry points the views call (`GridView`'s tile tap is
/// `tapCell`, the bar's Pick/Dislike `activateLatchButton`, the corner
/// `tapReceivedByMarkCorner`, P/X the shortcut handlers, Clear `applyMarkToTarget(.none)`, the
/// loupe's bar `applyLoupeMark` and its Lock rows `toggleLockFromLoupe`) and asserts the decoded
/// mark-request bodies the action added, as `"<state>:<ids>"`.
@MainActor
@Suite("IMGMGR-552 — the latch matrix: every mark entry point in every grid state")
struct LatchMatrixTests {
  private typealias Fixtures = LatchMatrixFixtures

  private func applied(_ id: Int) -> GridStubTransport.MarkMutationOutcome {
    .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: id, revision: "r-\(id)")]))
  }

  /// The mark requests written since `baseline` requests had been.
  private func delta(_ fixture: LatchFixture, since baseline: Int) async -> [String] {
    Array(await Fixtures.markWrites(fixture.transport).dropFirst(baseline))
  }

  private func written(_ fixture: LatchFixture) async -> Int {
    await Fixtures.markWrites(fixture.transport).count
  }

  private func wire(_ verb: LatchVerb) -> String {
    switch verb {
    case .pick: "pick"
    case .dislike: "dislike"
    }
  }

  // MARK: - The 54 cells

  @Test(
    "One entry point in one grid state writes exactly the mark requests it means",
    arguments: LatchState.allCases, LatchEntry.allCases)
  func cell(state: LatchState, entry: LatchEntry) async {
    let fixture = await Fixtures.build(state)
    let cell = "[\(state) × \(entry)]"
    if state == .loupe {
      await loupeCell(fixture, entry, cell)
    } else {
      await gridCell(fixture, entry, cell)
    }
  }

  private func gridCell(_ fixture: LatchFixture, _ entry: LatchEntry, _ cell: String) async {
    let store = fixture.store
    #expect(!store.isLoupeOpen, "\(cell) precondition: the grid, not the loupe")
    #expect(store.pickLock.latchedVerb == nil, "\(cell) precondition: no latch")
    switch entry {
    case .latchPick, .latchDislike:
      let verb: LatchVerb = entry == .latchPick ? .pick : .dislike
      await store.tapCell(.image(fixture.focus))
      #expect(store.focusedImageID == fixture.focus, "\(cell) the tap did not focus")
      // Setup: the FIRST press of the pair applies the verb to the focus, the second latches.
      var baseline = await written(fixture)
      await fixture.transport.setMarkStateOutcome(applied(fixture.focus))
      await store.activateLatchButton(verb)
      await store.activateLatchButton(verb)
      #expect(
        await delta(fixture, since: baseline) == ["\(wire(verb)):\(fixture.focus)"],
        "\(cell) setup: the double press")
      #expect(store.pickLock.latchedVerb == verb, "\(cell) the double press did not latch")
      // The exercised tap: exactly one request, the latched verb on the tapped photograph.
      baseline = await written(fixture)
      await fixture.transport.setMarkStateOutcome(applied(fixture.tap))
      await store.tapCell(.image(fixture.tap))
      #expect(
        await delta(fixture, since: baseline) == ["\(wire(verb)):\(fixture.tap)"],
        "\(cell) the latched tap")
      #expect(!store.isLoupeOpen, "\(cell) a latched tap opened the loupe")
      store.done()
      #expect(store.pickLock.latchedVerb == nil, "\(cell) Done did not end the latch")

    case .tapToPick:
      let baseline = await written(fixture)
      store.toggleTapToPick()
      #expect(store.pickLock.latchedVerb == .pick, "\(cell) Tap to Pick did not latch Pick")
      #expect(await delta(fixture, since: baseline) == [], "\(cell) setup: the toggle wrote")
      await fixture.transport.setMarkStateOutcome(applied(fixture.tap))
      await store.tapCell(.image(fixture.tap))
      #expect(
        await delta(fixture, since: baseline) == ["pick:\(fixture.tap)"], "\(cell) the latched tap")
      store.toggleTapToPick()
      #expect(store.pickLock.latchedVerb == nil, "\(cell) the second press did not exit")
      #expect(await delta(fixture, since: baseline).count == 1, "\(cell) the exit wrote")

    case .corner:
      let baseline = await written(fixture)
      await fixture.transport.setMarkStateOutcome(applied(fixture.corner))
      let centre = CGPoint(x: QuickPickCorner.side / 2, y: QuickPickCorner.side / 2)
      await store.tapReceivedByMarkCorner(
        fixture.corner, at: centre, tileSize: CGSize(width: 200, height: 200))
      #expect(
        await delta(fixture, since: baseline) == ["\(fixture.cornerWrites):\(fixture.corner)"],
        "\(cell) the corner one-shot")
      #expect(store.focusedImageID == fixture.corner, "\(cell) the corner did not focus")
      #expect(!store.isLoupeOpen, "\(cell) the corner opened the loupe")
      #expect(store.pickLock.latchedVerb == nil, "\(cell) the corner latched")

    case .keys:
      await store.tapCell(.image(fixture.focus))
      let baseline = await written(fixture)
      await fixture.transport.setMarkStateOutcome(applied(fixture.focus))
      await store.handlePickShortcut(shiftHeld: false)
      await store.handleDislikeShortcut(shiftHeld: false)
      #expect(
        await delta(fixture, since: baseline)
          == ["pick:\(fixture.focus)", "dislike:\(fixture.focus)"], "\(cell) P then X")
      #expect(store.pickLock.latchedVerb == nil, "\(cell) a key latched")

    case .clear:
      await store.tapCell(.image(fixture.focus))
      let baseline = await written(fixture)
      await fixture.transport.setMarkStateOutcome(applied(fixture.focus))
      await store.applyMarkToTarget(.none)
      #expect(
        await delta(fixture, since: baseline) == ["none:\(fixture.focus)"], "\(cell) Clear")
    }
  }

  /// S9: the loupe has its own latch entry (the Lock rows) and its own bar. Tap to Pick and the
  /// corner are not N/A by choice: the toggle is laid only on the grid's action bar and the
  /// corner only by the grid's cell builder, which `LatchMatrixUITests.testLoupe…` proves on the
  /// real surface. Here those two cells assert the loupe is the surface and nothing was written.
  private func loupeCell(_ fixture: LatchFixture, _ entry: LatchEntry, _ cell: String) async {
    let store = fixture.store
    #expect(store.isLoupeOpen, "\(cell) precondition: the loupe is open")
    #expect(store.focusedImageID == fixture.focus, "\(cell) precondition: the loupe frame")
    switch entry {
    case .latchPick, .latchDislike:
      let verb: LatchVerb = entry == .latchPick ? .pick : .dislike
      var baseline = await written(fixture)
      store.toggleLockFromLoupe(verb)
      #expect(store.pickLock.latchedVerb == verb, "\(cell) the Lock row did not latch")
      #expect(await delta(fixture, since: baseline) == [], "\(cell) setup: the Lock row wrote")
      // In the loupe the latch never double-applies: the bar's verb writes once.
      await fixture.transport.setMarkStateOutcome(applied(fixture.focus))
      _ = await store.applyLoupeMark(verb.markState)
      #expect(
        await delta(fixture, since: baseline) == ["\(wire(verb)):\(fixture.focus)"],
        "\(cell) the loupe's own \(wire(verb))")
      // Back: the latch is the grid's, so the next tile tap writes the latched verb.
      store.closeLoupe()
      baseline = await written(fixture)
      await fixture.transport.setMarkStateOutcome(applied(fixture.tap))
      await store.tapCell(.image(fixture.tap))
      #expect(
        await delta(fixture, since: baseline) == ["\(wire(verb)):\(fixture.tap)"],
        "\(cell) the latched tap after Back")
      store.done()
      #expect(store.pickLock.latchedVerb == nil, "\(cell) Done did not end the latch")

    case .tapToPick, .corner:
      // N/A on this surface (see the doc comment); the cell proves only that it IS the surface.
      #expect(await written(fixture) == 0, "\(cell) N/A: nothing may have been written")

    case .keys:
      let baseline = await written(fixture)
      await fixture.transport.setMarkStateOutcome(applied(fixture.focus))
      await store.handlePickShortcut(shiftHeld: false)
      await store.handleDislikeShortcut(shiftHeld: false)
      #expect(
        await delta(fixture, since: baseline)
          == ["pick:\(fixture.focus)", "dislike:\(fixture.focus)"], "\(cell) P then X")
      #expect(store.isLoupeOpen, "\(cell) a key closed the loupe")

    case .clear:
      let baseline = await written(fixture)
      await fixture.transport.setMarkStateOutcome(applied(fixture.focus))
      _ = await store.applyLoupeMark(.none)
      #expect(
        await delta(fixture, since: baseline) == ["none:\(fixture.focus)"], "\(cell) Clear")
    }
  }

  // MARK: - R3-17: what the latch survives (A4)

  /// R1 (IMGMGR-552): a switch into Scene and back out is a scene round trip, which R3-17 says
  /// the latch survives. On the way, a latched tap on a CARD pushes and writes nothing.
  @Test(
    "The latch survives Flat → Scene → Flat; a latched card tap writes nothing",
    arguments: [LatchVerb.pick, .dislike])
  func latchSurvivesASceneRoundTrip(verb: LatchVerb) async {
    let (store, transport) = await Fixtures.flatStoreWithScenes()
    let fixture = LatchFixture(
      store: store, transport: transport, focus: 3, tap: 4, corner: 4, cornerWrites: "pick")
    // Latched through the bar's own double press on a focused photograph.
    await store.tapCell(.image(3))
    await transport.setMarkStateOutcome(applied(3))
    await store.activateLatchButton(verb)
    await store.activateLatchButton(verb)
    #expect(store.pickLock.latchedVerb == verb, "precondition: the double press latched")
    let baseline = await written(fixture)

    await store.selectGrouping(.scene)
    #expect(store.displayMode == .scene)
    #expect(store.pickLock.latchedVerb == verb, "entering Scene ended the latch")

    await store.tapCell(.stack(5))
    #expect(store.enteredSceneID == 5, "the latched card tap did not push")
    #expect(await delta(fixture, since: baseline) == [], "a latched card tap wrote a mark")
    store.leaveScene()

    await store.selectGrouping(.none)
    #expect(store.displayMode == .flat)
    #expect(store.pickLock.latchedVerb == verb, "leaving Scene ended the latch")

    await transport.setMarkStateOutcome(applied(4))
    await store.tapCell(.image(4))
    #expect(
      await delta(fixture, since: baseline) == ["\(wire(verb)):4"],
      "one latched tap after the round trip")
  }

  /// R3-17's survival list on one Mark-grouped folder: scroll, grouping, a push into the
  /// remainder and Back, filter, size, layout — after each, still latched, and a latched tap
  /// still writes exactly one request.
  @Test("The latch survives scroll, grouping, a push and Back, filter, size and layout")
  func latchSurvivesEveryNonExitTransition() async {
    let (store, transport) = await Fixtures.markStore()
    let fixture = LatchFixture(
      store: store, transport: transport, focus: 1, tap: 2, corner: 1, cornerWrites: "none")
    store.toggleTapToPick()
    #expect(store.pickLock.latchedVerb == .pick, "precondition: Tap to Pick latched")

    func stillLatched(_ after: String, tapping id: Int) async {
      #expect(store.pickLock.latchedVerb == .pick, "\(after) ended the latch")
      let baseline = await written(fixture)
      await transport.setMarkStateOutcome(applied(id))
      await store.tapCell(.image(id))
      #expect(
        await delta(fixture, since: baseline) == ["pick:\(id)"],
        "after \(after): one latched tap on \(id)")
    }

    await store.loadMoreIfNeeded(currentItemID: 5)
    await stillLatched("scroll", tapping: 2)
    await store.selectGrouping(.key(.rating))
    await store.selectGrouping(.key(.mark))
    await store.refreshGroupHeaders()
    await stillLatched("a grouping change", tapping: 3)
    store.enterRemainder()
    #expect(store.enteredRemainder == .mark, "precondition: the remainder opened")
    await stillLatched("the push into the remainder", tapping: 8)
    store.leaveScene(.userBack)
    await store.pendingReconcile?.value
    await stillLatched("Back", tapping: 1)
    await store.applyFilterChange { $0.ratingMin = 1 }
    await stillLatched("a filter change", tapping: 2)
    store.setRowHeight(.step260)
    await stillLatched("a size change", tapping: 3)
    store.setLayoutStyle(.square)
    await stillLatched("the Square layout", tapping: 1)
  }

  // MARK: - R3-17: what ends the latch (A4)

  @Test("Done ends the latch")
  func doneEndsTheLatch() async {
    let (store, _) = await Fixtures.flatStoreWithScenes()
    store.toggleTapToPick()
    #expect(store.pickLock.latchedVerb == .pick)
    store.done()
    #expect(store.pickLock.latchedVerb == nil)
  }

  @Test("Select ends the latch — the Select command and a long press alike")
  func selectEndsTheLatch() async {
    let (store, _) = await Fixtures.flatStoreWithScenes()
    store.toggleTapToPick()
    store.enterSelectExplicitly()
    #expect(store.pickLock.latchedVerb == nil, "the Select command kept the latch")
    store.done()
    store.toggleTapToPick()
    #expect(store.pickLock.latchedVerb == .pick)
    store.longPressCell(.image(2))
    #expect(store.pickLock.latchedVerb == nil, "a long press into Select kept the latch")
  }

  /// "Start with Tap to Pick" is OFF here, explicitly: with it on, a folder change ends the old
  /// latch and then latches Pick afresh on purpose (IMGMGR-548), which would hide the exit.
  @Test("Leaving the folder ends the latch")
  func leavingTheFolderEndsTheLatch() async {
    let (store, transport) = await Fixtures.flatStoreWithScenes(startsWithTapToPick: false)
    store.toggleTapToPick()
    #expect(store.pickLock.latchedVerb == .pick)
    await transport.setListImagesPage(
      .init(items: [Fixtures.image(40)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)
    #expect(store.pickLock.latchedVerb == nil)
  }
}
