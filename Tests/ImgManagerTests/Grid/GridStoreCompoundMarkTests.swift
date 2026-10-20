import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// A store on the grid stub transport, for the Compare suites.
@MainActor
func makeCompareTestStore() -> (GridStore, GridStubTransport) {
  let transport = GridStubTransport()
  let client = ImgManagerAPIClient.make(transport: transport)
  return (GridStore(service: GridService(client: client)), transport)
}

/// WP30 P3 (IMGMGR-458), plan decision 6: a Compare verb is ONE store-level compound mark — one
/// lane acquisition, one `UndoEntry` covering exactly the groups that committed, no automatic
/// compensation — and `undoLastMark` answers an `UndoOutcome` fenced to its call's generation.
@MainActor
@Suite("GridStore — compound mark and UndoOutcome (WP30 P3)")
struct GridStoreCompoundMarkTests {
  private typealias MarkPayload = Components.Schemas.MarkView.StatePayload

  private func makeImage(id: Int, mark: MarkPayload) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: mark, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  /// Image 1 disliked, 2 picked, 3 unmarked — so Keep left on (1, 2) moves BOTH images to a new
  /// state and its undo has two groups (restore 1 to dislike, 2 to pick).
  private func loadedStore() async -> (GridStore, GridStubTransport) {
    let (store, transport) = makeCompareTestStore()
    let disliked = makeImage(id: 1, mark: .dislike)
    let picked = makeImage(id: 2, mark: .pick)
    let unmarked = makeImage(id: 3, mark: MarkPayload.none)
    let items = [disliked, picked, unmarked]
    await transport.setListImagesPage(.init(items: items, limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    return (store, transport)
  }

  /// Scene mode with scene 5 open on members 1 (disliked), 2 (picked) and 3: every mark or undo
  /// on 1 or 2 awaits scene 5's cover refresh (`GET /api/stacks/5`) AFTER its write landed, the
  /// window fold round 1's B1/B2 name.
  private func loadedSceneStore() async throws -> (GridStore, GridStubTransport) {
    let (store, transport) = makeCompareTestStore()
    let members = [
      makeImage(id: 1, mark: .dislike), makeImage(id: 2, mark: .pick),
      makeImage(id: 3, mark: MarkPayload.none),
    ]
    let row = Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: nil, editedCount: 0, hasPick: true, kind: .stack, matchedCount: 3,
      memberCount: 3, pickedCount: 1, representative: members[0], stackId: 5)
    let item = Components.Schemas.StackBrowsePage.ItemsPayloadPayload(value1: nil, value2: row)
    await transport.setBrowseStacksPage(.init(items: [item], limit: 100, nextCursor: nil))
    let memberPage = Components.Schemas.StackMemberPage(
      items: members, limit: 100, nextCursor: nil, stackId: 5)
    await transport.setStackMemberPage(memberPage, forStack: 5)
    await store.selectShoot(folderID: 1)
    await store.setDisplayMode(.scene)
    await store.enterScene(5)
    // Preconditions: without them a refresh that never starts would hang the wait below.
    let memberIDs = store.sceneMembers[5]?.map { $0.id }
    try #require(memberIDs == [1, 2, 3])
    let actionable = Set(store.actionableImages.map { $0.id })
    try #require(actionable.isSuperset(of: [1, 2]))
    return (store, transport)
  }

  private func markWrites(_ transport: GridStubTransport) async -> Int {
    await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
  }

  private func state(_ store: GridStore, _ id: Int) -> MarkPayload? {
    store.images.first { $0.id == id }?.mark.state
  }

  private var keepLeft: [CompoundMarkGroup] { CompareVerb.keepLeft.markGroups(left: 1, right: 2) }

  // MARK: - applyCompoundMark

  @Test("Both groups commit → ONE entry covering both priors, and undo restores both")
  func bothGroupsCommit() async {
    let (store, _) = await loadedStore()
    #expect(await store.applyCompoundMark(keepLeft) == .committed)
    #expect(state(store, 1) == .pick)
    #expect(state(store, 2) == .dislike)
    let priors = store.undo.entry?.priorStates.map { $0.imageID }
    #expect(priors == [1, 2])
    #expect(store.undo.entry?.priorStates.map { $0.state } == [.dislike, .pick])

    #expect(await store.undoLastMark() == .restoredAll)
    #expect(state(store, 1) == .dislike)
    #expect(state(store, 2) == .pick)
    #expect(store.undo.entry == nil)
  }

  @Test("The first group fails → nothing committed, no entry, the error surfaced")
  func firstGroupFails() async {
    let (store, transport) = await loadedStore()
    await transport.setMarkStateOutcome(.serverError, forState: .pick)
    #expect(await store.applyCompoundMark(keepLeft) == .failed)
    #expect(store.undo.entry == nil)
    #expect(store.lastMutationError != nil)
    #expect(state(store, 1) == .dislike)
    #expect(state(store, 2) == .pick)
  }

  @Test("The second group fails → the entry covers only the first group; the error is set")
  func secondGroupFails() async {
    let (store, transport) = await loadedStore()
    await transport.setMarkStateOutcome(.serverError, forState: .dislike)
    #expect(await store.applyCompoundMark(keepLeft) == .partial)
    #expect(store.undo.entry?.priorStates.map { $0.imageID } == [1])
    #expect(store.undo.entry?.priorStates.map { $0.state } == [.dislike])
    #expect(store.lastMutationError != nil)
    // Truthful and uncompensated: the first write stands, the second rolled back.
    #expect(state(store, 1) == .pick)
    #expect(state(store, 2) == .pick)
  }

  @Test("A conflict on either group → handleConflict, which clears the slot")
  func conflictClearsTheSlot() async {
    let (store, transport) = await loadedStore()
    #expect(await store.applyMark(.pick, to: [3]))
    #expect(store.undo.entry != nil)
    await transport.setMarkStateOutcome(.conflict, forState: .dislike)
    #expect(await store.applyCompoundMark(keepLeft) == .conflict)
    #expect(store.undo.entry == nil)
    #expect(store.lastMutationError == .conflict)
  }

  @Test(
    "The lane is held for the whole verb: a concurrent applyMark on one of its photographs is refused at each group"
  )
  func laneHeldAcrossTheVerb() async {
    let (store, transport) = await loadedStore()
    let groups = keepLeft
    await transport.holdMarkStateRequests(true)
    async let verb = store.applyCompoundMark(groups)

    // IMGMGR-586: a tap on ANOTHER photograph would queue behind the verb, so the refusal is
    // asserted on the verb's own photographs -- including 2, whose group has not started yet.
    await transport.waitUntilMarkStateStarted()
    #expect(store.isMutatingMark)
    #expect(await store.applyMark(.none, to: [2]) == false)
    await transport.releaseMarkState()

    await transport.waitUntilMarkStateStarted()
    #expect(store.isMutatingMark)
    #expect(await store.applyMark(.none, to: [1]) == false)
    #expect(store.laneWaiterCount == 0)
    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()

    #expect(await verb == .committed)
    #expect(!store.isMutatingMark)
    #expect(store.undo.entry?.priorStates.map { $0.imageID } == [1, 2])
  }

  @Test("Nothing loaded to write, or a busy lane → refused, nothing recorded")
  func refused() async {
    let (store, _) = await loadedStore()
    let absent = [CompoundMarkGroup(state: .pick, imageIDs: [99])]
    #expect(await store.applyCompoundMark(absent) == .refused)
    #expect(store.undo.entry == nil)
  }

  // MARK: - UndoOutcome

  @Test("undoLastMark with an empty slot answers .nothingToUndo")
  func nothingToUndo() async {
    let (store, _) = await loadedStore()
    #expect(await store.undoLastMark() == .nothingToUndo)
  }

  @Test("A failing group of a multi-group undo answers .partial")
  func failingGroupIsPartial() async {
    let (store, transport) = await loadedStore()
    #expect(await store.applyCompoundMark(keepLeft) == .committed)
    // Undo writes `dislike` (for 1) first, then `pick` (for 2); the second is refused.
    await transport.setMarkStateOutcome(.serverError, forState: .pick)
    #expect(await store.undoLastMark() == .partial)
    #expect(state(store, 1) == .dislike)
    #expect(state(store, 2) == .dislike)
    #expect(store.undo.entry?.priorStates.map { $0.imageID } == [2])
  }

  @Test("IMGMGR-482: a compound mark reports the token of the entry it recorded")
  func compoundMarkReportsTheRecordedToken() async {
    let (store, _) = await loadedStore()
    let report = await store.applyCompoundMarkReporting(keepLeft)
    #expect(report.result == .committed)
    #expect(report.entryToken != nil)
    #expect(report.entryToken == store.undo.entry?.token)
  }

  @Test("IMGMGR-482: a partial undo's remainder keeps the entry's token; the report names it")
  func partialUndoRemainderKeepsTheToken() async throws {
    let (store, transport) = await loadedStore()
    #expect(await store.applyCompoundMark(keepLeft) == .committed)
    let token = try #require(store.undo.entry?.token)
    await transport.setMarkStateOutcome(.serverError, forState: .pick)
    let report = await store.undoLastMarkReporting()
    #expect(report == UndoReport(outcome: .partial, entryToken: token))
    #expect(store.undo.entry?.token == token)
  }

  @Test("A generation change during the first group answers .scopeChanged")
  func generationChangeDuringFirstGroup() async {
    let (store, transport) = await loadedStore()
    #expect(await store.applyCompoundMark(keepLeft) == .committed)
    await transport.holdMarkStateRequests(true)
    async let undo = store.undoLastMark()
    await transport.waitUntilMarkStateStarted()
    await store.fullReload()
    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    #expect(await undo == .scopeChanged)
  }

  @Test("A generation change after the first group landed answers .scopeChanged, not .restoredAll")
  func generationChangeBetweenGroups() async {
    let (store, transport) = await loadedStore()
    #expect(await store.applyCompoundMark(keepLeft) == .committed)
    await transport.holdMarkStateRequests(true)
    async let undo = store.undoLastMark()
    await transport.waitUntilMarkStateStarted()
    await transport.releaseMarkState()
    // The first group has landed; the second is on the wire when the scope moves.
    await transport.waitUntilMarkStateStarted()
    await store.fullReload()
    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    #expect(await undo == .scopeChanged)
  }

  // MARK: - Fold round 1: the generation fence spans the scene refresh

  @Test(
    "B1: a generation change during a group's scene refresh writes no later group, records nothing",
    .timeLimit(.minutes(1)))
  func generationChangeDuringTheSceneRefreshStopsTheVerb() async throws {
    let (store, transport) = try await loadedSceneStore()
    let groups = keepLeft
    await transport.holdStackRowRequests(true)
    async let verb = store.applyCompoundMark(groups)
    await transport.waitUntilStackRowStarted()
    // The first group (pick 1) has landed; its cover refresh is on the wire.
    #expect(await markWrites(transport) == 1)
    await store.fullReload()
    await transport.holdStackRowRequests(false)
    await transport.releaseStackRow()
    #expect(await verb == .scopeChanged)
    #expect(await markWrites(transport) == 1)
    #expect(store.undo.entry == nil)
  }

  @Test(
    "B1: a generation change during the FINAL refresh answers .scopeChanged and records nothing",
    .timeLimit(.minutes(1)))
  func generationChangeDuringTheFinalRefreshRecordsNothing() async throws {
    let (store, transport) = try await loadedSceneStore()
    let groups = CompareVerb.both.markGroups(left: 1, right: 2)
    await transport.holdStackRowRequests(true)
    async let verb = store.applyCompoundMark(groups)
    await transport.waitUntilStackRowStarted()
    await store.fullReload()
    await transport.holdStackRowRequests(false)
    await transport.releaseStackRow()
    #expect(await verb == .scopeChanged)
    #expect(await markWrites(transport) == 1)
    #expect(store.undo.entry == nil)
  }

  @Test(
    "B2: an undo whose scope moves during a scene refresh writes nothing more",
    .timeLimit(.minutes(1)))
  func undoGenerationChangeDuringTheSceneRefresh() async throws {
    let (store, transport) = try await loadedSceneStore()
    #expect(await store.applyCompoundMark(keepLeft) == .committed)
    #expect(await markWrites(transport) == 2)
    await transport.holdStackRowRequests(true)
    async let undo = store.undoLastMark()
    await transport.waitUntilStackRowStarted()
    // Undo's first group (dislike 1) has landed; its cover refresh is on the wire.
    #expect(await markWrites(transport) == 3)
    await store.fullReload()
    await transport.holdStackRowRequests(false)
    await transport.releaseStackRow()
    #expect(await undo == .scopeChanged)
    #expect(await markWrites(transport) == 3)
    // The pre-fold code rebuilt the slot to the remainder [2] for a scope already left.
    let slotIDs = store.undo.entry?.priorStates.map { $0.imageID }
    #expect(slotIDs != [2])
  }

  @Test("A1: a verb in flight from a closed session never advances a reopened, equal one")
  func reopenedCompareIsNotAdvancedByAnOldVerb() async throws {
    let (store, transport) = await loadedStore()
    store.openLoupe(on: 1)
    store.openCompare()
    await transport.holdMarkStateRequests(true)
    async let verb = store.compareDecide(.keepLeft)
    await transport.waitUntilMarkStateStarted()
    store.closeCompare()
    store.openCompare()
    let reopened = try #require(store.compareSession)
    #expect(reopened.left == 1)
    #expect(reopened.right == 2)
    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    #expect(await verb == .committed)
    #expect(store.compareSession?.right == 2)
    #expect(store.compareSession?.token == reopened.token)
    #expect(store.compareSession?.pendingUndo == nil)
  }

  // MARK: - Compare on the store

  @Test("Compare: a committed Keep left advances the panes; Undo restores the pair and marks")
  func compareDecideAndUndo() async throws {
    let (store, _) = await loadedStore()
    store.openLoupe(on: 1)
    #expect(store.canOpenCompare)
    store.openCompare()
    let opened = try #require(store.compareSession)
    #expect(opened.left == 1)
    #expect(opened.right == 2)

    #expect(await store.compareDecide(.keepLeft) == .committed)
    #expect(store.compareSession?.right == 3)
    #expect(store.focusedImageID == 1)

    #expect(await store.compareUndo() == .restoredAll)
    #expect(store.compareSession?.panes == opened.panes)
    #expect(state(store, 1) == .dislike)
    #expect(state(store, 2) == .pick)

    store.closeCompare()
    #expect(!store.isCompareOpen)
    #expect(store.isLoupeOpen)
    #expect(store.focusedImageID == 1)
  }

  @Test("IMGMGR-482: Compare Undo of another entry's mark reports it and leaves the panes")
  func compareUndoOfAnotherEntryLeavesThePanes() async throws {
    let (store, _) = await loadedStore()
    store.openLoupe(on: 1)
    store.openCompare()
    #expect(await store.compareDecide(.keepLeft) == .committed)
    let advanced = try #require(store.compareSession?.panes)
    #expect(advanced.right == 3)
    // A mark outside Compare's verbs takes the store's one slot.
    #expect(await store.applyMark(.pick, to: [3]))
    // Undo restores THAT entry — every group, so `.restoredAll` — but it is not the entry the
    // Keep left snapshot pairs with. The pre-fix history popped the (1, 2) pair here, showing a
    // pair whose marks the Undo never touched.
    #expect(await store.compareUndo() == .restoredAll)
    #expect(state(store, 3) == MarkPayload.none)
    #expect(store.compareSession?.panes == advanced)
    #expect(store.compareSession?.pendingUndo == nil)
  }

  @Test("Any generation change while Compare is open ends it; the loupe stays")
  func generationChangeEndsCompare() async {
    let (store, _) = await loadedStore()
    store.openLoupe(on: 1)
    store.openCompare()
    #expect(store.isCompareOpen)
    _ = await store.authoritativeRefresh()
    #expect(!store.isCompareOpen)
    #expect(store.compareSession == nil)
  }

  @Test("Closing the loupe ends Compare, and a reopened loupe does not inherit it")
  func closingTheLoupeEndsCompare() async {
    let (store, _) = await loadedStore()
    store.openLoupe(on: 1)
    store.openCompare()
    store.closeLoupe()
    #expect(!store.isCompareOpen)
    store.openLoupe(on: 1)
    #expect(!store.isCompareOpen)
  }
}
