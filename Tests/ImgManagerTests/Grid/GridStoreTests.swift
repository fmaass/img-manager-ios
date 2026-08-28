import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

@MainActor
@Suite(
  "GridStore — cross-cutting invariants (precondition, 409 rollback, undo truth, Pick Lock ⟷ Select)"
)
struct GridStoreTests {

  private func makeImage(
    id: Int, mark: Components.Schemas.MarkView.StatePayload = .none, revision: String = "r0",
    tags: [String] = []
  ) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: revision, state: mark, tags: tags),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStore() -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let service = GridService(client: client)
    return (GridStore(service: service), transport)
  }

  // MARK: - Precondition + 409 rollback + undo truth

  @Test("Every mutation attaches a precondition built from the CURRENTLY loaded revision")
  func mutationAttachesPrecondition() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await store.applyMark(.pick, to: [1])

    let sent = await transport.lastMarkStateRequest
    #expect(sent?.imageIds == [1])
    #expect(sent?.preconditions?.count == 1)
    #expect(sent?.preconditions?.first?.imageId == 1)
    #expect(sent?.preconditions?.first?.revision == "r0")
    #expect(sent?.state == .pick)
  }

  @Test(
    "Success: optimistic state sticks, revision reconciles, undo records the TRUTHFUL prior state")
  func successReconcilesAndRecordsTruthfulUndo() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .dislike, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await store.applyMark(.pick, to: [1])

    #expect(store.images.first?.mark.state == .pick)
    #expect(store.images.first?.mark.revision == "r1")
    #expect(store.lastMutationError == nil)
    #expect(store.undo.canUndo)
    // Truthful, not the naive "opposite of pick": the image was really `.dislike` before.
    #expect(store.undo.entry?.priorStates.first?.state == .dislike)
    #expect(store.undo.entry?.appliedState == .pick)
  }

  @Test(
    "409: nothing was applied server-side, so the WHOLE optimistic batch rolls back and the error surfaces (2 images)"
  )
  func conflictRollsBackOptimisticState() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(
        items: [
          makeImage(id: 1, mark: .none, revision: "r0"),
          makeImage(id: 2, mark: .none, revision: "r0"),
        ], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(.conflict)
    await store.applyMark(.pick, to: [1, 2])

    // Type-qualified `.none` — bare `.none` here would match `Optional.none` (nil), not
    // `.some(StatePayload.none)`, since `StatePayload` itself has a case literally named
    // `none`.
    let none = Components.Schemas.MarkView.StatePayload.none
    #expect(store.images[0].mark.state == none)
    #expect(store.images[1].mark.state == none)
    #expect(store.images[0].mark.revision == "r0")  // untouched — nothing was applied
    #expect(store.images[1].mark.revision == "r0")
    #expect(store.lastMutationError == .conflict)
    #expect(!store.undo.canUndo)  // a refused mutation never enters the undo slot
  }

  @Test(
    "Undo is a mutation like any other: it re-derives its precondition from the CURRENT revision, not the stale original"
  )
  func undoUsesCurrentRevisionForItsOwnPrecondition() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .dislike, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await store.applyMark(.pick, to: [1])
    #expect(store.images.first?.mark.state == .pick)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r2")])))
    await store.undoLastMark()

    #expect(store.images.first?.mark.state == .dislike)
    #expect(store.images.first?.mark.revision == "r2")
    let sent = await transport.lastMarkStateRequest
    #expect(sent?.state == .dislike)
    #expect(sent?.preconditions?.first?.revision == "r1")
    #expect(!store.undo.canUndo)
  }

  @Test("One slot: undo consumed once does nothing on a second call with no new mutation")
  func undoIsOneSlot() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await store.applyMark(.pick, to: [1])
    await store.undoLastMark()
    let countAfterFirstUndo = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
    await store.undoLastMark()
    let countAfterSecondUndo = await transport.callCount(
      Operations.SetMarkStateApiMarksStatePost.id)
    #expect(countAfterFirstUndo == countAfterSecondUndo)
  }

  @Test(
    "Mixed-state batch undo: one group commits, the other 409s -- the slot is NOT consumed, only the failed remainder survives for retry"
  )
  func mixedStateUndoPartialFailureRestoresSlotForRetry() async {
    let (store, transport) = makeStore()
    // Image 1 was `.dislike` before, image 2 was `.none` before -- both get Picked together,
    // so undo must restore two DIFFERENT target states in two separate groups.
    await transport.setListImagesPage(
      .init(
        items: [
          makeImage(id: 1, mark: .dislike, revision: "r0"),
          makeImage(id: 2, mark: .none, revision: "r0"),
        ], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(
      .success(
        .init(
          applied: 2, requested: 2,
          revisions: [.init(imageId: 1, revision: "r1"), .init(imageId: 2, revision: "r1")])))
    await store.applyMark(.pick, to: [1, 2])
    #expect(store.images[0].mark.state == .pick)
    #expect(store.images[1].mark.state == .pick)
    #expect(store.undo.canUndo)

    // Groups are processed in deterministic (alphabetical target-state) order: "dislike"
    // before "none". Let the "dislike" restore (image 1) SUCCEED, and the "none" restore
    // (image 2) 409.
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r2")])),
      forState: .dislike)
    await transport.setMarkStateOutcome(.conflict, forState: .none)

    await store.undoLastMark()

    // Image 1's group committed: restored to its truthful prior state, revision reconciled.
    #expect(store.images[0].mark.state == .dislike)
    #expect(store.images[0].mark.revision == "r2")
    // Image 2's group 409'd: its OWN optimistic apply for THIS undo attempt rolled back to
    // what the original mutation left it at (`.pick`) -- not silently left inconsistent.
    #expect(store.images[1].mark.state == .pick)
    #expect(store.images[1].mark.revision == "r1")
    #expect(store.lastMutationError == .conflict)

    // The slot was NOT fully consumed -- exactly the failed remainder (image 2) survived for
    // a retry, and image 1 (already committed) is NOT re-offered.
    #expect(store.undo.canUndo)
    #expect(store.undo.entry?.imageIDs == [2])
    #expect(store.undo.entry?.priorStates.first?.state == MarkStateValue.none)

    // Retry: fix the stub and undo again -- only image 2's group is attempted this time.
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 2, revision: "r2")])),
      forState: .none)
    let callsBeforeRetry = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
    await store.undoLastMark()
    let callsAfterRetry = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
    #expect(callsAfterRetry == callsBeforeRetry + 1)  // exactly one more call -- image 1 not redone
    #expect(store.images[1].mark.state == Components.Schemas.MarkView.StatePayload.none)
    #expect(!store.undo.canUndo)
  }

  // MARK: - Pointer drag (diff-gate round 2, blocker 3)

  @Test("pointerDragCrossed dedups within one drag session -- a re-crossed tile is not re-applied")
  func pointerDragCrossedDedupsWithinOneSession() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    let t0 = ContinuousClock.now
    _ = store.pickLock.activateFromPickButton(at: t0)
    _ = store.pickLock.activateFromPickButton(at: t0.advanced(by: .milliseconds(100)))
    #expect(store.pickLock.state == .latched)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    store.beginPointerDrag()
    await store.pointerDragCrossed(1)
    await store.pointerDragCrossed(1)  // re-entry: must NOT apply a second time
    let callCount = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
    #expect(callCount == 1)
  }

  @Test(
    "beginPointerDrag() starts a FRESH session -- a tile crossed in a prior drag can be crossed again"
  )
  func beginPointerDragResetsSession() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    let t0 = ContinuousClock.now
    _ = store.pickLock.activateFromPickButton(at: t0)
    _ = store.pickLock.activateFromPickButton(at: t0.advanced(by: .milliseconds(100)))

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    store.beginPointerDrag()
    await store.pointerDragCrossed(1)
    store.beginPointerDrag()  // a new drag gesture
    await store.pointerDragCrossed(1)
    let callCount = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
    #expect(callCount == 2)
  }

  @Test("pointerDragCrossed in Select mode adds to the selection, not a mark")
  func pointerDragCrossedInSelectModeAddsToSelection() async {
    let (store, _) = makeStore()
    store.selection.enterSelectExplicitly()
    store.beginPointerDrag()
    await store.pointerDragCrossed(7)
    #expect(store.selection.members == [7])
  }

  // MARK: - "Lock Pick" discoverable menu command (gate's unasked issue)

  @Test("lockPickFromMenu() latches immediately -- no timing window, unlike the double-tap path")
  func lockPickFromMenuLatchesImmediately() {
    let (store, _) = makeStore()
    #expect(store.pickLock.state == .idle)
    store.lockPickFromMenu()
    #expect(store.pickLock.state == .latched)
  }

  @Test("lockPickFromMenu() is a no-op while Select is active")
  func lockPickFromMenuNoopDuringSelect() {
    let (store, _) = makeStore()
    store.selection.enterSelectExplicitly()
    store.lockPickFromMenu()
    #expect(store.pickLock.state == .idle)
  }

  // MARK: - Pick Lock ⟷ Select mutual exclusion (premise.out pin e)

  @Test(
    "Long-press while latched: unlatches first, then enters Select — no Pick applied during the transition"
  )
  func longPressWhileLatchedUnlatchesThenSelects() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 999, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    let t0 = ContinuousClock.now
    _ = store.pickLock.activateFromPickButton(at: t0)
    _ = store.pickLock.activateFromPickButton(at: t0.advanced(by: .milliseconds(100)))
    #expect(store.pickLock.state == .latched)

    store.longPressTile(999)

    #expect(store.pickLock.state == .idle)
    #expect(store.selection.mode == .select)
    #expect(store.selection.members == [999])
    // No mark was applied as a side effect of the transition itself.
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == 0)
  }

  @Test("Lock entry is disabled while Select is active")
  func lockEntryDisabledDuringSelect() async {
    let (store, _) = makeStore()
    store.selection.enterSelectExplicitly()
    await store.activatePickButton()
    #expect(store.pickLock.state == .idle)
  }

  @Test("Dislike never touches Pick Lock state — v1 is Pick-only")
  func dislikeNeverTouchesPickLock() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 1
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await store.handleDislikeShortcut(shiftHeld: false)
    #expect(store.pickLock.state == .idle)
  }

  // MARK: - Shortcut activation (arrows / P / X / Shift+advance / T / Z)

  @Test("P applies Pick to the focused image; Shift+P also advances focus")
  func pickShortcutWithShiftAdvances() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(
        items: [makeImage(id: 1, revision: "r0"), makeImage(id: 2, revision: "r0")], limit: 100,
        nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 1
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))

    await store.handlePickShortcut(shiftHeld: true)

    #expect(store.images.first { $0.id == 1 }?.mark.state == .pick)
    #expect(store.focusedImageID == 2)
  }

  @Test("X applies Dislike to the focused image, without Shift focus stays put")
  func dislikeShortcutWithoutShiftStays() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(
        items: [makeImage(id: 1, revision: "r0"), makeImage(id: 2, revision: "r0")], limit: 100,
        nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 1
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))

    await store.handleDislikeShortcut(shiftHeld: false)

    #expect(store.images.first { $0.id == 1 }?.mark.state == .dislike)
    #expect(store.focusedImageID == 1)
  }

  @Test("Z (undo) with nothing to undo is a safe no-op")
  func undoShortcutNoopWhenEmpty() async {
    let (store, _) = makeStore()
    await store.handleUndoShortcut()
    #expect(!store.undo.canUndo)
  }

  @Test("Arrow navigation moves through packed rows: right/left/down/up")
  func arrowNavigationUsesPackedRows() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: (1...5).map { makeImage(id: $0, revision: "r0") }, limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.rows = [[1, 2, 3], [4, 5]]
    store.focusedImageID = 1
    store.moveFocus(.right)
    #expect(store.focusedImageID == 2)
    store.moveFocus(.down)
    #expect(store.focusedImageID == 5)
    store.moveFocus(.up)
    #expect(store.focusedImageID == 2)
    store.moveFocus(.left)
    #expect(store.focusedImageID == 1)
  }

  // MARK: - Selection reset on query-generation change (filter)

  @Test("applyFilterChange that actually changes the query resets selection and reloads")
  func filterChangeResetsSelection() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.selection.enterSelectExplicitly()
    store.selection.toggle(1)
    #expect(!store.selection.members.isEmpty)

    await store.applyFilterChange { $0.mark = "pick" }

    #expect(store.selection.mode == .browse)
    #expect(store.selection.members.isEmpty)
  }

  @Test("A no-op filter change (same value) does NOT reset selection")
  func noopFilterChangeDoesNotReset() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.selection.enterSelectExplicitly()
    store.selection.toggle(1)

    await store.applyFilterChange { _ in }  // no actual mutation

    #expect(store.selection.mode == .select)
    #expect(store.selection.members == [1])
  }

  // MARK: - Cursor-fingerprint disposition (P2-checkpoint residual)

  @Test(
    "A 400 (undocumented) on paging discards the cursor and restarts the same scope from page one")
  func cursorMismatchRestartsFromPageOne() async {
    let (store, transport) = makeStore()
    let firstImage = makeImage(id: 1, revision: "r0")
    await transport.setListImagesPage(
      .init(items: [firstImage], limit: 100, nextCursor: "stale-cursor"))
    await store.selectShoot(folderID: 1)
    #expect(store.nextCursor == "stale-cursor")

    // A page-2 request (cursor="stale-cursor") gets refused; a page-1 restart (cursor==nil)
    // still succeeds against the SAME configured `listImagesPage` — proving the restart lands
    // on real data, not just that the 400 was swallowed.
    await transport.setListImagesRejectNonNilCursor(true)
    await store.loadMoreIfNeeded(currentItemID: 1)

    let callCount = await transport.callCount(Operations.ListImagesApiImagesGet.id)
    // 1 initial selectShoot fetch (cursor=nil, succeeds) + 1 paginated attempt (cursor=
    // "stale-cursor", refused 400) + 1 restart (cursor=nil, succeeds again).
    #expect(callCount == 3)
    #expect(store.lastPageLoadError == nil)
    #expect(store.images.map(\.id) == [1])  // restarted with the real page-one data, not empty
  }
}
