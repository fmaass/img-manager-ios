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

  @Test(
    "Undo remainder truth (diff-gate round 3, blocker 1): within ONE group, an id unloaded at undo time is never silently dropped -- only the id actually submitted leaves the slot"
  )
  func undoLeavesUnloadedGroupMemberInRemainder() async {
    let (store, transport) = makeStore()
    // Both images were `.dislike` before -- same undo group ("dislike"), so this exercises a
    // MIXED-LOADED group, not a mixed-STATE one (that's the sibling test above).
    await transport.setListImagesPage(
      .init(
        items: [
          makeImage(id: 1, mark: .dislike, revision: "r0"),
          makeImage(id: 2, mark: .dislike, revision: "r0"),
        ], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(
      .success(
        .init(
          applied: 2, requested: 2,
          revisions: [.init(imageId: 1, revision: "r1"), .init(imageId: 2, revision: "r1")])))
    await store.applyMark(.pick, to: [1, 2])
    #expect(store.undo.entry?.imageIDs.sorted() == [1, 2])

    // A foreground/retry full reload (NOT a scope change -- `selectShoot` is the only thing
    // that clears the slot) brings back only image 1; image 2 is unloaded, not restored, not
    // forgotten.
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .pick, revision: "r1")], limit: 100, nextCursor: nil))
    await store.fullReload()
    #expect(store.images.map(\.id) == [1])

    let callsBeforeUndo = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r2")])),
      forState: .dislike)
    await store.undoLastMark()
    let callsAfterUndo = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)

    // Only image 1 (loaded, actually submitted) was written.
    #expect(callsAfterUndo == callsBeforeUndo + 1)
    let sent = await transport.lastMarkStateRequest
    #expect(sent?.imageIds == [1])
    #expect(store.images[0].mark.state == .dislike)
    #expect(store.images[0].mark.revision == "r2")

    // Image 2 was NEVER submitted (nothing loaded to restore it from) -- it stays in the
    // remainder exactly as recorded, not silently declared settled.
    #expect(store.undo.canUndo)
    #expect(store.undo.entry?.imageIDs == [2])
    #expect(store.undo.entry?.priorStates.first?.imageID == 2)
    #expect(store.undo.entry?.priorStates.first?.state == MarkStateValue.dislike)
    // Untouched, original snapshot -- never re-derived from a since-vanished current revision.
    #expect(store.undo.entry?.priorStates.first?.revisionBefore == "r0")
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

  // MARK: - P5: loupe entry (second tap / Space/Enter), selection reset, Pick Lock untouched

  @Test(
    "A second tap on the ALREADY-focused tile opens the loupe; a different tile just moves focus")
  func secondTapOnFocusedTileOpensLoupe() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(
        items: [makeImage(id: 1, revision: "r0"), makeImage(id: 2, revision: "r0")], limit: 100,
        nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await store.tapTile(1)
    #expect(store.focusedImageID == 1)
    #expect(!store.isLoupeOpen)  // first tap only focuses

    await store.tapTile(1)
    #expect(store.isLoupeOpen)  // second tap on the SAME tile opens

    store.closeLoupe()
    await store.tapTile(2)
    #expect(store.focusedImageID == 2)
    #expect(!store.isLoupeOpen)  // a DIFFERENT tile is a fresh focus move, not an "open"
  }

  @Test("A tap in Select mode never opens the loupe, even on the already-selected tile twice")
  func tapTileInSelectModeNeverOpensLoupe() async {
    let (store, _) = makeStore()
    store.selection.enterSelectExplicitly()
    await store.tapTile(1)
    await store.tapTile(1)
    #expect(!store.isLoupeOpen)
    #expect(store.selection.members == [])  // toggled on then off
  }

  @Test(
    "openLoupe(on:) resets selection to browse/empty (the `.enteredLoupe` trigger SelectionState already reserved) but leaves Pick Lock untouched"
  )
  func openLoupeResetsSelectionNotPickLock() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.selection.enterSelectExplicitly()
    store.selection.toggle(1)
    #expect(!store.selection.members.isEmpty)
    // Latched via the discoverable menu path (never reachable through a latched TAP, since
    // that branch returns before ever calling `openLoupe` -- this proves the "untouched" claim
    // by giving Pick Lock real non-default state to preserve, not just leaving it at its
    // already-idle default).
    store.selection.reset(.doneOrEsc)  // Lock entry is disabled while Select is active
    store.lockPickFromMenu()
    #expect(store.pickLock.state == .latched)

    store.openLoupe(on: 1)

    #expect(store.isLoupeOpen)
    #expect(store.focusedImageID == 1)
    #expect(store.selection.mode == .browse)
    #expect(store.selection.members.isEmpty)
    // PickLockState.exit() is "grid-only, never the loupe".
    #expect(store.pickLock.state == .latched)
  }

  @Test("closeLoupe() also resets the full-screen toggle")
  func closeLoupeResetsFullScreenToo() {
    let (store, _) = makeStore()
    store.openLoupe(on: 1)
    store.toggleLoupeFullScreen()
    #expect(store.isLoupeFullScreen)

    store.closeLoupe()

    #expect(!store.isLoupeOpen)
    #expect(!store.isLoupeFullScreen)
  }

  @Test(
    "Space/Enter (handleOpenShortcut) opens the loupe on the focused image; a no-op with nothing focused"
  )
  func handleOpenShortcutOpensLoupeOnFocusedImage() async {
    let (store, transport) = makeStore()
    let (store2, _) = makeStore()
    store2.handleOpenShortcut()
    #expect(!store2.isLoupeOpen)  // nothing focused -- no-op

    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 1
    store.handleOpenShortcut()
    #expect(store.isLoupeOpen)
  }

  // MARK: - P5: U (Clear)

  @Test("U applies Clear (.none) to the focused image; Shift+U also advances")
  func clearShortcutWithShiftAdvances() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(
        items: [makeImage(id: 1, mark: .pick, revision: "r0"), makeImage(id: 2, revision: "r0")],
        limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 1
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))

    await store.handleClearShortcut(shiftHeld: true)

    // Type-qualified `.none` -- a bare `.none` on the right of `==` here would be inferred as
    // `Optional<StatePayload>.none` (nil), not `.some(StatePayload.none)`, since `mark.state`'s
    // type is `StatePayload?` and `StatePayload` itself has a case literally named `none` (the
    // same footgun `MarkStateValue.init(_:)`'s own doc comment names, and the exact form
    // `conflictRollsBackOptimisticState` above already sidesteps this same way).
    let none = Components.Schemas.MarkView.StatePayload.none
    #expect(store.images.first { $0.id == 1 }?.mark.state == none)
    #expect(store.focusedImageID == 2)
  }

  // MARK: - P5: dedicated flat previous/next over the shared paging state

  @Test("loupeNext/loupePrevious walk the local flat order; previous is disabled at index 0")
  func loupeNextPreviousWalkLocalOrder() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: (1...3).map { makeImage(id: $0, revision: "r0") }, limit: 100, nextCursor: nil)
    )
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 1

    #expect(!store.canLoupeGoPrevious)
    #expect(store.canLoupeGoNext)

    await store.loupeNext()
    #expect(store.focusedImageID == 2)
    #expect(store.canLoupeGoPrevious)

    await store.loupeNext()
    #expect(store.focusedImageID == 3)

    store.loupePrevious()
    store.loupePrevious()
    store.loupePrevious()  // one call past index 0 -- must stay put, never underflow
    #expect(store.focusedImageID == 1)
    #expect(!store.canLoupeGoPrevious)

    // Neither call ever touched the network -- purely the retained-prefix local walk.
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 1)
    #expect(
      await transport.callCount(Operations.ImageNeighboursApiImagesImageIdNeighboursGet.id) == 0)
  }

  @Test(
    "loupeNext at the loaded tail fetches the forward-neighbour endpoint and MERGES the result into store.images -- never a filmstrip-local page"
  )
  func loupeNextFetchesAndMergesNeighboursAtTail() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 1
    // Optimistic until PROVEN exhausted (matches `canLoupeGoNext`'s own doc comment: true
    // unless a neighbours fetch already confirmed nothing further) -- at the tail with nothing
    // yet confirmed, the control stays enabled so the tap itself can do the check, rather than
    // disabling before we actually know.
    #expect(store.canLoupeGoNext)

    await transport.setNeighboursPage(
      .init(
        items: [makeImage(id: 2, revision: "r0"), makeImage(id: 3, revision: "r0")], limit: 5,
        nextCursor: nil))

    await store.loupeNext()

    #expect(store.images.map(\.id) == [1, 2, 3])  // merged into the SAME array, in order
    #expect(store.focusedImageID == 2)  // advanced to the first newly-merged image
    #expect(!store.loupeExhausted)
    #expect(store.canLoupeGoNext)
    #expect(
      await transport.callCount(Operations.ImageNeighboursApiImagesImageIdNeighboursGet.id) == 1)

    // Now genuinely at the tail again, with nothing further -- an empty neighbours page marks
    // exhaustion and leaves focus untouched.
    store.focusedImageID = 3
    await transport.setNeighboursPage(.init(items: [], limit: 5, nextCursor: nil))
    await store.loupeNext()
    #expect(store.focusedImageID == 3)
    #expect(store.loupeExhausted)
    #expect(!store.canLoupeGoNext)
  }

  @Test(
    "a neighbours response landing after a shoot switch is discarded whole -- no old-scope rows, no stale focus (diff-gate round)"
  )
  func staleNeighboursResponseFromAPriorScopeIsDiscarded() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 1

    await transport.setNeighboursPage(
      .init(items: [makeImage(id: 2, revision: "r0")], limit: 5, nextCursor: nil))
    await transport.holdNeighboursRequests(true)
    let inFlight = Task { await store.loupeNext() }
    await transport.waitUntilNeighboursStarted()

    // The shoot changes while the neighbours request is genuinely in flight.
    await transport.holdNeighboursRequests(false)
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 10, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)

    await transport.releaseNeighbours()
    await inFlight.value

    #expect(store.images.map(\.id) == [10])  // the stale response appended nothing
    #expect(store.focusedImageID != 2)  // and restored no old-scope focus
  }

  @Test(
    "a neighbours response fully deduped by a concurrent grid merge is NOT exhaustion -- Next stays enabled, focus advances locally"
  )
  func overlappingNeighboursResponseDoesNotLatchExhaustion() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: "cursor-a"))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 1

    await transport.setNeighboursPage(
      .init(items: [makeImage(id: 2, revision: "r0")], limit: 5, nextCursor: nil))
    await transport.holdNeighboursRequests(true)
    let inFlight = Task { await store.loupeNext() }
    await transport.waitUntilNeighboursStarted()

    // While the neighbours request is in flight, the grid's own page fetch merges id 2 first.
    await transport.holdNeighboursRequests(false)
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 2, revision: "r0")], limit: 100, nextCursor: nil))
    await store.loadMoreIfNeeded(currentItemID: 1)
    #expect(store.images.map(\.id) == [1, 2])

    await transport.releaseNeighbours()
    await inFlight.value

    #expect(!store.loupeExhausted)  // dedup-empty is not the server saying "nothing further"
    #expect(store.canLoupeGoNext)
    #expect(store.focusedImageID == 2)  // advanced to the locally-present next image
  }

  @Test(
    "mergeImages dedup: a grid page fetched via loadMoreIfNeeded never re-adds an id the loupe's neighbours-merge already loaded"
  )
  func loadMoreIfNeededDedupsAgainstAnEarlierNeighboursMerge() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: "cursor-a"))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 1

    // The loupe's own forward prefetch adds id 2 ahead of any grid scroll.
    await transport.setNeighboursPage(
      .init(items: [makeImage(id: 2, revision: "r0")], limit: 5, nextCursor: nil))
    await store.loupeNext()
    #expect(store.images.map(\.id) == [1, 2])

    // The grid's OWN cursor-paged fetch later returns a page whose range OVERLAPS (id 2 again)
    // plus one genuinely new id (3) -- id 2 must not be duplicated.
    await transport.setListImagesPage(
      .init(
        items: [makeImage(id: 2, revision: "r0"), makeImage(id: 3, revision: "r0")], limit: 100,
        nextCursor: nil))
    await store.loadMoreIfNeeded(currentItemID: 2)

    #expect(store.images.map(\.id) == [1, 2, 3])  // id 2 appears exactly once
  }

  @Test("selectShoot resets loupe state: closed, not full-screen, exhaustion cleared")
  func selectShootResetsLoupeState() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.openLoupe(on: 1)
    store.toggleLoupeFullScreen()
    await transport.setNeighboursPage(.init(items: [], limit: 5, nextCursor: nil))
    await store.loupeNext()
    #expect(store.loupeExhausted)

    await transport.setListImagesPage(
      .init(items: [makeImage(id: 2, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)

    #expect(!store.isLoupeOpen)
    #expect(!store.isLoupeFullScreen)
    #expect(!store.loupeExhausted)
  }

  // MARK: - P5 BINDING: rapid double-mutation is refused, never interleaved (fold addendum)

  @Test(
    "A mark call while one is already in flight is REFUSED -- no snapshot, no second network call, no interleaved state"
  )
  func rapidDoubleMutationIsRefused() async throws {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .none, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await transport.holdMarkStateRequests(true)

    async let firstCall: Void = store.applyMark(.pick, to: [1])
    // Deterministic: only returns once the FIRST call's network request has genuinely started,
    // which can only happen after `isMutatingMark` was already set (that assignment strictly
    // precedes the awaited network call).
    await transport.waitUntilMarkStateStarted()
    #expect(store.isMutatingMark)

    // The rapid second tap: a DIFFERENT target state on the SAME image, while the first is
    // still in flight.
    await store.applyMark(.dislike, to: [1])

    // Refused: no second network call, no interleaved snapshot -- the image still shows only
    // the FIRST call's optimistic value, never dislike.
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == 1)
    #expect(store.images.first?.mark.state == .pick)

    await transport.releaseMarkState()
    _ = await firstCall

    // The first call completed normally once released -- proving the guard blocked only the
    // SECOND call, never the first's own eventual completion.
    #expect(!store.isMutatingMark)
    #expect(store.images.first?.mark.state == .pick)
    #expect(store.images.first?.mark.revision == "r1")
    #expect(store.undo.canUndo)

    // Guard released: a THIRD call now goes through normally.
    await transport.holdMarkStateRequests(false)
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r2")])))
    await store.applyMark(.dislike, to: [1])
    #expect(store.images.first?.mark.state == .dislike)
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == 2)
  }

  @Test("undoLastMark() is refused too while a mark mutation is in flight (same guard, same slot)")
  func undoRefusedWhileMarkInFlight() async throws {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .dislike, revision: "r0")], limit: 100, nextCursor: nil)
    )
    await store.selectShoot(folderID: 1)
    // Prime the undo slot with a completed, unrelated prior mutation.
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await store.applyMark(.pick, to: [1])
    #expect(store.undo.canUndo)

    await transport.holdMarkStateRequests(true)
    async let secondCall: Void = store.applyMark(.dislike, to: [1])
    await transport.waitUntilMarkStateStarted()

    await store.undoLastMark()  // refused: a mark mutation is in flight

    // 2, not 3: the priming `applyMark` above (1) plus the held second `applyMark` having
    // already ENTERED `send()` (2, counted at transport entry regardless of the hold) -- the
    // refused `undoLastMark()` must add NO third call.
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == 2)
    #expect(store.undo.canUndo)  // untouched -- undo never even read the slot

    await transport.releaseMarkState()
    _ = await secondCall
  }
}
