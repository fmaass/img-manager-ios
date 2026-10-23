import CoreGraphics
import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-542 (R3-22): the peek band's layout, ordering, scroll restore, marks, filmstrip and
/// load races — the rest of the plan's unit list beside `PeekBandTests`.
///
/// Store fixture: one folder; the stream is loose 10, scene 5 {1, 2, 3} (cover 900), scene 6
/// {7, 8} (cover 901), loose 11. The covers are not members, so a cover that leaks into a band
/// or a payload shows as its own id.
@MainActor
@Suite("IMGMGR-542 — peek band layout, restore, marks and races")
struct PeekBandStateTests {
  private typealias MarkPayload = Components.Schemas.MarkView.StatePayload
  private typealias WireState = Components.Schemas.MarkStateRequest.StatePayload
  private typealias Item = Components.Schemas.StackBrowsePage.ItemsPayloadPayload

  private let t0: TimeInterval = 1_700_000_000
  private let t1: TimeInterval = 1_700_003_600
  private let markOp = Operations.SetMarkStateApiMarksStatePost.id
  private let membersOp = Operations.ListStackMembersApiStacksStackIdMembersGet.id

  // MARK: - Fixtures

  private func image(_ id: Int, mark: MarkPayload = MarkPayload.none, aspect: Double = 1.0)
    -> Components.Schemas.ImageSummary
  {
    Components.Schemas.ImageSummary(
      aspectRatio: aspect, ext: "raf", filename: "DSCF\(id).raf", folderId: 1, hasEdit: false,
      id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: mark, tags: []), missing: false,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func row(_ id: Int, count: Int, matched: Int? = nil, anchor: TimeInterval, cover: Int)
    -> Components.Schemas.StackBrowseStackRow
  {
    Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: Date(timeIntervalSince1970: anchor), editedCount: 0, hasPick: false,
      kind: .stack, matchedCount: matched ?? count, memberCount: count, pickedCount: 0,
      representative: image(cover), stackId: id)
  }

  private func scene(_ id: Int, count: Int, anchor: TimeInterval, cover: Int) -> Item {
    .init(value1: nil, value2: row(id, count: count, anchor: anchor, cover: cover))
  }

  private func loose(_ id: Int) -> Item {
    .init(value1: .init(image: image(id), kind: .image), value2: nil)
  }

  private func page(_ items: [Item], next: String? = nil) -> Components.Schemas.StackBrowsePage {
    Components.Schemas.StackBrowsePage(items: items, limit: 100, nextCursor: next)
  }

  private func members(
    _ images: [Components.Schemas.ImageSummary], of stackID: Int, next: String? = nil
  ) -> Components.Schemas.StackMemberPage {
    Components.Schemas.StackMemberPage(
      items: images, limit: 100, nextCursor: next, stackId: stackID)
  }

  private func members(_ ids: [Int], of stackID: Int, next: String? = nil)
    -> Components.Schemas.StackMemberPage
  {
    members(ids.map { image($0) }, of: stackID, next: next)
  }

  private func applied(_ id: Int) -> GridStubTransport.MarkMutationOutcome {
    .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: id, revision: "r-\(id)")]))
  }

  private var streamItems: [Item] {
    [
      loose(10), scene(5, count: 3, anchor: t0, cover: 900),
      scene(6, count: 2, anchor: t1, cover: 901), loose(11),
    ]
  }

  private func sceneStore(_ items: [Item]? = nil) async -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let store = GridStore(service: GridService(client: client))
    await transport.setBrowseStacksPage(page(items ?? streamItems))
    await transport.setStackMemberPage(members([1, 2, 3], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([7, 8], of: 6), forStack: 6)
    await store.selectShoot(folderID: 1)
    await store.setDisplayMode(.scene)
    return (store, transport)
  }

  private func shown(_ store: GridStore) -> [GridDisplayID] {
    store.displayRows(for: .stream).map(\.id)
  }

  private func markRequests(_ transport: GridStubTransport) async -> Int {
    await transport.recordedWire.filter { $0.operationID == markOp }.count
  }

  // MARK: - Pure layout fixtures

  private let alwaysAvailable: (GridDisplayID, ProxyTier) -> ProxyAvailability = { _, _ in
    .ok(width: 4000, height: 4000)
  }

  private func photo(_ id: Int, aspect: Double = 1.0) -> SceneDisplayRow {
    .image(image(id, aspect: aspect))
  }

  private func card(_ id: Int) -> SceneDisplayRow {
    .stack(row(id, count: 3, anchor: t0, cover: 900 + id))
  }

  private func band(_ stackID: Int, _ ids: [Int]) -> SceneBand {
    SceneBand(
      stackID: stackID, rows: ids.map { photo($0, aspect: [1.5, 0.667, 1.333, 1.0][$0 % 4]) })
  }

  private func render(
    _ rows: [SceneDisplayRow], bands: [SceneBand] = [], paneWidth: CGFloat = 800,
    spacing: CGFloat = 2
  ) -> [GridRenderRow] {
    GridSectionLayout.renderRows(
      rows: rows, groupBy: nil, headers: [:], timezone: nil, paneWidth: paneWidth,
      targetRowHeight: 200, displayScale: 2, spacing: spacing, bands: bands,
      availability: alwaysAvailable)
  }

  private func tiles(_ rendered: [GridRenderRow]) -> [PackedRow] {
    rendered.compactMap(\.packedRow)
  }

  private func height(_ row: PackedRow) -> CGFloat {
    guard let first = row.cells.first, case .display(_, let size) = first.plan else { return 0 }
    return size.height
  }

  private func width(_ row: PackedRow) -> CGFloat {
    row.cells.reduce(CGFloat(0)) { sum, cell in
      guard case .display(_, let size) = cell.plan else { return sum }
      return sum + size.width
    }
  }

  /// The y of every row's top edge: the heights of the rows above plus one gutter each.
  private func tops(_ rows: [PackedRow], spacing: CGFloat = 2) -> [CGFloat] {
    var y: CGFloat = 0
    return rows.map { row in
      defer { y += height(row) + spacing }
      return y
    }
  }

  /// Twelve photographs of mixed aspect around card 5, then card 6 and more photographs.
  private var layoutStream: [SceneDisplayRow] {
    (1...12).map { photo(100 + $0, aspect: [1.5, 0.667, 1.333][$0 % 3]) } + [card(5)]
      + (13...20).map { photo(100 + $0, aspect: 1.5) } + [card(6)] + [photo(130)]
  }

  // MARK: - U2–U5: layout

  @Test("U2: the rows above the band and the card's own row keep their packing and their y")
  func rowsAboveAndTheCardRowKeepTheirPackingWhenABandOpens() {
    let without = tiles(render(layoutStream))
    let with = tiles(render(layoutStream, bands: [band(5, Array(501...520))]))
    guard let cardRow = without.firstIndex(where: { $0.cells.contains { $0.id == .stack(5) } })
    else {
      Issue.record("card 5 was not packed")
      return
    }
    #expect(Array(with[...cardRow]) == Array(without[...cardRow]))
    let topsWithout = tops(without)
    let topsWith = tops(with)
    #expect(Array(topsWith[...cardRow]) == Array(topsWithout[...cardRow]))
    #expect(with[cardRow + 1].band == 5)
    #expect(topsWith[cardRow + 1] == topsWith[cardRow] + height(with[cardRow]) + 2)
  }

  @Test("U3: band rows are justified to the full width; the trailing row is not stretched")
  func bandRowsAreJustifiedToTheFullWidth() {
    let rows = tiles(render([card(5)], bands: [band(5, Array(501...540))], paneWidth: 800))
      .filter { $0.band == 5 }
    #expect(rows.count >= 3)
    for row in rows.dropLast() {
      let gutters = 2 * CGFloat(row.cells.count - 1)
      #expect(abs(width(row) + gutters - 800) <= 0.5)
    }
    if let last = rows.last {
      #expect(height(last) <= 200 + 0.5)
    }
    // One member is one band row (boundary).
    let single = tiles(render([card(5)], bands: [band(5, [501])])).filter { $0.band == 5 }
    #expect(single.count == 1)
    #expect(single.first?.cells.map(\.id) == [.image(501)])
  }

  @Test("U4: two bands under one row follow the order they were opened")
  func twoBandsUnderOneRowFollowInsertionOrder() async {
    let rendered = tiles(
      render([card(5), card(6)], bands: [band(6, [601, 602]), band(5, [501, 502])]))
    #expect(rendered.first?.cells.map(\.id) == [.stack(5), .stack(6)])
    #expect(rendered.map(\.band) == [nil, 6, 5])
    let (store, _) = await sceneStore()
    await store.togglePeekBand(6)
    await store.togglePeekBand(5)
    #expect(store.peekBandRows.map(\.stackID) == [6, 5])
  }

  @Test("U4b: bands on different rows follow their cards, not the order they were opened")
  func bandsOnDifferentRowsFollowCardOrderNotInsertionOrder() {
    // A 150-pt pane packs one 200-pt tile per row, so every card owns its own row.
    let rendered = tiles(
      render(
        [card(5), photo(10), card(6)], bands: [band(6, [601]), band(5, [501])], paneWidth: 150))
    #expect(rendered.map(\.band) == [nil, 5, nil, nil, 6])
    #expect(rendered.map(\.id) == [.stack(5), .image(501), .image(10), .stack(6), .image(601)])
  }

  @Test("U5: a band is uncapped and pages on with its own cursor")
  func aBandIsUncapped() async {
    let (store, transport) = await sceneStore()
    let first = Array(10_000..<10_500)
    let second = Array(10_500..<10_750)
    await transport.setStackMemberPage(members(first, of: 5, next: "m2"), forStack: 5)
    await transport.setStackMemberPage(members(second, of: 5), forCursor: "m2")
    await store.togglePeekBand(5)
    #expect(store.peekBandRows.first?.rows.count == 500)
    await store.loadMoreSceneMembers(stackID: 5)
    #expect(store.peekBandRows.first?.rows.map(\.id) == (first + second).map(GridDisplayID.image))
    #expect(shown(store).filter { if case .image = $0 { true } else { false } }.count == 752)
  }

  // MARK: - U8: order of opening

  @Test("U8: reopening a band makes it the most recent")
  func reopeningABandMakesItTheMostRecent() async {
    let (store, _) = await sceneStore()
    await store.togglePeekBand(5)
    await store.togglePeekBand(6)
    await store.togglePeekBand(5)
    await store.togglePeekBand(5)
    #expect(store.openBandIDs == [6, 5])
    store.closeMostRecentBand()
    #expect(store.openBandIDs == [6])
  }

  @Test(
    "U8b: closing either of two bands leaves the other open, its members intact",
    arguments: [5, 6])
  func closingEitherOfTwoBandsLeavesTheOtherOpenWithItsMembersIntact(closing: Int) async {
    let (store, _) = await sceneStore()
    await store.togglePeekBand(5)
    await store.togglePeekBand(6)
    let other = closing == 5 ? 6 : 5
    let kept = store.peekBandRows.filter { $0.stackID == other }
    await store.togglePeekBand(closing)
    #expect(store.openBandIDs == [other])
    #expect(store.peekBandRows == kept)
  }

  // MARK: - U9: scroll restore

  @Test("U9: closing keeps an anchor that survives")
  func closingKeepsASurvivingAnchor() async {
    let (store, _) = await sceneStore()
    await store.togglePeekBand(5)
    store.recordScrollAnchor(.image(11), for: .stream)
    store.collapseAllBands()
    #expect(store.scrollAnchor(for: .stream) == .image(11))
    #expect(store.bandCloseAnchor == .image(11))
  }

  @Test("U9: closing from inside a band goes back to where it was opened")
  func closingFromInsideABandRestoresItsOpenAnchor() async {
    let (store, _) = await sceneStore()
    store.recordScrollAnchor(.image(10), for: .stream)
    await store.togglePeekBand(5)
    store.recordScrollAnchor(.image(2), for: .stream)
    let revision = store.bandCloseRevision
    await store.togglePeekBand(5)
    #expect(store.scrollAnchor(for: .stream) == .image(10))
    #expect(store.bandCloseRevision == revision + 1)
  }

  @Test("U9: an open anchor that no longer exists falls back to the band's card")
  func aStaleOpenAnchorFallsBackToTheCard() async {
    let (store, _) = await sceneStore()
    await store.togglePeekBand(5)
    store.recordScrollAnchor(.image(3), for: .stream)
    await store.togglePeekBand(6)
    #expect(store.peekBands.last?.anchorAtOpen == .image(3))
    await store.togglePeekBand(5)
    #expect(store.scrollAnchor(for: .stream) == .stack(5))
    // Member 3 is gone with band 5, so band 6's open anchor no longer names a rendered row.
    #expect(store.peekBands.first?.anchorAtOpen == nil)
    store.recordScrollAnchor(.image(7), for: .stream)
    await store.togglePeekBand(6)
    #expect(store.scrollAnchor(for: .stream) == .stack(6))
  }

  @Test("U9: Collapse all never lands inside a band it is closing")
  func collapseAllNeverLandsInsideAClosingBand() async {
    let (store, _) = await sceneStore()
    await store.togglePeekBand(5)
    store.recordScrollAnchor(.image(2), for: .stream)
    await store.togglePeekBand(6)
    store.recordScrollAnchor(.image(8), for: .stream)
    store.collapseAllBands()
    let anchor = store.scrollAnchor(for: .stream)
    #expect(anchor == .stack(6))
    #expect(![.image(1), .image(2), .image(3), .image(7), .image(8)].contains(anchor))
  }

  @Test("U9: stored anchors are revalidated after a refresh")
  func anchorsAreRevalidatedAfterARefreshOrTopologyChange() async {
    let (store, transport) = await sceneStore()
    await store.togglePeekBand(5)
    store.recordScrollAnchor(.image(2), for: .stream)
    await store.togglePeekBand(6)
    await transport.setStackMemberPage(members([1, 3], of: 5), forStack: 5)
    #expect(await store.authoritativeRefresh())
    #expect(store.openBandIDs == [5, 6])
    #expect(store.peekBands.last?.anchorAtOpen == nil)
    #expect(store.scrollAnchor(for: .stream) == .image(1))
  }

  @Test("U9: a refresh dropping the anchored member and its card lands on the row before them")
  func aRefreshRemovingTheAnchoredMemberAndItsCardFallsBackToTheNearestSurvivingPredecessor()
    async
  {
    let (store, transport) = await sceneStore()
    await store.togglePeekBand(5)
    store.recordScrollAnchor(.image(2), for: .stream)
    await transport.setBrowseStacksPage(
      page([loose(10), scene(6, count: 2, anchor: t1, cover: 901), loose(11)]))
    #expect(await store.authoritativeRefresh())
    #expect(store.openBandIDs.isEmpty)
    #expect(store.scrollAnchor(for: .stream) == .image(10))
    #expect(store.scrollAnchor(for: .stream) != .stack(5))
  }

  @Test("U9: a refresh dropping everything before the anchor leaves no anchor")
  func aRefreshRemovingEverythingBeforeTheAnchorLeavesNoAnchor() async {
    let (store, transport) = await sceneStore([
      scene(5, count: 3, anchor: t0, cover: 900), scene(6, count: 2, anchor: t1, cover: 901),
      loose(11),
    ])
    await store.togglePeekBand(5)
    store.recordScrollAnchor(.image(2), for: .stream)
    await transport.setBrowseStacksPage(
      page([scene(6, count: 2, anchor: t1, cover: 901), loose(11)]))
    #expect(await store.authoritativeRefresh())
    #expect(store.scrollAnchor(for: .stream) == nil)
  }

  @Test("U9: with no surviving candidate the close names no row, so nothing scrolls")
  func noCandidateMeansNoScroll() {
    let restore = GridScrollAnchor.anchorAfterClosing(
      current: .image(2), closing: [PeekBand(stackID: 5, anchorAtOpen: .image(1))],
      members: [5: [1, 2, 3]], surviving: [],
      streamOrder: [.stack(5), .image(1), .image(2), .image(3)])
    #expect(restore == nil)
    #expect(
      GridScrollAnchor.firstSurviving(
        [nil, .stack(5)], surviving: [.image(11)], predecessorOf: .stack(5),
        streamOrder: [.stack(5), .image(11)]) == nil)
  }

  // MARK: - U10b, U11: marks inside a band

  @Test("U10b: P, X, U and the latched tap write a band member, never the card")
  func pickDislikeAndClearWriteABandMember() async {
    let (store, transport) = await sceneStore()
    await store.togglePeekBand(5)
    await store.tapCell(.image(2))
    #expect(store.focusedImageID == 2)

    await transport.setMarkStateOutcome(applied(2))
    await store.handlePickShortcut(shiftHeld: false)
    #expect(await transport.lastMarkStateRequest?.imageIds == [2])
    #expect(await transport.lastMarkStateRequest?.state == WireState.pick)

    await store.handleDislikeShortcut(shiftHeld: false)
    #expect(await transport.lastMarkStateRequest?.imageIds == [2])
    #expect(await transport.lastMarkStateRequest?.state == WireState.dislike)

    await store.handleClearShortcut(shiftHeld: false)
    #expect(await transport.lastMarkStateRequest?.imageIds == [2])
    #expect(await transport.lastMarkStateRequest?.state == WireState.none)

    await transport.setMarkStateOutcome(applied(3))
    store.pickLock.forceLatch(.pick)
    await store.tapCell(.image(3))
    #expect(await transport.lastMarkStateRequest?.imageIds == [3])
    #expect(await transport.lastMarkStateRequest?.state == WireState.pick)
    let written = await markRequests(transport)
    #expect(written == 4)

    // The card under a latch pushes its scene and writes nothing.
    await store.tapCell(.stack(5))
    #expect(await markRequests(transport) == written)
  }

  @Test(
    "U11: a member marked inside a band stays in place under a Mark filter",
    arguments: ["pick", "dislike", "clear"])
  func aMemberMarkedInsideABandStaysUnderAMarkFilter(verb: String) async {
    let (store, transport) = await sceneStore()
    await store.applyFilterChange { $0.mark = "none" }
    await transport.setStackMemberPage(
      members([image(1), image(2), image(3, mark: .pick)], of: 5), forStack: 5)
    await store.togglePeekBand(5)
    let before = shown(store)
    #expect(before.contains(.image(2)) && before.contains(.image(3)))

    let target = verb == "clear" ? 3 : 2
    let state: MarkStateValue = verb == "pick" ? .pick : (verb == "dislike" ? .dislike : .none)
    await transport.setStackRow(
      row(5, count: 3, matched: 1, anchor: t0, cover: 900), forStack: 5)
    await transport.setMarkStateOutcome(applied(target))
    #expect(await store.applyMark(state, to: [target]))

    #expect(shown(store) == before, "\(verb): the band moved")
    let listed = store.sceneRows.compactMap { row -> Components.Schemas.StackBrowseStackRow? in
      guard case .stack(let stack) = row, stack.stackId == 5 else { return nil }
      return stack
    }.first
    #expect(listed?.matchedCount == 1, "\(verb): the card's matched_count was not re-read")
  }

  // MARK: - U12c: the loupe walk across bands

  @Test("U12c: a loose photograph has no strip; its walk crosses open bands in card order")
  func aLoosePhotographsStripWalksOpenBandsInCardOrderAndSkipsClosedOnes() async {
    let (store, _) = await sceneStore()
    await store.togglePeekBand(6)
    await store.togglePeekBand(5)
    store.openLoupe(on: 10)
    #expect(FilmstripScope.resolve(for: store) == .hidden)
    #expect(store.actionableImages.map(\.id) == [10, 1, 2, 3, 7, 8, 11])
    #expect(store.loadedSuccessor(after: 10) == .next(1))
    #expect(store.loadedSuccessor(after: 3) == .next(7))
    store.focusedImageID = 7
    #expect(FilmstripScope.resolve(for: store) == .members(store.sceneMembers[6] ?? []))
    // A closed band is skipped: the walk goes from the loose photograph straight to band 6.
    store.focusedImageID = 10
    store.collapseAllBands()
    await store.togglePeekBand(6)
    #expect(store.loadedSuccessor(after: 10) == .next(7))
    #expect(store.openSceneMembers(containing: 2) == nil)
  }

  // MARK: - U13, U14, U17: the window around the band

  @Test("U13: a band whose card left the window is not rendered")
  func aBandWhoseCardLeftTheWindowIsNotRendered() async {
    let (store, transport) = await sceneStore()
    await store.togglePeekBand(5)
    await store.togglePeekBand(6)
    await transport.setBrowseStacksPage(
      page([loose(10), scene(5, count: 3, anchor: t0, cover: 900), loose(11)]))
    #expect(await store.authoritativeRefresh())
    #expect(store.openBandIDs == [5])
    #expect(store.peekBandRows.map(\.stackID) == [5])
    #expect(shown(store) == [.image(10), .stack(5), .image(1), .image(2), .image(3), .image(11)])
  }

  @Test("U14: leaving Scene or grouping by Mark closes every band")
  func leavingSceneOrSwitchingToMarkGroupingClosesEveryBand() async {
    let (store, _) = await sceneStore()
    await store.togglePeekBand(5)
    await store.setDisplayMode(.flat)
    #expect(store.openBandIDs.isEmpty)
    #expect(store.peekBandRows.isEmpty)
    await store.setDisplayMode(.scene)
    #expect(store.openBandIDs.isEmpty)
    #expect(shown(store) == [.image(10), .stack(5), .stack(6), .image(11)])

    await store.togglePeekBand(6)
    #expect(store.openBandIDs == [6])
    await store.selectGrouping(.key(.mark))
    #expect(store.openBandIDs.isEmpty)
    #expect(!store.canCloseBand)
  }

  @Test("U17: a band survives entering and leaving a scene")
  func aBandSurvivesASceneRoundTrip() async {
    let (store, _) = await sceneStore()
    await store.togglePeekBand(5)
    let before = shown(store)
    await store.enterScene(6)
    store.leaveScene()
    #expect(store.openBandIDs == [5])
    #expect(shown(store) == before)
    await store.enterScene(5)
    store.leaveScene()
    #expect(store.openBandIDs == [5])
    #expect(shown(store) == before)
  }

  // MARK: - U15b, U15c: load races

  @Test("U15b: a second chevron tap while the band loads closes it")
  func aSecondChevronTapWhileLoadingClosesIt() async {
    let (store, transport) = await sceneStore()
    await transport.holdStackMembersRequests(true)
    let opening = Task { await store.togglePeekBand(5) }
    await transport.waitUntilStackMembersStarted()
    await store.togglePeekBand(5)
    #expect(store.openBandIDs.isEmpty)
    await transport.releaseStackMembers()
    await opening.value
    #expect(store.openBandIDs.isEmpty)
    #expect(shown(store) == [.image(10), .stack(5), .stack(6), .image(11)])
    #expect(await transport.callCount(membersOp) == 1)
  }

  @Test("U15c: a page from an earlier opening of the same band is dropped")
  func aPageFromAnEarlierOpeningOfTheSameBandIsDropped() async {
    let (store, transport) = await sceneStore()
    await transport.holdStackMembersRequests(true)
    let firstOpening = Task { await store.togglePeekBand(5) }
    await transport.waitUntilStackMembersStarted()
    store.closeMostRecentBand()
    let reopening = Task { await store.togglePeekBand(5) }
    while await transport.callCount(membersOp) < 2 { await Task.yield() }
    #expect(store.openBandIDs == [5])

    // The first opening's page lands first, with members the reopened band must never show.
    await transport.setStackMemberPage(members([97, 98], of: 5), forStack: 5)
    await transport.releaseStackMembers()
    await firstOpening.value
    #expect(store.sceneMembers[5] == nil)
    #expect(store.peekBandRows.isEmpty)

    await transport.setStackMemberPage(members([1, 2, 3], of: 5), forStack: 5)
    await transport.releaseStackMembers()
    await reopening.value
    #expect(store.sceneMembers[5]?.map(\.id) == [1, 2, 3])
    #expect(shown(store).contains(.image(2)))
    #expect(!shown(store).contains(.image(97)))
  }

  // MARK: - U19: pack time

  @Test("U19: packing the stand-in folder with three open bands takes at most 4 ms (median)")
  func renderRowsPackTimeWithThreeStandInBands() {
    var stream: [SceneDisplayRow] = []
    for index in 0..<240 {
      stream.append(card(80_001 + index))
      stream.append(photo(90_001 + index, aspect: [1.5, 0.667, 1.333, 1.0][index % 4]))
    }
    let bands = (0..<3).map { offset in
      band(80_001 + offset, (1...60).map { (80_001 + offset) * 100 + $0 })
    }
    let clock = ContinuousClock()
    var samples: [Duration] = []
    for _ in 0..<20 {
      let start = clock.now
      _ = render(stream, bands: bands, paneWidth: 1024)
      samples.append(clock.now - start)
    }
    let median = samples.sorted()[samples.count / 2]
    #expect(
      tiles(render(stream, bands: bands, paneWidth: 1024)).filter { $0.band != nil }
        .flatMap(\.cells).count == 180)
    #expect(median <= .milliseconds(4), "median pack time \(median)")
  }
}
