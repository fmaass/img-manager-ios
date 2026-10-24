import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-586: a mark write that fails is recorded and offered for Retry instead of only rolling
/// the tile back, and a mark tap made while another mark write is in flight waits its turn on the
/// lane instead of being dropped.
@MainActor
@Suite("GridStore — unsaved mark writes and queued mark taps (IMGMGR-586)")
struct UnsavedMarksTests {

  private func makeImage(
    id: Int, mark: Components.Schemas.MarkView.StatePayload = .none, revision: String = "r0"
  ) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: revision, state: mark, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func loadedStore(_ ids: [Int] = [1]) async -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let store = GridStore(service: GridService(client: client))
    await transport.setListImagesPage(
      .init(items: ids.map { makeImage(id: $0) }, limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    return (store, transport)
  }

  private func markCalls(_ transport: GridStubTransport) async -> Int {
    await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
  }

  private func state(_ store: GridStore, _ id: Int) -> MarkStateValue? {
    store.images.first(where: { $0.id == id }).map { MarkStateValue($0.mark.state) }
  }

  private func succeeds(_ ids: [Int], revision: String) -> GridStubTransport.MarkMutationOutcome {
    .success(
      .init(
        applied: ids.count, requested: ids.count,
        revisions: ids.map { .init(imageId: $0, revision: revision) }))
  }

  /// Bounded, so a call that is refused instead of queued fails the test instead of hanging it.
  private func waitUntilQueued(_ store: GridStore, count: Int = 1) async {
    for _ in 0..<10_000 where store.laneWaiterCount < count {
      await Task.yield()
    }
  }

  // MARK: - Failed writes are recorded, never silent

  @Test("A failed pick rolls the tile back and is recorded as unsaved with what it asked for")
  func failedPickIsRecorded() async {
    let (store, transport) = await loadedStore()
    await transport.setMarkStateOutcome(.serverError)

    let committed = await store.applyMark(.pick, to: [1])

    #expect(!committed)
    #expect(state(store, 1) == MarkStateValue.none, "the refused pick was not rolled back")
    #expect(store.unsavedMarks.count == 1)
    #expect(store.unsavedMarks[1]?.state == .pick)
    #expect(store.unsavedMarks[1]?.prior.revisionBefore == "r0")
    #expect(UnsavedMarksCopy.message(for: store.unsavedMarks.values) == "1 pick didn't save")
  }

  @Test("Retry after the transport recovers re-sends the failed write; success clears it")
  func retryResendsAndClears() async {
    let (store, transport) = await loadedStore([1, 2])
    await transport.setMarkStateOutcome(.serverError)
    await store.applyMark(.pick, to: [1, 2])
    #expect(store.unsavedMarks.count == 2)
    #expect(UnsavedMarksCopy.message(for: store.unsavedMarks.values) == "2 picks didn't save")

    await transport.setMarkStateOutcome(succeeds([1, 2], revision: "r1"))
    await store.retryUnsavedMarks()

    #expect(await markCalls(transport) == 2)
    let request = await transport.lastMarkStateRequest
    #expect(request?.state == .pick)
    #expect(Set(request?.imageIds ?? []) == [1, 2])
    #expect(Set(request?.preconditions?.map(\.revision) ?? []) == ["r0"])
    #expect(store.unsavedMarks.isEmpty)
    #expect(state(store, 1) == .pick)
    #expect(state(store, 2) == .pick)
    #expect(store.images.map(\.mark.revision) == ["r1", "r1"])
  }

  @Test("A Retry that fails again keeps the count and leaves the tile on server truth")
  func retryThatFailsKeepsTheRecord() async {
    let (store, transport) = await loadedStore()
    await transport.setMarkStateOutcome(.serverError)
    await store.applyMark(.dislike, to: [1])

    await store.retryUnsavedMarks()

    #expect(await markCalls(transport) == 2, "Retry sent nothing")
    #expect(store.unsavedMarks[1]?.state == .dislike)
    #expect(store.unsavedMarks.count == 1)
    #expect(state(store, 1) == MarkStateValue.none)
    #expect(UnsavedMarksCopy.message(for: store.unsavedMarks.values) == "1 mark didn't save")
    // The failed Retry released the photograph: a new tap on it is sent, not refused.
    await store.applyMark(.dislike, to: [1])
    #expect(await markCalls(transport) == 3, "the photograph stayed pending after a failed Retry")
  }

  @Test("Nothing unsaved: Retry sends nothing")
  func retryWithNothingUnsavedIsANoOp() async {
    let (store, transport) = await loadedStore()
    await store.retryUnsavedMarks()
    #expect(await markCalls(transport) == 0)
    #expect(store.unsavedMarks.isEmpty)
  }

  @Test("A later saved write to the same photograph clears its record: the last tap wins")
  func laterSuccessClearsOnlyThatPhotograph() async {
    let (store, transport) = await loadedStore([1, 2])
    await transport.setMarkStateOutcome(.serverError)
    await store.applyMark(.pick, to: [1])
    await store.applyMark(.pick, to: [2])
    #expect(Set(store.unsavedMarks.keys) == [1, 2])

    await transport.setMarkStateOutcome(succeeds([1], revision: "r1"))
    await store.applyMark(.dislike, to: [1])
    #expect(Set(store.unsavedMarks.keys) == [2])

    await transport.setMarkStateOutcome(succeeds([2], revision: "r1"))
    await store.retryUnsavedMarks()
    let request = await transport.lastMarkStateRequest
    #expect(request?.imageIds == [2], "Retry re-sent a pick the later dislike had replaced")
    #expect(state(store, 1) == .dislike)
    #expect(state(store, 2) == .pick)
  }

  @Test("A later failed write replaces the photograph's record: the last tap wins")
  func laterFailureReplacesTheRecord() async {
    let (store, transport) = await loadedStore()
    await transport.setMarkStateOutcome(.serverError)
    await store.applyMark(.pick, to: [1])
    await store.applyMark(.dislike, to: [1])
    #expect(store.unsavedMarks.count == 1)
    #expect(store.unsavedMarks[1]?.state == .dislike)

    await transport.setMarkStateOutcome(succeeds([1], revision: "r1"))
    await store.retryUnsavedMarks()
    #expect(await transport.lastMarkStateRequest?.state == .dislike)
    #expect(state(store, 1) == .dislike)
  }

  @Test("A 409 belongs to the conflict banner and is never counted as unsaved")
  func conflictIsNotUnsaved() async {
    let (store, transport) = await loadedStore()
    await transport.setMarkStateOutcome(.serverError)
    await store.applyMark(.pick, to: [1])
    #expect(store.unsavedMarks.count == 1)

    await transport.setMarkStateOutcome(.conflict)
    await store.applyMark(.pick, to: [1])

    #expect(store.unsavedMarks.isEmpty, "one photograph under two banners")
    #expect(store.conflictRecovery != nil)
  }

  @Test("Retry still writes a photograph the scope it was picked in no longer shows")
  func retryWritesAcrossAScopeChange() async {
    let (store, transport) = await loadedStore()
    await transport.setMarkStateOutcome(.serverError)
    await store.applyMark(.pick, to: [1])

    await transport.setListImagesPage(.init(items: [makeImage(id: 5)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)
    #expect(store.images.map(\.id) == [5])
    #expect(store.unsavedMarks.count == 1, "leaving the shoot forgot the unsaved pick")

    await transport.setMarkStateOutcome(succeeds([1], revision: "r1"))
    await store.retryUnsavedMarks()
    let request = await transport.lastMarkStateRequest
    #expect(request?.imageIds == [1])
    #expect(request?.preconditions?.first?.revision == "r0")
    #expect(store.unsavedMarks.isEmpty)
  }

  @Test("A write that fails after its scope changed under it is still recorded as unsaved")
  func failureAfterAScopeChangeIsRecorded() async {
    let (store, transport) = await loadedStore()
    await transport.setMarkStateOutcome(.serverError)
    await transport.holdMarkStateRequests(true)
    async let write: Bool = store.applyMark(.pick, to: [1])
    await transport.waitUntilMarkStateStarted()

    await transport.setListImagesPage(.init(items: [makeImage(id: 5)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)
    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    _ = await write

    #expect(store.unsavedMarks[1]?.state == .pick, "the failed pick vanished with the scope")
  }

  @Test("IMGMGR-589: a Retry refused with a 409 after the reader switched shoots keeps the mark")
  func retryConflictAfterAScopeChangeKeepsTheMark() async throws {
    let (store, transport) = await loadedStore()
    await transport.setMarkStateOutcome(.serverError)
    await store.applyMark(.pick, to: [1])
    try #require(store.unsavedMarks.count == 1)

    await transport.setMarkStateOutcome(.conflict)
    await transport.holdMarkStateRequests(true)
    async let retry: Void = store.retryUnsavedMarks()
    await transport.waitUntilMarkStateStarted()

    await transport.setListImagesPage(.init(items: [makeImage(id: 5)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)
    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    _ = await retry

    #expect(await markCalls(transport) == 2, "1 refused write + 1 retry")
    // The 409 arrived in a scope that no longer shows the photograph, so the conflict banner
    // cannot take it; the unsaved banner keeps it, still against the revision it was made on.
    #expect(store.unsavedMarks[1]?.state == .pick, "the rejected pick is under neither banner")
    #expect(store.unsavedMarks[1]?.prior.revisionBefore == "r0")
  }

  @Test("Retry after a refresh sends the original precondition and lands in the conflict banner")
  func retryAfterARefreshConflicts() async throws {
    let (store, transport) = await loadedStore()
    await transport.setMarkStateOutcome(.serverError)
    await store.applyMark(.pick, to: [1])
    try #require(store.unsavedMarks.count == 1)

    // Another device changed the photograph meanwhile; the refresh shows its new revision.
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .dislike, revision: "r1")], limit: 100, nextCursor: nil))
    _ = await store.authoritativeRefresh()
    try #require(store.images.first?.mark.revision == "r1")
    try #require(store.unsavedMarks[1]?.prior.revisionBefore == "r0")

    await transport.setMarkStateOutcome(.conflict)
    await store.retryUnsavedMarks()

    let request = await transport.lastMarkStateRequest
    #expect(request?.imageIds == [1])
    #expect(request?.state == .pick)
    #expect(request?.preconditions?.first?.revision == "r0", "Retry overwrote the other device")
    guard case .identified(_, _, let changedIDs) = store.conflictRecovery else {
      Issue.record(
        "no conflict banner after the refused Retry: \(String(describing: store.conflictRecovery))")
      return
    }
    #expect(changedIDs == [1])
    #expect(store.unsavedMarks.isEmpty, "one photograph under two banners")
  }

  @Test("Two Retry presses racing send the failed write once")
  func racingRetriesWriteOnce() async throws {
    let (store, transport) = await loadedStore()
    await transport.setMarkStateOutcome(.serverError)
    await store.applyMark(.pick, to: [1])
    // Without a record there is no retry write to hold, and the wait below would never return.
    try #require(store.unsavedMarks.count == 1)

    await transport.setMarkStateOutcome(succeeds([1], revision: "r1"))
    await transport.holdMarkStateRequests(true)
    async let first: Void = store.retryUnsavedMarks()
    await transport.waitUntilMarkStateStarted()
    async let second: Void = store.retryUnsavedMarks()
    await waitUntilQueued(store)
    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    _ = await first
    _ = await second

    #expect(await markCalls(transport) == 2, "1 refused write + 1 retry, never a second retry")
    #expect(store.unsavedMarks.isEmpty)
    #expect(state(store, 1) == .pick)
  }

  @Test("A repeat tap on a photograph whose Retry write is out is refused, not queued as a Clear")
  func repeatTapDuringRetryIsRefused() async throws {
    let (store, transport) = await loadedStore()
    await transport.setMarkStateOutcome(.serverError)
    await store.applyMark(.pick, to: [1])
    try #require(store.unsavedMarks.count == 1)

    await transport.setMarkStateOutcome(succeeds([1], revision: "r1"))
    await transport.holdMarkStateRequests(true)
    async let retry: Void = store.retryUnsavedMarks()
    await transport.waitUntilMarkStateStarted()
    // Retry shows the photograph as picked, so the reader's second tap on it asks for a Clear.
    try #require(state(store, 1) == .pick)
    async let repeatTap: Bool = store.applyMark(.none, to: [1])
    await waitUntilQueued(store)
    #expect(store.laneWaiterCount == 0, "the repeat tap was queued behind the Retry")

    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    _ = await retry
    let tapLanded = await repeatTap

    #expect(!tapLanded)
    #expect(await markCalls(transport) == 2, "1 refused write + 1 retry, and no Clear after it")
    let last = await transport.lastMarkStateRequest
    #expect(last?.state == .pick)
    #expect(last?.imageIds == [1])
    #expect(store.unsavedMarks.isEmpty)
    #expect(state(store, 1) == .pick)
    #expect(store.images.first?.mark.revision == "r1")
    // Once the Retry has landed, the photograph takes taps again.
    #expect(await store.applyMark(.none, to: [1]))
    #expect(state(store, 1) == MarkStateValue.none)
  }

  @Test("Dismiss forgets the record and sends nothing")
  func dismissForgets() async {
    let (store, transport) = await loadedStore()
    await transport.setMarkStateOutcome(.serverError)
    await store.applyMark(.pick, to: [1])
    store.dismissUnsavedMarks()
    #expect(store.unsavedMarks.isEmpty)
    #expect(await markCalls(transport) == 1)
  }

  @Test("The banner copy counts picks, and says marks once anything else is in the set")
  func copyCountsPicksAndMarks() {
    func mark(_ id: Int, _ state: MarkStateValue) -> UnsavedMark {
      UnsavedMark(state: state, prior: .init(imageID: id, state: .none, revisionBefore: "r0"))
    }
    #expect(UnsavedMarksCopy.message(for: [mark(1, .pick)]) == "1 pick didn't save")
    #expect(
      UnsavedMarksCopy.message(for: [mark(1, .pick), mark(2, .pick)]) == "2 picks didn't save")
    #expect(UnsavedMarksCopy.message(for: [mark(1, .none)]) == "1 mark didn't save")
    #expect(
      UnsavedMarksCopy.message(for: [mark(1, .pick), mark(2, .dislike), mark(3, .none)])
        == "3 marks didn't save")
  }

  // MARK: - Taps during an in-flight write are queued, never dropped

  @Test(
    "Taps on other photographs during a held write land in tap order; a repeat tap on a photograph whose write is pending is refused"
  )
  func queuedTapsLandInOrderAndRepeatsAreRefused() async {
    let transport = GridStubTransport()
    let store = GridStore(
      service: GridService(client: ImgManagerAPIClient.make(transport: transport)))
    await transport.setListImagesPage(
      .init(
        items: [makeImage(id: 1), makeImage(id: 2), makeImage(id: 3, mark: .pick)], limit: 100,
        nextCursor: nil))
    await store.selectShoot(folderID: 1)
    await transport.setMarkStateOutcome(succeeds([1], revision: "r1"), forState: .pick)
    await transport.setMarkStateOutcome(succeeds([2], revision: "r2"), forState: .dislike)
    await transport.setMarkStateOutcome(succeeds([3], revision: "r3"), forState: .none)
    await transport.holdMarkStateRequests(true)

    async let first: Bool = store.applyMark(.pick, to: [1])
    await transport.waitUntilMarkStateStarted()
    async let second: Bool = store.applyMark(.dislike, to: [2])
    await waitUntilQueued(store, count: 1)
    // IMGMGR-475: an accidental double tap must not flip a pick back -- refused whether the
    // photograph's write is out (1) or still queued (2). Both answer at once, unqueued.
    #expect(await store.applyMark(.none, to: [1]) == false)
    #expect(await store.applyMark(.pick, to: [2]) == false)
    async let third: Bool = store.applyMark(.none, to: [3])
    await waitUntilQueued(store, count: 2)
    #expect(store.laneWaiterCount == 2, "a tap on another photograph was not queued")

    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    let answers = await [first, second, third]

    #expect(answers == [true, true, true])
    #expect(await markCalls(transport) == 3)
    let last = await transport.lastMarkStateRequest
    #expect(last?.imageIds == [3])
    #expect(last?.state == MarkStateValue.none.payloadForRequest)
    #expect(state(store, 1) == .pick)
    #expect(state(store, 2) == .dislike)
    #expect(state(store, 3) == MarkStateValue.none)
    // Once its write has landed, the photograph takes taps again.
    #expect(await store.applyMark(.none, to: [1]))
    #expect(state(store, 1) == MarkStateValue.none)
  }
}

extension MarkStateValue {
  fileprivate var payloadForRequest: Components.Schemas.MarkStateRequest.StatePayload {
    switch self {
    case .pick: .pick
    case .dislike: .dislike
    case .none: .none
    }
  }
}
