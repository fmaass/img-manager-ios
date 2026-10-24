import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-541 (R3-6, R3-21): grouped by Mark or Rating, the photographs without one are ONE
/// remainder row, entered like a scene.
///
/// The fixture reproduces the server's bucketing at the vendored commit (`app/api/groups.py`):
/// `pick` then `dislike`, then the null bucket LAST, whatever the direction. 500 photographs:
/// picks 1…5, dislikes 6…7, and 8…500 without a mark, served 100 to a page.
@MainActor
@Suite("GridStore — Mark/Rating groups and the remainder row (IMGMGR-541)")
struct GridStoreMarkGroupTests {

  // MARK: - Fixture

  private func makeImage(id: Int, groupKey: String?, mark: MarkStateValue = .none)
    -> Components.Schemas.ImageSummary
  {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "raf", filename: "DSCF\(id).raf", folderId: 1, groupKey: groupKey,
      hasEdit: false, id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(
        revision: "r0", state: Components.Schemas.MarkView.StatePayload(rawValue: mark.rawValue),
        tags: []), missing: false,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  /// The server's grouped order for one mark assignment: picks, dislikes, then the null bucket.
  /// `descending` reverses photographs WITHIN each group only — never the groups.
  private func orderedIDs(picks: [Int], dislikes: [Int], descending: Bool = false)
    -> [(id: Int, key: String?)]
  {
    let marked = Set(picks + dislikes)
    let rest = (1...500).filter { !marked.contains($0) }
    func within(_ ids: [Int]) -> [Int] { descending ? ids.sorted(by: >) : ids.sorted() }
    var ordered: [(id: Int, key: String?)] = []
    for id in within(picks) { ordered.append((id, "pick")) }
    for id in within(dislikes) { ordered.append((id, "dislike")) }
    for id in within(rest) { ordered.append((id, nil)) }
    return ordered
  }

  /// Serves `ordered` 100 to a page through cursors "c2"…"c5", with the matching headers.
  private func serve(
    _ ordered: [(id: Int, key: String?)], picks: [Int], dislikes: [Int],
    on transport: GridStubTransport
  ) async {
    let summaries = ordered.map { id, key in
      makeImage(
        id: id, groupKey: key,
        mark: picks.contains(id) ? .pick : dislikes.contains(id) ? .dislike : .none)
    }
    let pages = stride(from: 0, to: summaries.count, by: 100).map {
      Array(summaries[$0..<min($0 + 100, summaries.count)])
    }
    for (index, items) in pages.enumerated() {
      let next = index + 1 < pages.count ? "c\(index + 2)" : nil
      let page = Components.Schemas.ImagePage(items: items, limit: 100, nextCursor: next)
      if index == 0 {
        await transport.setListImagesPage(page)
      } else {
        await transport.setListImagesPage(page, forCursor: "c\(index + 1)")
      }
    }
    await transport.setImageGroupsResult(
      Components.Schemas.ImageGroups(
        costHint: .standard, groupBy: .mark,
        headers: [
          .init(count: picks.count, key: "pick", label: "Pick"),
          .init(count: dislikes.count, key: "dislike", label: "Dislike"),
          .init(count: 500 - picks.count - dislikes.count, key: nil, label: "Unknown"),
        ], timezone: nil, total: 500))
  }

  private func makeStore() -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    return (GridStore(service: GridService(client: client)), transport)
  }

  private let picks = Array(1...5)
  private let dislikes = [6, 7]

  /// Folder 1, grouped by Mark, headers vouched.
  private func groupedByMark(descending: Bool = false) async -> (GridStore, GridStubTransport) {
    let (store, transport) = makeStore()
    await serve(
      orderedIDs(picks: picks, dislikes: dislikes, descending: descending), picks: picks,
      dislikes: dislikes, on: transport)
    await store.selectShoot(folderID: 1)
    if descending { await store.setSortDirection(.desc) }
    await store.selectGrouping(.key(.mark))
    await store.refreshGroupHeaders()
    return (store, transport)
  }

  private func listCursors(_ transport: GridStubTransport) async -> [String?] {
    await transport.recordedListImagesQueries.map { $0["cursor"] }
  }

  // MARK: - The stream

  @Test("Grouped by Mark, the stream holds only the marked photographs")
  func groupedByMarkStreamHoldsOnlyMarkedPhotos() async {
    let (store, _) = await groupedByMark()
    #expect(store.images.map(\.id) == Array(1...7))
    #expect(store.remainderImages.map(\.id) == Array(8...100))
    #expect(store.remainderReached)
    #expect(store.remainderCursor == "c2")
    #expect(store.nextCursor == nil)
    #expect(!store.actionableImages.contains { $0.groupKey == nil })
  }

  @Test("The stream stops paging once the null bucket begins")
  func streamStopsPagingOnceTheNullBucketBegins() async {
    let (store, transport) = await groupedByMark()
    let before = await listCursors(transport)
    await store.loadMoreIfNeeded(currentItemID: 7)
    #expect(await listCursors(transport) == before)
  }

  @Test("A page ending exactly on the last marked photo pages on to find the boundary")
  func haltAtAPageEdgeFetchesTheNextPageToFindTheNullBoundary() async {
    let (store, transport) = makeStore()
    let marked = (1...7).map { makeImage(id: $0, groupKey: $0 <= 5 ? "pick" : "dislike") }
    let rest = (8...107).map { makeImage(id: $0, groupKey: nil) }
    await transport.setListImagesPage(.init(items: marked, limit: 100, nextCursor: "e2"))
    await transport.setListImagesPage(
      .init(items: rest, limit: 100, nextCursor: "e3"), forCursor: "e2")
    await serveHeadersOnly(transport, unmarked: 493)
    await store.selectShoot(folderID: 1)
    await store.selectGrouping(.key(.mark))
    await store.refreshGroupHeaders()
    #expect(!store.remainderReached)
    #expect(store.nextCursor == "e2")
    store.enterRemainder()
    #expect(store.entry == nil, "refused before the boundary is known")

    await store.loadMoreIfNeeded(currentItemID: 7)
    #expect(store.remainderReached)
    #expect(store.images.map(\.id) == Array(1...7))
    #expect(store.remainderImages.first?.id == 8)
    #expect(store.remainderCursor == "e3")
    #expect(store.nextCursor == nil)
  }

  private func serveHeadersOnly(_ transport: GridStubTransport, unmarked: Int) async {
    await transport.setImageGroupsResult(
      Components.Schemas.ImageGroups(
        costHint: .standard, groupBy: .mark,
        headers: [
          .init(count: 5, key: "pick", label: "Pick"),
          .init(count: 2, key: "dislike", label: "Dislike"),
          .init(count: unmarked, key: nil, label: "Unknown"),
        ], timezone: nil, total: 7 + unmarked))
  }

  @Test("An all-unmarked folder shows only the remainder row")
  func allUnmarkedFolderShowsOnlyTheRemainderRow() async {
    let (store, transport) = makeStore()
    await serve(orderedIDs(picks: [], dislikes: []), picks: [], dislikes: [], on: transport)
    await store.selectShoot(folderID: 1)
    await store.selectGrouping(.key(.mark))
    await store.refreshGroupHeaders()
    #expect(store.images.isEmpty)
    #expect(store.remainderReached)
    #expect(store.remainderCount == 500)
  }

  @Test("The remainder count is the server's header, never a tally of the loaded rows")
  func remainderCountIsTheServersHeaderNotATally() async {
    let (store, _) = await groupedByMark()
    #expect(store.remainderImages.count == 93)
    #expect(store.remainderCount == 493)
    let rows = renderRows(store)
    #expect(rows.last == .remainder(GroupRemainderRow(groupBy: .mark, count: 493)))
  }

  @Test("Camera grouping keeps its Unknown bucket in the stream, headed")
  func cameraUnknownStaysInTheStream() async {
    let (store, transport) = makeStore()
    await serve(
      orderedIDs(picks: picks, dislikes: dislikes), picks: picks, dislikes: dislikes,
      on: transport)
    await store.selectShoot(folderID: 1)
    await store.selectGrouping(.key(.camera))
    #expect(store.images.count == 100)
    #expect(store.remainderImages.isEmpty)
    #expect(!store.remainderReached)
    #expect(store.nextCursor == "c2")
  }

  private func renderRows(_ store: GridStore) -> [GridRenderRow] {
    GridSectionLayout.renderRows(
      rows: store.displayRows(for: .stream), groupBy: store.activeGrouping.groupByKey,
      headers: store.groupHeaders, timezone: nil, paneWidth: 400, targetRowHeight: 100,
      displayScale: 2,
      remainderCount: store.remainderReached ? store.remainderCount : nil
    ) { _, _ in .ok(width: 4000, height: 4000) }
  }

  @Test("Group order never reverses with the sort direction", arguments: [false, true])
  func groupOrderNeverReversesWithDirection(descending: Bool) async {
    let (store, _) = await groupedByMark(descending: descending)
    let order: [String] = renderRows(store).compactMap {
      switch $0 {
      case .header(let header): return header.dotTitle
      case .remainder(let row): return row.title
      case .tiles: return nil
      }
    }
    #expect(order == ["Picks · 5", "Dislikes · 2", "493 photos without a mark"])
    #expect(store.images.map(\.id) == (descending ? [5, 4, 3, 2, 1, 7, 6] : Array(1...7)))
  }

  @Test("An explicit none and no mark row at all are one bucket: the remainder")
  func explicitNoneAndNoMarkRowAreOneBucket() async {
    let (store, transport) = makeStore()
    let picked = makeImage(id: 1, groupKey: "pick", mark: .pick)
    let explicitNone = makeImage(id: 2, groupKey: nil, mark: .none)
    var noRow = makeImage(id: 3, groupKey: nil)
    noRow.mark.state = nil
    await transport.setListImagesPage(
      .init(items: [picked, explicitNone, noRow], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    await store.selectGrouping(.key(.mark))
    #expect(store.images.map(\.id) == [1])
    #expect(store.remainderImages.map(\.id) == [2, 3])
  }

  @Test("Entering the remainder is refused before the stream reaches it")
  func enterRemainderRefusedBeforeTheHalt() async {
    let (store, transport) = makeStore()
    let marked = (1...7).map { makeImage(id: $0, groupKey: $0 <= 5 ? "pick" : "dislike") }
    await transport.setListImagesPage(.init(items: marked, limit: 100, nextCursor: "e2"))
    await serveHeadersOnly(transport, unmarked: 493)
    await store.selectShoot(folderID: 1)
    await store.selectGrouping(.key(.mark))
    await store.refreshGroupHeaders()
    store.enterRemainder()
    #expect(store.entry == nil)
    #expect(!store.isInRemainder)
    #expect(store.activeScope == .stream)
  }

  /// The reconcile drops the vouched headers first, so a failed fetch can only leave the row
  /// hidden or, after the reload's own retry, at the server's new count — never the stale one.
  @Test("A failed groups fetch at the reconcile never leaves a stale count")
  func aFailedGroupsFetchAtReconcileNeverLeavesAStaleCount() async {
    let (store, transport) = await groupedByMark()
    store.enterRemainder()
    _ = await store.applyMark(.pick, to: [8])
    await serve(
      orderedIDs(picks: picks + [8], dislikes: dislikes), picks: picks + [8],
      dislikes: dislikes, on: transport)
    await transport.setImageGroupsShouldFail(true)
    store.leaveScene(.userBack)
    await store.pendingReconcile?.value
    #expect(store.remainderCount != 493, "a stale count survived the reconcile")
    #expect(store.remainderCount == nil || store.remainderCount == 492)
    let rows = renderRows(store)
    #expect(!rows.contains { $0 == .remainder(GroupRemainderRow(groupBy: .mark, count: 493)) })
  }

  @Test("A scene card is never a mark target after a Mark grouping round trip")
  func sceneCardIsNeverAMarkTargetAfterAMarkGroupingRoundTrip() async {
    let (store, transport) = makeStore()
    let scene = Components.Schemas.StackBrowsePage.ItemsPayloadPayload(
      value1: nil,
      value2: Components.Schemas.StackBrowseStackRow(
        anchorTakenAt: Date(timeIntervalSince1970: 1_700_000_000), editedCount: 0,
        hasPick: false, kind: .stack, matchedCount: 3, memberCount: 3, pickedCount: 0,
        representative: makeImage(id: 9, groupKey: nil), stackId: 5))
    await transport.setBrowseStacksPage(.init(items: [scene], limit: 100, nextCursor: nil))
    await serve(
      orderedIDs(picks: picks, dislikes: dislikes), picks: picks, dislikes: dislikes,
      on: transport)
    await store.selectShoot(folderID: 1)
    #expect(store.displayMode == .scene)
    await store.selectGrouping(.key(.mark))
    #expect(store.displayMode == .flat)
    await store.selectGrouping(.scene)
    #expect(store.displayMode == .scene)
    #expect(store.images.isEmpty && store.remainderImages.isEmpty)
    store.cardDidTakeFocus(5)
    #expect(store.markTargetImageIDs.isEmpty)
  }

  @Test("Opening another folder leaves the remainder")
  func openingAnotherFolderLeavesTheRemainder() async {
    let (store, _) = await groupedByMark()
    store.enterRemainder()
    await store.openShoot(folderID: 2)
    #expect(store.entry == nil)
    #expect(!store.isInRemainder)
  }

  // MARK: - The remainder: one partition, its own cursor

  @Test("A full traversal partitions the 500 photographs exactly once", arguments: [false, true])
  func fullTraversalPartitionsTheFolderExactlyOnce(descending: Bool) async {
    let (store, _) = await groupedByMark(descending: descending)
    store.enterRemainder()
    #expect(store.isInRemainder)
    var guardrail = 0
    while store.remainderCursor != nil, guardrail < 10 {
      guardrail += 1
      await store.loadMoreIfNeeded(currentItemID: store.remainderImages.last!.id)
    }
    let stream = store.images.map(\.id)
    let remainder = store.remainderImages.map(\.id)
    #expect(stream.count == 7)
    #expect(remainder.count == 493)
    #expect(Set(stream).isDisjoint(with: remainder))
    #expect(Set(stream).union(remainder) == Set(1...500))
    #expect(Set(stream).count == stream.count && Set(remainder).count == remainder.count)
  }

  @Test("Previous at the first remainder tile stays in the remainder")
  func previousAtTheFirstRemainderTileStaysInTheRemainder() async {
    let (store, _) = await groupedByMark()
    store.enterRemainder()
    store.openLoupe(on: 8)
    store.loupePrevious()
    #expect(store.focusedImageID == 8)
    #expect(store.loadedSuccessor(after: 7) == .absent, "no stream photo is in this scope")
  }

  @Test("Next after marking the last loaded remainder tile pages the remainder's own cursor")
  func nextAfterMarkingTheLastLoadedRemainderTileContinuesFromTheRemainderCursor() async {
    let (store, transport) = await groupedByMark()
    store.enterRemainder()
    _ = await store.applyMark(.pick, to: [100])
    let result = await store.successor(after: 100, pagesScenes: false)
    #expect(result == .found(101))
    let last = await transport.lastListImagesQuery
    #expect(last?["cursor"] == "c2")
    #expect(last?["group_by"] == "mark")
    #expect(await transport.recordedNeighboursQueries.isEmpty)
    let ids = store.remainderImages.map(\.id)
    #expect(ids == Array(8...200))
    #expect(Set(ids).isDisjoint(with: 1...7))
    #expect(store.remainderCursor == "c3")
    #expect(store.remainderImages.first { $0.id == 100 }?.mark.state == .pick)
  }

  @Test("A failed remainder page keeps the continuation cursor")
  func aFailedRemainderPageKeepsTheContinuationCursor() async {
    let (store, transport) = await groupedByMark()
    store.enterRemainder()
    await transport.setListImagesShouldFail(true)
    await store.loadMoreIfNeeded(currentItemID: 100)
    #expect(store.remainderCursor == "c2")
    #expect(store.remainderImages.map(\.id) == Array(8...100))
  }

  @Test("The stream's successor under Mark grouping never calls the neighbours endpoint")
  func streamSuccessorUnderMarkGroupingNeverCallsNeighbours() async {
    let (store, transport) = await groupedByMark()
    let result = await store.successor(after: 7, pagesScenes: false)
    #expect(result == .exhausted)
    #expect(await transport.recordedNeighboursQueries.isEmpty)
  }

  // MARK: - Stay in place, then reconcile

  @Test("A photo marked inside the remainder stays in place")
  func markingInsideTheRemainderKeepsThePhotoInPlace() async {
    let (store, _) = await groupedByMark()
    store.enterRemainder()
    _ = await store.applyMark(.pick, to: [8])
    #expect(store.remainderImages.first?.id == 8)
    #expect(store.remainderImages.first?.mark.state == .pick)
    #expect(store.images.map(\.id) == Array(1...7))
    #expect(store.remainderCount == 493)
  }

  @Test("Back after a mark reconciles: the row shrinks and the pick lands under Picks")
  func backAfterAMarkReconcilesAndTheRowShrinks() async {
    let (store, transport) = await groupedByMark()
    store.enterRemainder()
    _ = await store.applyMark(.pick, to: [8])
    await serve(
      orderedIDs(picks: picks + [8], dislikes: dislikes), picks: picks + [8],
      dislikes: dislikes, on: transport)
    store.leaveScene(.userBack)
    await store.pendingReconcile?.value
    #expect(store.entry == nil)
    #expect(store.remainderCount == 492)
    #expect(store.groupHeaders[.known("pick")]?.count == 6)
    #expect(store.images.map(\.id) == [1, 2, 3, 4, 5, 8, 6, 7])
    #expect(!store.remainderImages.contains { $0.id == 8 })
  }

  @Test("Back without a mark issues no request")
  func backWithoutAMarkIssuesNoRequest() async {
    let (store, transport) = await groupedByMark()
    store.enterRemainder()
    let lists = await transport.recordedListImagesQueries.count
    let groups = await transport.recordedImageGroupsQueries.count
    store.leaveScene(.userBack)
    await store.pendingReconcile?.value
    #expect(await transport.recordedListImagesQueries.count == lists)
    #expect(await transport.recordedImageGroupsQueries.count == groups)
    #expect(store.remainderCount == 493)
  }

  @Test("Back waits for an in-flight mark write before it refetches")
  func backWaitsForAnInFlightMarkWriteBeforeRefetching() async {
    let (store, transport) = await groupedByMark()
    store.enterRemainder()
    await transport.holdMarkStateRequests(true)
    let write = Task { await store.applyMark(.pick, to: [8]) }
    await transport.waitUntilMarkStateStarted()
    let lists = await transport.recordedListImagesQueries.count
    store.leaveScene(.userBack)
    for _ in 0..<50 { await Task.yield() }
    #expect(await transport.recordedListImagesQueries.count == lists, "refetched under the write")
    await serve(
      orderedIDs(picks: picks + [8], dislikes: dislikes), picks: picks + [8],
      dislikes: dislikes, on: transport)
    await transport.releaseMarkState()
    _ = await write.value
    await store.pendingReconcile?.value
    #expect(await transport.recordedListImagesQueries.count > lists)
    #expect(store.remainderCount == 492)
  }

  /// Pick→Clear, Dislike→Clear, Pick→Dislike (§2.4, T-S1…T-S3).
  nonisolated static let streamMarks: [(Int, MarkStateValue)] = [
    (1, .none), (6, .none), (1, .dislike),
  ]

  @Test("A stream mark stays in place until the folder is opened again", arguments: streamMarks)
  func aStreamMarkStaysThenLandsAfterReconcile(id: Int, to state: MarkStateValue) async {
    let (store, transport) = await groupedByMark()
    let index = store.images.firstIndex { $0.id == id }
    _ = await store.applyMark(state, to: [id])
    #expect(store.images.firstIndex { $0.id == id } == index)
    #expect(store.groupHeaders[.known("pick")]?.count == 5)
    #expect(store.groupHeaders[.known("dislike")]?.count == 2)

    let newPicks = picks.filter { $0 != id } + (state == .pick ? [id] : [])
    let newDislikes = dislikes.filter { $0 != id } + (state == .dislike ? [id] : [])
    await serve(
      orderedIDs(picks: newPicks, dislikes: newDislikes), picks: newPicks,
      dislikes: newDislikes, on: transport)
    await store.openShoot(folderID: 1)
    #expect(store.groupHeaders[.known("pick")]?.count == newPicks.count)
    #expect(store.groupHeaders[.known("dislike")]?.count == newDislikes.count)
    #expect(store.remainderCount == 500 - newPicks.count - newDislikes.count)
    let landed = store.images.first { $0.id == id }?.groupKey
    switch state {
    case .none: #expect(store.remainderImages.contains { $0.id == id })
    case .dislike: #expect(landed == "dislike")
    case .pick: #expect(landed == "pick")
    }
  }

  @Test("The next grouping change reconciles a stream mark")
  func aGroupingChangeReconcilesAStreamMark() async {
    let (store, transport) = await groupedByMark()
    _ = await store.applyMark(.none, to: [1])
    await serve(
      orderedIDs(picks: [2, 3, 4, 5], dislikes: dislikes), picks: [2, 3, 4, 5],
      dislikes: dislikes, on: transport)
    await store.selectGrouping(.none)
    await store.selectGrouping(.key(.mark))
    await store.refreshGroupHeaders()
    #expect(store.images.map(\.id) == [2, 3, 4, 5, 6, 7])
    #expect(store.remainderCount == 494)
  }

  // MARK: - One reload policy

  @Test("A foreground refresh preserves membership and order and patches fields")
  func foregroundRefreshPreservesMembershipAndOrder() async {
    let (store, transport) = await groupedByMark()
    var changed = (1...100).map { makeImage(id: $0, groupKey: nil) }
    changed[1] = makeImage(id: 2, groupKey: "dislike", mark: .dislike)
    await transport.setListImagesPage(.init(items: changed, limit: 100, nextCursor: "c2"))
    _ = await store.authoritativeRefresh()
    #expect(store.images.map(\.id) == Array(1...7))
    #expect(store.images[1].mark.state == .dislike)
    #expect(store.images[1].groupKey == "pick", "placed where it was")
    #expect(store.remainderCount == 493)
  }

  @Test("Cursor-invalid recovery keeps locally marked tiles where they were")
  func cursorInvalidRecoveryKeepsLocallyMarkedTiles() async {
    let (store, transport) = await groupedByMark()
    store.enterRemainder()
    _ = await store.applyMark(.pick, to: [100])
    await transport.armListImagesRejectNonNilCursorOnce()
    await store.loadMoreIfNeeded(currentItemID: 100)
    let ids = store.remainderImages.map(\.id)
    #expect(Array(ids.prefix(93)) == Array(8...100), "retained order untouched")
    #expect(store.remainderImages[92].mark.state == .pick)
    #expect(Set(ids).count == ids.count)
    #expect(Set(ids).isDisjoint(with: 1...7))
    #expect(ids.count == 193, "the continuation was recovered")
    #expect(store.remainderCursor == "c3")
  }

  @Test("A notice Retry keeps the entered remainder as it is")
  func noticeRetryPreservesTheEnteredRemainder() async {
    let (store, transport) = await groupedByMark()
    store.enterRemainder()
    _ = await store.applyMark(.pick, to: [9])
    await transport.setListImagesShouldFail(true)
    await store.loadMoreIfNeeded(currentItemID: 100)
    #expect(store.lastPageLoadError != nil)
    await transport.setListImagesShouldFail(false)
    await store.fullReload()
    #expect(store.isInRemainder)
    #expect(Array(store.remainderImages.map(\.id).prefix(3)) == [8, 9, 10])
    #expect(store.remainderImages.count == 193, "the failed page was retried")
    #expect(store.lastPageLoadError == nil)
  }

  @Test("A scope change leaves the remainder")
  func scopeChangeLeavesTheRemainder() async {
    let (store, _) = await groupedByMark()
    store.enterRemainder()
    await store.selectGrouping(.key(.camera))
    #expect(store.entry == nil)
    #expect(store.remainderImages.isEmpty)
  }

  @Test("Rating's remainder behaves like Mark's but Back never reconciles")
  func ratingBackNeverReconciles() async {
    let (store, transport) = makeStore()
    let rated = (1...7).map { makeImage(id: $0, groupKey: $0 <= 3 ? "5" : "3") }
    let unrated = (8...100).map { makeImage(id: $0, groupKey: nil) }
    await transport.setListImagesPage(.init(items: rated + unrated, limit: 100, nextCursor: nil))
    await transport.setImageGroupsResult(
      Components.Schemas.ImageGroups(
        costHint: .standard, groupBy: .rating,
        headers: [
          .init(count: 3, key: "5", label: "5"), .init(count: 4, key: "3", label: "3"),
          .init(count: 93, key: nil, label: "Unknown"),
        ], timezone: nil, total: 100))
    await store.selectShoot(folderID: 1)
    await store.selectGrouping(.key(.rating))
    await store.refreshGroupHeaders()
    #expect(store.images.map(\.id) == Array(1...7))
    store.enterRemainder()
    #expect(store.enteredRemainder == .rating)
    _ = await store.applyMark(.pick, to: [8])
    let lists = await transport.recordedListImagesQueries.count
    store.leaveScene(.userBack)
    await store.pendingReconcile?.value
    #expect(await transport.recordedListImagesQueries.count == lists)
  }

  // MARK: - IMGMGR-626: a keyset fixture whose photographs move

  /// The UI fixture's shoot (9001…9500: 9001…9005 picked, 9006…9007 disliked, the rest without a
  /// mark) served through `DebugMarkGroupsFixture`'s KEYSET cursors from `marks`, the server's
  /// state at request time. Serving it again after a write moves the photograph that write marked,
  /// and a cursor issued before still resolves — to the photographs after its OLD place.
  private static let keysetSeed: [Int: String] = {
    var marks: [Int: String] = [9006: "dislike", 9007: "dislike"]
    for id in 9001...9005 { marks[id] = "pick" }
    return marks
  }()

  private func serveKeyset(
    _ marks: [Int: String], groupBy: GroupByKey = .mark, on transport: GridStubTransport
  ) async {
    await transport.setListImagesResolver { query in
      DebugMarkGroupsFixture.page(query: query, marks: { marks[$0] ?? "none" })
    }
    await transport.setImageGroupsResult(
      DebugMarkGroupsFixture.groups(
        query: ["group_by": groupBy.rawValue], marks: { marks[$0] ?? "none" }))
  }

  private func keysetGrouped(
    by key: GroupByKey, marks: [Int: String]? = nil, descending: Bool = false
  ) async -> (GridStore, GridStubTransport) {
    let (store, transport) = makeStore()
    await serveKeyset(marks ?? Self.keysetSeed, groupBy: key, on: transport)
    await store.selectShoot(folderID: 1)
    if descending { await store.setSortDirection(.desc) }
    await store.selectGrouping(.key(key))
    await store.refreshGroupHeaders()
    return (store, transport)
  }

  /// 150 picks, so the stream itself pages: page one is 9001…9100, all picks.
  private static let longStreamSeed: [Int: String] = {
    var marks: [Int: String] = [:]
    for id in 9001...9150 { marks[id] = "pick" }
    return marks
  }()

  @Test("A keyset cursor resumes after its own photograph, never on it")
  func keysetCursorResumesAfterItsOwnPhotograph() {
    let marks = Self.longStreamSeed
    let first = DebugMarkGroupsFixture.page(query: ["group_by": "mark"]) { marks[$0] ?? "none" }
    #expect(first.nextCursor == "mg-pick-9100")
    let second = DebugMarkGroupsFixture.page(
      query: ["group_by": "mark", "cursor": "mg-pick-9100"], marks: { marks[$0] ?? "none" })
    #expect(second.items.first?.id == 9101)
    #expect(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
  }

  @Test("The keyset fixture moves a marked tail photograph and resolves its old cursor")
  func keysetFixtureMovesTheMarkedTailAndResolvesItsOldCursor() {
    var marks = Self.keysetSeed
    let query = ["group_by": "mark"]
    let before = DebugMarkGroupsFixture.page(query: query) { marks[$0] ?? "none" }
    #expect(before.items.last?.id == 9100)
    #expect(before.nextCursor == "mg-_-9100")
    marks[9100] = "pick"
    let after = DebugMarkGroupsFixture.page(query: query) { marks[$0] ?? "none" }
    #expect(Array(after.items.prefix(6).map(\.id)) == [9001, 9002, 9003, 9004, 9005, 9100])
    let resumed = DebugMarkGroupsFixture.page(
      query: ["group_by": "mark", "cursor": "mg-_-9100"], marks: { marks[$0] ?? "none" })
    #expect(resumed.items.map(\.id) == Array(9101...9200))
  }

  // T-N2 on the moving fixture.
  @Test("Next after marking the remainder's tail resumes the cursor issued before the move")
  func nextAfterMarkingTheTailResumesTheCursorIssuedBeforeTheMove() async {
    let (store, transport) = await keysetGrouped(by: .mark)
    store.enterRemainder()
    #expect(store.remainderCursor == "mg-_-9100")
    _ = await store.applyMark(.pick, to: [9100])
    await serveKeyset(Self.keysetSeed.merging([9100: "pick"]) { $1 }, on: transport)
    let result = await store.successor(after: 9100, pagesScenes: false)
    #expect(result == .found(9101))
    #expect(await transport.lastListImagesQuery?["cursor"] == "mg-_-9100")
    #expect(await transport.recordedNeighboursQueries.isEmpty)
    let ids = store.remainderImages.map(\.id)
    #expect(ids == Array(9008...9200))
    #expect(Set(ids).isDisjoint(with: 9001...9007))
    #expect(store.remainderCursor == "mg-_-9200")
    #expect(store.remainderImages.first { $0.id == 9100 }?.mark.state == .pick)
  }

  // T-R2 (remainder) on the moving fixture.
  @Test("Cursor-invalid recovery in the remainder after the tail photograph moved")
  func remainderRecoveryAfterTheTailMoved() async {
    let (store, transport) = await keysetGrouped(by: .mark)
    store.enterRemainder()
    _ = await store.applyMark(.pick, to: [9100])
    await serveKeyset(Self.keysetSeed.merging([9100: "pick"]) { $1 }, on: transport)
    await transport.armListImagesRejectNonNilCursorOnce()
    await store.loadMoreIfNeeded(currentItemID: 9100)
    var ids = store.remainderImages.map(\.id)
    #expect(Array(ids.prefix(93)) == Array(9008...9100), "retained order untouched")
    #expect(store.remainderImages[92].mark.state == .pick)
    // Page one now ends at 9099 (9100 moved under Picks), so the recovered page is 9101…9200.
    #expect(ids == Array(9008...9200), "only the new photographs are appended")
    #expect(store.remainderCursor == "mg-_-9200", "the dead cursor is replaced")
    await store.loadMoreIfNeeded(currentItemID: 9200)
    ids = store.remainderImages.map(\.id)
    #expect(ids == Array(9008...9300))
    #expect(Set(ids).isDisjoint(with: 9001...9007))
  }

  // T-R2 for the stream.
  @Test("Cursor-invalid recovery in the stream keeps a locally marked tile where it was")
  func streamRecoveryKeepsALocallyMarkedTileWhereItWas() async {
    let (store, transport) = await keysetGrouped(by: .mark, marks: Self.longStreamSeed)
    #expect(store.images.map(\.id) == Array(9001...9100))
    #expect(store.nextCursor == "mg-pick-9100")
    _ = await store.applyMark(.dislike, to: [9050])
    await serveKeyset(Self.longStreamSeed.merging([9050: "dislike"]) { $1 }, on: transport)
    await transport.armListImagesRejectNonNilCursorOnce()
    await store.loadMoreIfNeeded(currentItemID: 9100)
    var ids = store.images.map(\.id)
    #expect(Array(ids.prefix(100)) == Array(9001...9100), "retained order untouched")
    #expect(store.images[49].mark.state == .dislike)
    #expect(store.images[49].groupKey == "pick", "placed where it was")
    #expect(ids.count == 101 && ids.last == 9101, "only the new photograph is appended")
    #expect(store.nextCursor == "mg-pick-9101", "the dead cursor is replaced")
    await store.loadMoreIfNeeded(currentItemID: 9101)
    ids = store.images.map(\.id)
    #expect(ids == Array(9001...9150), "9050 is never appended a second time")
    #expect(store.remainderReached)
    #expect(Set(ids).isDisjoint(with: store.remainderImages.map(\.id)))
  }

  // MARK: - IMGMGR-626: recovery keeps paging ownership

  @Test(
    "Cursor recovery keeps paging ownership: an overlapping tail request waits it out",
    arguments: [false, true])
  func cursorRecoveryKeepsPagingOwnership(inRemainder: Bool) async {
    let (store, transport) = await keysetGrouped(
      by: .mark, marks: inRemainder ? Self.keysetSeed : Self.longStreamSeed)
    if inRemainder { store.enterRemainder() }
    await transport.armListImagesRejectNonNilCursorOnce()
    await transport.holdNextListImagesRequest()
    let first = Task { await store.loadMoreIfNeeded(currentItemID: 9100) }
    await transport.waitUntilListImagesStarted()
    #expect(store.isLoadingPage, "the recovery's page-one request runs without owning paging")
    let issued = await listCursors(transport)
    await store.loadMoreIfNeeded(currentItemID: 9100)
    #expect(await listCursors(transport) == issued, "a second tail request started mid-recovery")
    await transport.releaseListImages()
    await first.value
    #expect(!store.isLoadingPage)
    if inRemainder {
      #expect(store.remainderImages.map(\.id) == Array(9008...9200))
      #expect(store.remainderCursor == "mg-_-9200")
    } else {
      #expect(store.images.map(\.id) == Array(9001...9150))
      #expect(store.nextCursor == nil)
      #expect(store.remainderImages.map(\.id) == Array(9151...9200))
    }
  }

  // MARK: - IMGMGR-626: a reconcile whose stream reload fails

  @Test("A failed stream reload at the reconcile never vouches fresh counts over the old rows")
  func aFailedReloadAtTheReconcileNeverVouchesFreshCounts() async {
    let (store, transport) = await groupedByMark()
    store.enterRemainder()
    _ = await store.applyMark(.pick, to: [8])
    await serve(
      orderedIDs(picks: picks + [8], dislikes: dislikes), picks: picks + [8],
      dislikes: dislikes, on: transport)
    await transport.setListImagesShouldFail(true)
    store.leaveScene(.userBack)
    await store.pendingReconcile?.value
    #expect(store.lastPageLoadError != nil, "the reload did not fail")
    #expect(store.images.map(\.id) == Array(1...7), "the stream was not reconciled")
    #expect(store.groupHeaders.isEmpty, "headers were vouched for the unreconciled rows")
    #expect(store.remainderCount == nil)
    let titles: [String] = renderRows(store).compactMap {
      switch $0 {
      case .header(let header): return header.dotTitle
      case .remainder(let row): return row.title
      case .tiles: return nil
      }
    }
    #expect(!titles.contains("Picks · 6"))
    #expect(!titles.contains("492 photos without a mark"))
  }

  // MARK: - IMGMGR-626: coverage the P13 plan named

  // T-O1 for Rating.
  @Test("Rating's group order never reverses with the sort direction", arguments: [false, true])
  func ratingGroupOrderNeverReversesWithDirection(descending: Bool) async {
    let (store, _) = await keysetGrouped(by: .rating, descending: descending)
    let order: [String] = renderRows(store).compactMap {
      switch $0 {
      case .header(let header): return header.dotTitle
      case .remainder(let row): return row.title
      case .tiles: return nil
      }
    }
    #expect(order == ["5 · 3", "4 · 2", "1 · 2", "493 photos without a rating"])
    let expected = descending ? [9003, 9002, 9001, 9005, 9004, 9007, 9006] : Array(9001...9007)
    #expect(store.images.map(\.id) == expected)
  }

  // T-N1 for Triage.
  @Test("Triage inside the remainder starts on its first tile and never steps into the stream")
  func triageInsideTheRemainderStaysInTheRemainder() async {
    let (store, _) = await groupedByMark()
    store.enterRemainder()
    #expect(store.triagePool.map(\.id) == Array(8...100), "no stream photo is in the pool")
    let session = TriageSession(store: store)
    #expect(session.cursor == 8)
    #expect(session.position == 1)
    session.didDisplay(8)
    await session.decide(.skip)
    #expect(session.cursor == 9)
    await session.undo()
    #expect(session.cursor == 8)
    #expect(!session.canUndo, "nothing before the first remainder tile")
    await session.undo()
    #expect(session.cursor == 8)
    #expect(store.isInRemainder)
  }

  // The scope-change test for a filter change.
  @Test("A filter change leaves the remainder")
  func filterChangeLeavesTheRemainder() async {
    let (store, transport) = await groupedByMark()
    store.enterRemainder()
    await store.applyFilterChange { $0.keyword = "street" }
    #expect(store.entry == nil)
    #expect(!store.isInRemainder)
    #expect(store.activeScope == .stream)
    #expect(store.query.keyword == "street")
    #expect(await transport.lastListImagesQuery?["cursor"] == nil)
    #expect(store.remainderImages.map(\.id) == Array(8...100), "the new query's own first page")
    #expect(store.remainderCursor == "c2")
  }
}
