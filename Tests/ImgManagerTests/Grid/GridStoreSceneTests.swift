import CoreGraphics
import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP12's cross-cutting invariants: the actionability boundary, Scene enter/leave scope
/// semantics, expansion and its paging, and the cover refresh that follows a write.
///
/// Every test here drives a REAL loaded Scene page through `GridStubTransport` — the boundary
/// assertions in particular would be worthless against an empty store, where a mark is skipped
/// because the id was never loaded rather than because the card refused it. `positiveControl`
/// tests exist beside them for exactly that reason: the same page, the same transport counter,
/// and a member that DOES write.
@MainActor
@Suite("GridStore — Scene mode (rows, boundary, expansion, cover refresh)")
struct GridStoreSceneTests {

  // MARK: - Fixtures

  private func makeImage(
    id: Int, mark: Components.Schemas.MarkView.StatePayload = .none, revision: String = "r0",
    missing: Bool = false, captured: Date? = nil
  ) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, capturedAt: captured, ext: "raf", filename: "DSCF\(id).raf", folderId: 1,
      hasEdit: false, id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(revision: revision, state: mark, tags: []), missing: missing,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStackRow(
    id: Int, memberCount: Int = 3, hasPick: Bool = false, matchedCount: Int = 3,
    anchor: Date? = nil, representative: Components.Schemas.ImageSummary
  ) -> Components.Schemas.StackBrowseStackRow {
    Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: anchor, hasPick: hasPick, kind: .stack, matchedCount: matchedCount,
      memberCount: memberCount, representative: representative, stackId: id)
  }

  private func page(
    _ rows: [Components.Schemas.StackBrowsePage.ItemsPayloadPayload], nextCursor: String? = nil
  ) -> Components.Schemas.StackBrowsePage {
    Components.Schemas.StackBrowsePage(items: rows, limit: 100, nextCursor: nextCursor)
  }

  private func imageRow(_ image: Components.Schemas.ImageSummary)
    -> Components.Schemas.StackBrowsePage.ItemsPayloadPayload
  {
    .init(value1: .init(image: image, kind: .image), value2: nil)
  }

  private func stackRowItem(_ row: Components.Schemas.StackBrowseStackRow)
    -> Components.Schemas.StackBrowsePage.ItemsPayloadPayload
  {
    .init(value1: nil, value2: row)
  }

  private func makeStore() -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    return (GridStore(service: GridService(client: client)), transport)
  }

  /// The standard fixture: a flat shoot loaded first (so leaving Scene mode has something to come
  /// back to), then one Scene page holding a loose photograph and one collapsed scene whose cover
  /// is a photograph the reader must NOT be able to write to.
  ///
  /// Cover id 900 appears NOWHERE else, so any write naming 900 can only have come from the card.
  private func loadedSceneStore() async -> (GridStore, GridStubTransport) {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: "flat-cursor"))
    await store.selectShoot(folderID: 1)

    let cover = makeImage(id: 900, mark: .pick, revision: "cover-rev")
    await transport.setBrowseStacksPage(
      page(
        [
          imageRow(makeImage(id: 10)),
          stackRowItem(
            makeStackRow(
              id: 5, memberCount: 3, hasPick: true, matchedCount: 2,
              anchor: Date(timeIntervalSince1970: 1_700_000_000), representative: cover)),
        ], nextCursor: "scene-cursor"))
    await store.setDisplayMode(.scene)
    return (store, transport)
  }

  // MARK: - Row kinds and the empty `images` array

  @Test("Entering Scene mode serves kind-discriminated rows and leaves `images` empty")
  func sceneRowsAreKindDiscriminated() async {
    let (store, _) = await loadedSceneStore()

    #expect(store.displayMode == .scene)
    #expect(store.sceneRows.count == 2)
    #expect(store.sceneNextCursor == "scene-cursor")
    // `images` stays empty by construction — the array every flat path reads must not be able to
    // hold a collapsed card's cover.
    #expect(store.images.isEmpty)
    #expect(store.nextCursor == nil)

    let rows = store.sceneDisplayRows
    #expect(rows.map(\.id) == [.image(10), .stack(5)])
    guard case .stack(let row, let isExpanded) = rows[1] else {
      Issue.record("row 1 is not a stack row")
      return
    }
    #expect(!isExpanded)
    #expect(row.memberCount == 3)
    #expect(row.matchedCount == 2)
    #expect(row.anchorTakenAt == Date(timeIntervalSince1970: 1_700_000_000))
  }

  // MARK: - The actionability boundary (gate correction 1 + 2 + 4)

  @Test("A collapsed card contributes NOTHING to the actionable projection — its cover included")
  func collapsedCardIsNotActionable() async {
    let (store, _) = await loadedSceneStore()
    #expect(store.actionableImages.map(\.id) == [10])
    #expect(!store.actionableImages.contains { $0.id == 900 })
  }

  @Test(
    "No gesture on a collapsed card produces a mark or a selection entry — tap, long press, Pick-Lock drag, Select drag"
  )
  func noGestureOnACardEverWrites() async {
    let (store, transport) = await loadedSceneStore()
    let markOp = Operations.SetMarkStateApiMarksStatePost.id
    await transport.setStackMemberPage(
      .init(items: [makeImage(id: 501)], limit: 100, nextCursor: nil, stackId: 5), forStack: 5)

    // 1. A tap while Pick Lock is LATCHED. On a photograph this is a pick; on a card it must not
    //    be, and the card's only meaning — open me — is what happens instead.
    store.pickLock.forceLatch()
    await store.tapCell(.stack(5))
    #expect(await transport.callCount(markOp) == 0)
    #expect(store.sceneExpanded.contains(5))  // it did the ONE thing a card can do
    await store.tapCell(.stack(5))  // and closes again
    #expect(!store.sceneExpanded.contains(5))

    // 2. A Pick-Lock pointer drag that crosses the card's frame.
    store.beginPointerDrag()
    await store.pointerDragCrossed(.stack(5))
    #expect(await transport.callCount(markOp) == 0)

    // 3. A long press. It must not enter Select, and must not select the card.
    store.longPressCell(.stack(5))
    #expect(store.selection.mode == .browse)
    #expect(store.selection.members.isEmpty)

    // 4. A Select-mode drag across the card.
    store.enterSelectExplicitly()
    store.beginPointerDrag()
    await store.pointerDragCrossed(.stack(5))
    #expect(store.selection.members.isEmpty)

    // Nothing anywhere in this test reached the mark endpoint, and no request was ever built.
    #expect(await transport.callCount(markOp) == 0)
    #expect(await transport.lastMarkStateRequest == nil)
  }

  @Test(
    "POSITIVE CONTROL: the same loaded page, the same counter — a LOOSE photograph does write, so the zeroes above mean refusal, not an unloaded id"
  )
  func positiveControlALoosePhotographDoesWrite() async {
    let (store, transport) = await loadedSceneStore()
    let markOp = Operations.SetMarkStateApiMarksStatePost.id
    #expect(await transport.callCount(markOp) == 0)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 10, revision: "r1")])))
    store.pickLock.forceLatch()
    store.beginPointerDrag()
    await store.pointerDragCrossed(.image(10))

    #expect(await transport.callCount(markOp) == 1)
    #expect(await transport.lastMarkStateRequest?.imageIds == [10])
  }

  @Test("Even with a card's cover id passed directly, the write finds no state to build a precondition from")
  func aCoverIdCannotBeMarkedEvenIfNamed() async {
    let (store, transport) = await loadedSceneStore()
    await store.applyMark(.pick, to: [900])
    // Not "the request was refused server-side": no request was ever built, because the cover is
    // not in the actionable projection the preconditions are captured from.
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == 0)
  }

  // MARK: - Scene enter / leave scope semantics (gate correction 6)

  @Test("Entering Scene mode is a full scope reset: flat cursor discarded, selection, Pick Lock, undo and focus cleared")
  func enteringSceneModeIsAFullReset() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1), makeImage(id: 2)], limit: 100, nextCursor: "flat-cursor"))
    await store.selectShoot(folderID: 1)
    #expect(store.nextCursor == "flat-cursor")

    // Build up exactly the state a filter change would deliberately PRESERVE, so this test can
    // only pass if Scene entry takes `selectShoot`'s stronger reset instead.
    store.enterSelectExplicitly()
    store.selection.toggle(1)
    store.focusedImageID = 2
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await store.applyMark(.pick, to: [1])
    #expect(store.undo.canUndo)
    store.pickLock.forceLatch()

    await transport.setBrowseStacksPage(page([imageRow(makeImage(id: 10))]))
    await store.setDisplayMode(.scene)

    #expect(store.nextCursor == nil)  // the flat cursor is gone, not carried into a foreign scope
    #expect(store.images.isEmpty)
    #expect(store.selection.members.isEmpty)
    #expect(store.selection.mode == .browse)
    #expect(store.pickLock.state != .latched)
    #expect(!store.undo.canUndo)
    #expect(store.focusedImageID == nil)
  }

  @Test("Leaving Scene mode restores flat paging from page one and drops the whole scene window")
  func leavingSceneModeRestoresFlatPagingFromPageOne() async {
    let (store, transport) = await loadedSceneStore()
    await transport.setStackMemberPage(
      .init(items: [makeImage(id: 501)], limit: 100, nextCursor: nil, stackId: 5), forStack: 5)
    await store.toggleSceneExpanded(5)
    #expect(!store.sceneMembers.isEmpty)

    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1), makeImage(id: 2)], limit: 100, nextCursor: "flat-again"))
    await store.setDisplayMode(.flat)

    #expect(store.displayMode == .flat)
    #expect(store.images.map(\.id) == [1, 2])
    #expect(store.nextCursor == "flat-again")  // page ONE's cursor, not a resumed scene cursor
    #expect(store.sceneRows.isEmpty)
    #expect(store.sceneExpanded.isEmpty)
    #expect(store.sceneMembers.isEmpty)
    #expect(store.sceneNextCursor == nil)
    #expect(store.actionableImages.map(\.id) == [1, 2])
  }

  // MARK: - Expansion, paging, single-flight, tombstones

  @Test("Expanding splices the members after their card in capture order, tombstones included")
  func expandingSplicesMembersInCaptureOrder() async {
    let (store, transport) = await loadedSceneStore()
    await transport.setStackMemberPage(
      .init(
        items: [
          makeImage(id: 501, captured: Date(timeIntervalSince1970: 1_700_000_000)),
          makeImage(id: 502, missing: true, captured: Date(timeIntervalSince1970: 1_700_000_060)),
          makeImage(id: 503, captured: Date(timeIntervalSince1970: 1_700_000_120)),
        ], limit: 100, nextCursor: nil, stackId: 5),
      forStack: 5)

    await store.toggleSceneExpanded(5)

    #expect(
      store.sceneDisplayRows.map(\.id)
        == [.image(10), .stack(5), .image(501), .image(502), .image(503)])
    // Members of an EXPANDED scene are ordinary photographs again — including the tombstone,
    // which is part of the authoritative membership and must be visible rather than dropped.
    #expect(store.actionableImages.map(\.id) == [10, 501, 502, 503])
    #expect(store.actionableImages.first { $0.id == 502 }?.missing == true)
    #expect(store.sceneMemberCursors[5] == .exhausted)
  }

  @Test("A tombstoned member renders as a missing tile whatever the proxy plan says")
  func tombstonedMemberRendersAsMissing() async {
    let tombstone = makeImage(id: 502, missing: true)
    let alive = makeImage(id: 503)
    // A fully-available proxy plan — the case where a cached rendition WOULD otherwise draw a
    // photograph that no longer exists.
    let servable = TileRenderPlan.display(tier: .grid, size: CGSize(width: 200, height: 200))

    #expect(TilePresentation.resolve(missing: tombstone.missing, plan: servable) == .tombstone)
    #expect(
      TilePresentation.resolve(missing: alive.missing, plan: servable)
        == .display(tier: .grid, size: CGSize(width: 200, height: 200)))
    // And the two "missing" ideas stay distinct: no proxy YET is a preparation state, not a
    // tombstone.
    #expect(
      TilePresentation.resolve(missing: alive.missing, plan: .placeholder(reason: .missing))
        == .placeholder(reason: .missing))
  }

  @Test("Membership pages further, appending in place; the card never moves")
  func membershipPagesFurther() async {
    let (store, transport) = await loadedSceneStore()
    await transport.setStackMemberPage(
      .init(items: [makeImage(id: 501)], limit: 100, nextCursor: "members-2", stackId: 5),
      forStack: 5)
    await transport.setStackMemberPage(
      .init(items: [makeImage(id: 502)], limit: 100, nextCursor: nil, stackId: 5),
      forCursor: "members-2")

    await store.toggleSceneExpanded(5)
    #expect(store.sceneMemberCursors[5] == .more("members-2"))

    await store.loadMoreSceneMembersIfNeeded(afterMemberID: 501)

    #expect(store.sceneDisplayRows.map(\.id) == [.image(10), .stack(5), .image(501), .image(502)])
    #expect(store.sceneMemberCursors[5] == .exhausted)
    // The scene row itself is untouched: still one card, still in the same position.
    #expect(store.sceneRows.count == 2)
  }

  @Test("Membership loading is single-flight per scene: a second expand while one is in flight adds no second call")
  func membershipIsSingleFlight() async {
    let (store, transport) = await loadedSceneStore()
    await transport.setStackMemberPage(
      .init(items: [makeImage(id: 501)], limit: 100, nextCursor: nil, stackId: 5), forStack: 5)
    await transport.holdStackMembersRequests(true)

    let first = Task { await store.toggleSceneExpanded(5) }
    await transport.waitUntilStackMembersStarted()

    // A second open of the SAME scene while the first page is genuinely on the wire.
    await store.toggleSceneExpanded(5)  // closes
    await store.toggleSceneExpanded(5)  // opens again — must not start a second request

    await transport.releaseStackMembers()
    await first.value
    await transport.holdStackMembersRequests(false)

    #expect(
      await transport.callCount(Operations.ListStackMembersApiStacksStackIdMembersGet.id) == 1)
  }

  @Test("Collapsing a scene takes its members out of the selection")
  func collapsingPrunesTheSelection() async {
    let (store, transport) = await loadedSceneStore()
    await transport.setStackMemberPage(
      .init(
        items: [makeImage(id: 501), makeImage(id: 502)], limit: 100, nextCursor: nil, stackId: 5),
      forStack: 5)
    await store.toggleSceneExpanded(5)

    store.enterSelectExplicitly()
    store.selection.toggle(10)  // a loose photograph, elsewhere in the stream
    store.selection.toggle(501)  // a member of the scene about to close
    #expect(store.selection.members == [10, 501])

    await store.toggleSceneExpanded(5)

    // Only the hidden member leaves; a selection made elsewhere is untouched, and Select mode
    // itself is not exited — collapsing a card is not "Done".
    #expect(store.selection.members == [10])
    #expect(store.selection.mode == .select)
  }

  // MARK: - Members are ordinary photographs (gate correction 1), and the cover follows the write

  @Test("A mark on an EXPANDED member finds its state, writes with its own precondition, and lands in place")
  func markingAnExpandedMemberWorks() async {
    let (store, transport) = await loadedSceneStore()
    await transport.setStackMemberPage(
      .init(
        items: [makeImage(id: 501, revision: "m-rev-1"), makeImage(id: 502, revision: "m-rev-2")],
        limit: 100, nextCursor: nil, stackId: 5),
      forStack: 5)
    await store.toggleSceneExpanded(5)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 501, revision: "m-rev-9")])))
    await store.applyMark(.pick, to: [501])

    let sent = await transport.lastMarkStateRequest
    #expect(sent?.imageIds == [501])
    // The precondition came from the MEMBER's own loaded revision — the projection's read half
    // and its write half looking at the same photograph.
    #expect(sent?.preconditions?.first?.revision == "m-rev-1")
    #expect(store.mutationCommitCount == 1)

    let member = store.actionableImages.first { $0.id == 501 }
    #expect(member?.mark.state == .pick)
    #expect(member?.mark.revision == "m-rev-9")  // reconciled in place, inside the member strip
    #expect(store.undo.canUndo)
  }

  @Test("After a write touching a member, the touched scene's row is re-read and merged IN PLACE")
  func coverRefreshMergesOnlyTheFourFields() async {
    let (store, transport) = await loadedSceneStore()
    await transport.setStackMemberPage(
      .init(
        items: [makeImage(id: 501, revision: "m-rev-1")], limit: 100, nextCursor: nil, stackId: 5),
      forStack: 5)
    await store.toggleSceneExpanded(5)

    // The server's answer AFTER the pick: the cover moved to the picked member and the badges
    // changed. The anchor is deliberately different here so a merge that took the whole row
    // (rather than the four fields) would move the card in capture order and fail this test.
    let newCover = makeImage(id: 501, mark: .pick, revision: "m-rev-9")
    await transport.setStackRow(
      makeStackRow(
        id: 5, memberCount: 4, hasPick: true, matchedCount: 4,
        anchor: Date(timeIntervalSince1970: 1), representative: newCover),
      forStack: 5)
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 501, revision: "m-rev-9")])))

    await store.applyMark(.pick, to: [501])

    #expect(await transport.callCount(Operations.GetStackApiStacksStackIdGet.id) == 1)
    guard case .stack(let merged) = store.sceneRows[1] else {
      Issue.record("row 1 is no longer a stack row")
      return
    }
    #expect(merged.representative.id == 501)  // the cover followed the pick
    #expect(merged.memberCount == 4)
    #expect(merged.hasPick)
    #expect(merged.matchedCount == 4)
    // Everything else stayed: the anchor (position in capture order) and the expansion.
    #expect(merged.anchorTakenAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(store.sceneExpanded.contains(5))
    #expect(store.sceneMembers[5]?.map(\.id) == [501])
  }

  @Test("A write touching NO member of any open scene re-reads no card at all")
  func coverRefreshIsScopedToTouchedScenes() async {
    let (store, transport) = await loadedSceneStore()
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 10, revision: "r1")])))

    await store.applyMark(.pick, to: [10])  // the loose photograph, in no scene

    #expect(store.mutationCommitCount == 1)
    #expect(await transport.callCount(Operations.GetStackApiStacksStackIdGet.id) == 0)
  }

  // MARK: - Scene paging

  @Test("Scene paging consumes the SCENE cursor and dedups a repeated row across the boundary")
  func scenePagingUsesItsOwnCursor() async {
    let (store, transport) = await loadedSceneStore()
    await transport.setBrowseStacksPage(
      page([imageRow(makeImage(id: 10)), imageRow(makeImage(id: 11))], nextCursor: nil),
      forCursor: "scene-cursor")

    await store.loadMoreScenesIfNeeded(currentRowID: .stack(5))

    // id 10 was already served on page one and must not appear twice.
    #expect(store.sceneRows.map(\.displayID) == [.image(10), .stack(5), .image(11)])
    #expect(store.sceneNextCursor == nil)
  }

  @Test("A refused scene cursor restarts THIS scope from page one rather than dead-ending")
  func refusedSceneCursorRestartsFromPageOne() async {
    let (store, transport) = await loadedSceneStore()
    await transport.setBrowseStacksRejectNonNilCursor(true)

    await store.loadMoreScenesIfNeeded(currentRowID: .stack(5))

    // Page one is served again (the reject flag only refuses a NON-nil cursor), so the window is
    // rebuilt rather than left with a paging error the reader can do nothing about.
    #expect(store.sceneRows.count == 2)
    #expect(store.lastPageLoadError == nil)
  }
}

/// The two pure derivations Scene mode's safety argument rests on, tested without a store, a view
/// or a network — the same reason the web keeps them in their own module.
@Suite("SceneRowBuilder — display sequence and the actionable projection")
struct SceneRowBuilderTests {

  private func image(_ id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      ext: "raf", filename: "DSCF\(id).raf", folderId: 1, id: id,
      lightroom: .init(sidecarPresent: false), mark: .init(revision: "r0"),
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func stack(_ id: Int, cover: Int) -> Components.Schemas.StackBrowseStackRow {
    .init(
      hasPick: false, kind: .stack, matchedCount: 2, memberCount: 2, representative: image(cover),
      stackId: id)
  }

  @Test("A COLLAPSED scene renders as the card alone and contributes nothing actionable")
  func collapsedSceneContributesNothing() {
    let rows = SceneRowBuilder.displayRows(
      rows: [.image(image(1)), .stack(stack(5, cover: 900))], expanded: [], members: [:])
    #expect(rows.map(\.id) == [.image(1), .stack(5)])
    #expect(SceneRowBuilder.actionableImages(rows).map(\.id) == [1])
  }

  @Test("An EXPANDED scene is followed by its loaded members, which ARE actionable")
  func expandedSceneContributesItsMembers() {
    let rows = SceneRowBuilder.displayRows(
      rows: [.stack(stack(5, cover: 900)), .image(image(1))],
      expanded: [5], members: [5: [image(501), image(502)]])
    #expect(rows.map(\.id) == [.stack(5), .image(501), .image(502), .image(1)])
    #expect(SceneRowBuilder.actionableImages(rows).map(\.id) == [501, 502, 1])
    #expect(!SceneRowBuilder.actionableImages(rows).contains { $0.id == 900 })
  }

  @Test("An expanded scene whose members have not arrived yet renders as the card alone")
  func expandedButUnloadedSceneRendersTheCardAlone() {
    let rows = SceneRowBuilder.displayRows(
      rows: [.stack(stack(5, cover: 900))], expanded: [5], members: [:])
    #expect(rows.map(\.id) == [.stack(5)])
    #expect(SceneRowBuilder.actionableImages(rows).isEmpty)
  }

  @Test("A photograph and a scene that share a number are different display identities")
  func imageAndStackIdsNeverCollide() {
    let rows = SceneRowBuilder.displayRows(
      rows: [.image(image(7)), .stack(stack(7, cover: 900))], expanded: [], members: [:])
    #expect(rows.map(\.id) == [.image(7), .stack(7)])
    #expect(GridDisplayID.image(7) != GridDisplayID.stack(7))
    #expect(GridDisplayID.stack(7).imageID == nil)
  }
}
