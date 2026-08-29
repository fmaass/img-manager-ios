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
    "Mixed-state batch undo: one group commits, the other 409s -- the 409'd group now routes through the SAME conflict-recovery machine as applyMark (diff-gate round 2, B4), not a bare rollback+remaining-retry"
  )
  func mixedStateUndoConflictRoutesThroughRecoveryMachine() async {
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
    // (image 2) 409. The recovery's own re-read reports image 2 at a genuinely different
    // revision ("r5"), so it lands in `.identified`, never the no-diff fallback.
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r2")])),
      forState: .dislike)
    await transport.setMarkStateOutcome(.conflict, forState: .none)
    await transport.setListImagesPage(
      .init(
        items: [
          makeImage(id: 1, mark: .dislike, revision: "r2"),
          makeImage(id: 2, mark: .pick, revision: "r5"),
        ], limit: 200, nextCursor: nil))

    await store.undoLastMark()

    // Image 1's group committed: restored to its truthful prior state, revision reconciled.
    #expect(store.images[0].mark.state == .dislike)
    #expect(store.images[0].mark.revision == "r2")
    #expect(store.lastMutationError == .conflict)

    // B4: the slot is now owned by conflictRecovery, not the old remaining-retry mechanism --
    // undo was cleared entirely (including image 1's own already-committed history), and the
    // recovery identifies image 2 (the 409'd restore) with its FRESH re-read revision.
    #expect(!store.undo.canUndo)
    guard case .identified(let intent, let freshMarkViews, let changedIDs) = store.conflictRecovery
    else {
      Issue.record("expected .identified, got \(String(describing: store.conflictRecovery))")
      return
    }
    #expect(intent == .setState(.none))  // the REJECTED restore was "set image 2 back to none"
    #expect(changedIDs == [2])
    #expect(freshMarkViews[2]?.revision == "r5")

    // Apply Again resubmits the restore (state .none) using the FRESH "r5" revision. The
    // per-state `.none` override from the undo attempt above (`.conflict`) is STILL active on
    // the stub -- it must be overridden again here, or the retry would 409 a second time.
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 2, revision: "r6")])),
      forState: .none)
    await store.applyConflictAgain()

    // Type-qualified `.none` -- a bare `.none` here would match `Optional<StatePayload>.none`
    // (nil), not `.some(StatePayload.none)`, since `sent?.state`'s type is `StatePayload?`.
    let none = Components.Schemas.MarkStateRequest.StatePayload.none
    let sent = await transport.lastMarkStateRequest
    #expect(sent?.state == none)
    #expect(sent?.preconditions?.first?.revision == "r5")
    #expect(store.images[1].mark.state == Components.Schemas.MarkView.StatePayload.none)
    #expect(store.images[1].mark.revision == "r6")
    #expect(store.conflictRecovery == nil)
    // Apply Again went through the ordinary applyMark path, which records its OWN fresh undo
    // entry for this specific recovered write (B4 scope decision: the original multi-group
    // entry, including image 1's already-committed restore, is not reconstructed).
    #expect(store.undo.canUndo)
    #expect(store.undo.entry?.imageIDs == [2])
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
    await store.pointerDragCrossed(.image(1))
    await store.pointerDragCrossed(.image(1))  // re-entry: must NOT apply a second time
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
    await store.pointerDragCrossed(.image(1))
    store.beginPointerDrag()  // a new drag gesture
    await store.pointerDragCrossed(.image(1))
    let callCount = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
    #expect(callCount == 2)
  }

  @Test("pointerDragCrossed in Select mode adds to the selection, not a mark")
  func pointerDragCrossedInSelectModeAddsToSelection() async {
    let (store, _) = makeStore()
    store.selection.enterSelectExplicitly()
    store.beginPointerDrag()
    await store.pointerDragCrossed(.image(7))
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
    store.rows = [[.image(1), .image(2), .image(3)], [.image(4), .image(5)]]
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

  // MARK: - P6: authoritative refresh (foreground + genuine same-shoot re-entry)

  @Test(
    "authoritativeRefresh replaces an optimistic mark the server disagrees with (server truth wins) and invalidates the undo slot"
  )
  func foregroundRefreshReplacesOptimisticMarkServerDisagreesWith() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .none, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await store.applyMark(.pick, to: [1])
    #expect(store.images.first?.mark.state == .pick)
    #expect(store.undo.canUndo)

    // Someone else reverted it on another surface between the local pick and this refresh.
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .none, revision: "r2")], limit: 100, nextCursor: nil))
    let refreshed = await store.authoritativeRefresh()

    let none = Components.Schemas.MarkView.StatePayload.none
    #expect(refreshed)
    #expect(store.images.first?.mark.state == none)
    #expect(store.images.first?.mark.revision == "r2")
    #expect(!store.undo.canUndo)
  }

  @Test(
    "authoritativeRefresh preserves loupe presentation AND focus when the focused image survives the refreshed query"
  )
  func authoritativeRefreshPreservesLoupeFocusWhenImageSurvives() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(
        items: [
          makeImage(id: 1, revision: "r0"),
          makeImage(id: 2, revision: "r0"),
        ], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.openLoupe(on: 1)
    #expect(store.isLoupeOpen)

    await transport.setListImagesPage(
      .init(
        items: [
          makeImage(id: 1, revision: "r5"),
          makeImage(id: 2, revision: "r0"),
        ], limit: 100, nextCursor: nil))
    let refreshed = await store.authoritativeRefresh()

    #expect(refreshed)
    #expect(store.isLoupeOpen)
    #expect(store.focusedImageID == 1)
    #expect(store.images.first { $0.id == 1 }?.mark.revision == "r5")
  }

  @Test(
    "authoritativeRefresh closes the loupe and clears focus (deterministically) when the focused image no longer matches the refreshed query -- never the prior unconditional clear"
  )
  func authoritativeRefreshClosesLoupeWhenFocusedImageVanishes() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(
        items: [makeImage(id: 1, revision: "r0"), makeImage(id: 2, revision: "r0")], limit: 100,
        nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.openLoupe(on: 1)

    // id 1 no longer matches the current query (e.g. its mark changed elsewhere) -- only id 2
    // survives the refreshed re-read.
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 2, revision: "r0")], limit: 100, nextCursor: nil))
    let refreshed = await store.authoritativeRefresh()

    #expect(refreshed)
    #expect(!store.isLoupeOpen)
    #expect(store.focusedImageID == nil)
    #expect(store.images.map(\.id) == [2])
  }

  @Test(
    "selectShoot on the ALREADY-selected shoot (genuine re-entry) triggers an authoritative refresh instead of the prior bare no-op"
  )
  func sameShootReentryTriggersRefresh() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    #expect(store.images.first?.mark.revision == "r0")

    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r5")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)  // same id -- genuine re-entry, not a scope change

    #expect(store.images.first?.mark.revision == "r5")
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 2)
  }

  @Test(
    "A generation-fenced authoritative refresh whose OWN fetch lands AFTER a scope change is discarded whole -- the new scope's data is never overwritten by the stale snapshot"
  )
  func staleAuthoritativeRefreshDiscardedByGenerationFence() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.holdNextListImagesRequest()
    async let refreshResult: Bool = store.authoritativeRefresh()
    await transport.waitUntilListImagesStarted()

    // The scope changes to folder 2 WHILE the refresh's own fetch is still suspended -- this is
    // a SEPARATE, un-held call (the hold was single-slot and already consumed by the refresh's
    // own fetch above), so it completes normally and bumps the generation.
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 99, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)
    #expect(store.images.map(\.id) == [99])

    // Only now does the STALE folder-1 fetch actually return.
    await transport.releaseListImages()
    let refreshed = await refreshResult

    #expect(!refreshed)
    #expect(store.images.map(\.id) == [99])  // untouched by the discarded stale snapshot
  }

  @Test(
    "A lifecycle refresh requested while a mutation is in flight QUEUES behind it (never refused, never dropped) and runs once the mutation completes"
  )
  func refreshDeferredBehindInFlightMutationRunsAfterward() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .none, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await transport.holdMarkStateRequests(true)

    async let markCall: Void = store.applyMark(.pick, to: [1])
    await transport.waitUntilMarkStateStarted()
    #expect(store.isMutatingMark)

    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .pick, revision: "r9")], limit: 100, nextCursor: nil))
    async let refreshResult: Bool = store.authoritativeRefresh()

    // Let the queued refresh task actually reach its (network-free) await point, then prove it
    // has NOT issued a network call yet -- it is genuinely queued, not merely "will run later".
    await Task.yield()
    await Task.yield()
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 1)

    await transport.releaseMarkState()
    _ = await markCall
    let refreshed = await refreshResult

    #expect(refreshed)
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 2)
    #expect(store.images.first?.mark.revision == "r9")
    #expect(!store.isMutatingMark)
  }

  @Test(
    "A cursor-invalid (400) mid-refresh discards the partial snapshot and restarts from page one -- the refresh still completes with the full, real multi-page result"
  )
  func cursorInvalidMidRefreshRestartsFromPageOne() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: "c2"))
    await store.selectShoot(folderID: 1)

    await transport.setListImagesPage(
      .init(items: [makeImage(id: 3, revision: "r0")], limit: 200, nextCursor: nil),
      forCursor: "c2")
    await transport.armListImagesRejectNonNilCursorOnce()
    let callsBefore = await transport.callCount(Operations.ListImagesApiImagesGet.id)

    let refreshed = await store.authoritativeRefresh()

    #expect(refreshed)
    #expect(store.images.map(\.id) == [1, 3])
    #expect(store.lastPageLoadError == nil)
    // page1 (ok) + page2/"c2" (400, once-armed) + page1 restart (ok) + page2/"c2" (ok) = 4.
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == callsBefore + 4)
  }

  @Test(
    "A neighbours FAILURE landing after a shoot switch does not surface lastPageLoadError in the new scope (premise-gate advisory (a): the failure path needs the SAME generation guard the success path already had)"
  )
  func neighboursCatchGuardDoesNotSurfaceStaleScopeError() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 1

    await transport.holdNeighboursRequests(true)
    let inFlight = Task { await store.loupeNext() }
    await transport.waitUntilNeighboursStarted()

    await transport.setNeighboursShouldFail(true)
    await transport.holdNeighboursRequests(false)
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 10, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)

    await transport.releaseNeighbours()
    await inFlight.value

    #expect(store.lastPageLoadError == nil)
    #expect(store.images.map(\.id) == [10])
  }

  // MARK: - P6: refused-write (409) recovery -- the adjudicated "Changed elsewhere" state machine

  @Test(
    "409 conflict: rolls back, re-reads authoritatively, identifies the changed-elsewhere subset by revision-diff, and Apply Again resubmits with FRESH revisions"
  )
  func conflictRecoveryIdentifiesChangedElsewhereAndApplyAgainResubmitsFreshRevisions() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .none, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(.conflict)
    // The automatic re-read sees a DIFFERENT revision than the rejected request submitted --
    // someone else touched the same image in between.
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .none, revision: "r5")], limit: 100, nextCursor: nil))

    await store.applyMark(.pick, to: [1])

    let none = Components.Schemas.MarkView.StatePayload.none
    #expect(store.images.first?.mark.state == none)  // rolled back to the truthful appearance
    #expect(store.images.first?.mark.revision == "r5")  // but revision is now SERVER truth
    #expect(store.lastMutationError == .conflict)
    #expect(!store.undo.canUndo)

    guard case .identified(let intent, let freshMarkViews, let changedIDs) = store.conflictRecovery
    else {
      Issue.record("expected .identified, got \(String(describing: store.conflictRecovery))")
      return
    }
    #expect(intent == .setState(.pick))
    #expect(freshMarkViews[1]?.revision == "r5")
    #expect(changedIDs == [1])

    // Apply Again: resubmits using the recovery's OWN fresh markview -- the "r5" revision, never
    // the stale rejected "r0".
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r6")])))
    await store.applyConflictAgain()

    let sent = await transport.lastMarkStateRequest
    #expect(sent?.preconditions?.first?.revision == "r5")
    #expect(store.images.first?.mark.state == .pick)
    #expect(store.images.first?.mark.revision == "r6")
    #expect(store.conflictRecovery == nil)
  }

  @Test(
    "409 conflict whose re-read finds NO differing revision (a revision raced back) falls back to marking the WHOLE submitted batch as changed elsewhere"
  )
  func conflictRecoveryFallsBackToWholeBatchWhenNoDiffFound() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(
        items: [
          makeImage(id: 1, mark: .none, revision: "r0"),
          makeImage(id: 2, mark: .none, revision: "r0"),
        ], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(.conflict)
    // listImagesPage is UNCHANGED -- the re-read sees the exact same revisions submitted.
    await store.applyMark(.pick, to: [1, 2])

    guard case .identified(_, _, let changedIDs) = store.conflictRecovery else {
      Issue.record("expected .identified, got \(String(describing: store.conflictRecovery))")
      return
    }
    #expect(changedIDs == [1, 2])
  }

  @Test(
    "409 conflict whose OWN re-read fails offers Retry Refresh (readFailed); Apply Again is inert until a fresh revision exists; retrying succeeds"
  )
  func conflictRecoveryReadFailureOffersRetryThenIdentifies() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .none, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(.conflict)
    await transport.setListImagesShouldFail(true)
    await store.applyMark(.pick, to: [1])

    guard case .readFailed(let intent, let batch) = store.conflictRecovery else {
      Issue.record("expected .readFailed, got \(String(describing: store.conflictRecovery))")
      return
    }
    #expect(intent == .setState(.pick))
    #expect(batch.first?.imageID == 1)

    // Apply Again matches ONLY `.identified` -- from `.readFailed` it is an inert no-op.
    let callsBefore = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
    await store.applyConflictAgain()
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == callsBefore)
    #expect(store.conflictRecovery != nil)

    // Retry Refresh: the transport is fixed, and now returns a genuinely different revision.
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .none, revision: "r5")], limit: 100, nextCursor: nil))
    await store.retryConflictRefresh()

    guard case .identified(_, _, let changedIDs) = store.conflictRecovery else {
      Issue.record(
        "expected .identified after retry, got \(String(describing: store.conflictRecovery))")
      return
    }
    #expect(changedIDs == [1])
  }

  @Test(
    "Keep Server Version dismisses the recovery surface with no further write"
  )
  func dismissConflictRecoveryIsInert() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .none, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    await transport.setMarkStateOutcome(.conflict)
    await store.applyMark(.pick, to: [1])
    #expect(store.conflictRecovery != nil)

    let callsBefore = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
    store.dismissConflictRecovery()

    #expect(store.conflictRecovery == nil)
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == callsBefore)
  }

  @Test(
    "Diff-gate round 2, B6: Apply Again still issues the API write for an image the RE-READ's filtered query no longer shows -- its fresh markview comes from a per-id detail() fetch, never silently dropped"
  )
  func applyConflictAgainResubmitsForImageVanishedFromFilteredReread() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(
        items: [
          makeImage(id: 1, mark: .none, revision: "r0"),
          makeImage(id: 2, mark: .none, revision: "r0"),
        ], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(.conflict)
    // The re-read's query no longer shows id 1 at all (e.g. the active filter now excludes it).
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 2, mark: .none, revision: "r0")], limit: 200, nextCursor: nil))
    await transport.setDetailResult(
      .init(
        ext: "jpg", filename: "vanished.jpg", folderId: 1, id: 1,
        lightroom: .init(sidecarPresent: false),
        mark: .init(revision: "r9", state: .none, tags: []),
        proxies: .init(additionalProperties: [:]), sourceTier: "local"))

    await store.applyMark(.pick, to: [1, 2])

    #expect(!store.images.contains { $0.id == 1 })  // gone entirely -- wholesale replace
    guard case .identified(_, let freshMarkViews, let changedIDs) = store.conflictRecovery else {
      Issue.record("expected .identified, got \(String(describing: store.conflictRecovery))")
      return
    }
    #expect(changedIDs == [1])  // id 2's revision matched -- only the vanished id differs
    #expect(freshMarkViews[1]?.revision == "r9")  // sourced from detail(), not `images`

    await transport.setMarkStateOutcome(
      .success(
        .init(
          applied: 2, requested: 2,
          revisions: [.init(imageId: 1, revision: "r10"), .init(imageId: 2, revision: "r1")])))
    await store.applyConflictAgain()

    // The write DID go out for id 1 -- with the fresh "r9" precondition -- never silently
    // skipped just because it is not in `images`.
    let sent = await transport.lastMarkStateRequest
    #expect(sent?.imageIds.sorted() == [1, 2])
    #expect(sent?.preconditions?.first(where: { $0.imageId == 1 })?.revision == "r9")
    #expect(store.conflictRecovery == nil)
  }

  // MARK: - P6: tags join the mutation lane / recovery machine (diff-gate round 2, B5)

  @Test(
    "addTag QUEUES behind an in-flight mark mutation instead of refusing or silently dropping the submitted tag (diff-gate round 2, B5)"
  )
  func addTagQueuesBehindInFlightMutation() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await transport.holdMarkStateRequests(true)
    async let markCall: Void = store.applyMark(.pick, to: [1])
    await transport.waitUntilMarkStateStarted()

    await transport.setTagsOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r2")])))
    async let tagCall: Void = store.addTag("landscape", to: [1])

    // Let the queued tag write actually reach its (network-free) await point, then prove it has
    // NOT issued a network call yet -- it is genuinely queued, not refused and not dropped.
    await Task.yield()
    await Task.yield()
    #expect(await transport.callCount(Operations.EditMarkTagsApiMarksTagsPost.id) == 0)

    await transport.releaseMarkState()
    _ = await markCall
    _ = await tagCall

    #expect(await transport.callCount(Operations.EditMarkTagsApiMarksTagsPost.id) == 1)
    #expect(store.images.first?.mark.tags == ["landscape"])
    #expect(store.images.first?.mark.revision == "r2")
  }

  @Test(
    "A tag write's 409 routes through the SAME recovery machine as state mutations (diff-gate round 2, B5): re-reads, identifies, and Apply Again resubmits the TAG with a fresh revision"
  )
  func tagConflictRoutesThroughRecoveryMachineAndApplyAgainResubmits() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setTagsOutcome(.conflict)
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r5")], limit: 200, nextCursor: nil))

    await store.addTag("landscape", to: [1])

    #expect(store.images.first?.mark.tags?.isEmpty ?? true)  // rolled back
    #expect(store.lastMutationError == .conflict)
    guard case .identified(let intent, let freshMarkViews, let changedIDs) = store.conflictRecovery
    else {
      Issue.record("expected .identified, got \(String(describing: store.conflictRecovery))")
      return
    }
    #expect(intent == .addTag("landscape"))
    #expect(changedIDs == [1])
    #expect(freshMarkViews[1]?.revision == "r5")

    await transport.setTagsOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r6")])))
    await store.applyConflictAgain()

    let sent = await transport.lastTagsRequest
    #expect(sent?.tag == "landscape")
    #expect(sent?.preconditions?.first?.revision == "r5")
    #expect(store.images.first?.mark.tags == ["landscape"])
    #expect(store.images.first?.mark.revision == "r6")
    #expect(store.conflictRecovery == nil)
  }

  // MARK: - P6: diff-gate round 2 B1/B2 -- generation fencing against a racing reload

  @Test(
    "Diff-gate round 2, B1: authoritativeRefresh ADVANCES the generation (never merely copies it), so an older pending reloadFirstPage cannot overwrite the refresh's newer, already-published snapshot"
  )
  func authoritativeRefreshAdvancesGenerationAgainstOlderPendingReload() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    // An older reload (a filter change) starts and gets its OWN fetch held -- it is genuinely
    // "in flight" when the refresh below starts.
    await transport.holdNextListImagesRequest()
    async let filterTask: Void = store.applyFilterChange { $0.mark = "pick" }
    await transport.waitUntilListImagesStarted()

    // The refresh's OWN fetch is unheld (the single-slot hold was already consumed) and
    // completes immediately with FRESHER data.
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r9")], limit: 100, nextCursor: nil))
    let refreshed = await store.authoritativeRefresh()
    #expect(refreshed)
    #expect(store.images.first?.mark.revision == "r9")

    // NOW the older, still-pending reload's held response finally arrives -- it must NOT be
    // allowed to overwrite the refresh's newer publish.
    await transport.releaseListImages()
    _ = await filterTask

    #expect(store.images.first?.mark.revision == "r9")  // untouched by the stale reload
  }

  @Test(
    "Diff-gate round 2, B2: applyMark's CONFLICT completion is fenced against a racing scope reload -- a 409 returning after a filter reload already republished the scope is discarded whole, no rollback, no error, no recovery state"
  )
  func applyMarkConflictCompletionDiscardedAfterRacingReload() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .none, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.holdMarkStateRequests(true)
    await transport.setMarkStateOutcome(.conflict)
    async let markTask: Void = store.applyMark(.pick, to: [1])
    await transport.waitUntilMarkStateStarted()

    // A filter reload runs to completion WHILE the mark write is still held -- it publishes a
    // DIFFERENT truth for the SAME id.
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .dislike, revision: "r2")], limit: 100, nextCursor: nil)
    )
    await store.applyFilterChange { $0.mark = "pick" }
    #expect(store.images.first?.mark.state == .dislike)
    #expect(store.images.first?.mark.revision == "r2")

    // NOW the held (and now stale) mark write finally returns its 409.
    await transport.releaseMarkState()
    _ = await markTask

    // Discarded whole: the reload's published truth is untouched, no error, no recovery state.
    #expect(store.images.first?.mark.state == .dislike)
    #expect(store.images.first?.mark.revision == "r2")
    #expect(store.lastMutationError == nil)
    #expect(store.conflictRecovery == nil)
  }

  @Test(
    "Diff-gate round 2, B2: applyMark's SUCCESS completion is likewise fenced -- a late success returning after selectShoot already moved to a new scope never records undo for the old scope's write"
  )
  func applyMarkSuccessCompletionDiscardedAfterRacingScopeChange() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .none, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.holdMarkStateRequests(true)
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    async let markTask: Void = store.applyMark(.pick, to: [1])
    await transport.waitUntilMarkStateStarted()

    // The scope changes to a DIFFERENT shoot entirely WHILE the write is still held.
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 99, mark: .none, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)
    #expect(store.images.map(\.id) == [99])
    #expect(!store.undo.canUndo)  // selectShoot's own scope-change clear

    // NOW the held (and now stale) write finally succeeds.
    await transport.releaseMarkState()
    _ = await markTask

    // Discarded whole: the new scope's images are untouched, and the late success did NOT
    // resurrect an undo entry for the OLD scope's write after selectShoot cleared the slot.
    #expect(store.images.map(\.id) == [99])
    #expect(!store.undo.canUndo)
  }

  @Test(
    "Diff-gate round 3, B6: a FAILED per-id detail() read for a filtered-out id never produces a silent partial `.identified` -- the whole recovery becomes .readFailed (retryable), Apply Again stays unavailable (no write at all) until the retry succeeds"
  )
  func detailFetchFailureForVanishedIDBecomesReadFailedNotSilentPartial() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .none, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(.conflict)
    // The re-read's query no longer shows id 1 at all, AND the detail() fallback itself fails.
    await transport.setListImagesPage(.init(items: [], limit: 200, nextCursor: nil))
    await transport.setDetailShouldFail(true)

    await store.applyMark(.pick, to: [1])

    guard case .readFailed(let intent, let batch) = store.conflictRecovery else {
      Issue.record("expected .readFailed, got \(String(describing: store.conflictRecovery))")
      return
    }
    #expect(intent == .setState(.pick))
    #expect(batch.first?.imageID == 1)

    // Apply Again is unavailable from .readFailed -- singleton batch, so a silent partial would
    // otherwise mean literally NO write at all.
    let callsBefore = await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id)
    await store.applyConflictAgain()
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == callsBefore)
    #expect(store.conflictRecovery != nil)

    // Retry Refresh: the detail() fetch now succeeds.
    await transport.setDetailShouldFail(false)
    await transport.setDetailResult(
      .init(
        ext: "jpg", filename: "vanished.jpg", folderId: 1, id: 1,
        lightroom: .init(sidecarPresent: false),
        mark: .init(revision: "r9", state: .none, tags: []),
        proxies: .init(additionalProperties: [:]), sourceTier: "local"))
    await store.retryConflictRefresh()

    guard case .identified(_, let freshMarkViews, let changedIDs) = store.conflictRecovery else {
      Issue.record(
        "expected .identified after retry, got \(String(describing: store.conflictRecovery))")
      return
    }
    #expect(changedIDs == [1])
    #expect(freshMarkViews[1]?.revision == "r9")
  }

  // MARK: - WP8 P7 (Q5): selectShoot's atomic (folderID, sourceTier) destination

  @Test("selectShoot(folderID:sourceTier:) sets BOTH atomically — never a two-step transition")
  func selectShootSetsBothFieldsAtomically() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 5, sourceTier: .archive)
    #expect(store.query.folderID == 5)
    #expect(store.query.sourceTier == .archive)
  }

  @Test(
    "Same folder_id, DIFFERENT tier is a real scope change (reloadFirstPage), never a bare refresh"
  )
  func sameFolderDifferentTierIsScopeChange() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 5, sourceTier: .local)
    let callsAfterFirst = await transport.callCount(Operations.ListImagesApiImagesGet.id)

    await transport.setListImagesPage(
      .init(items: [makeImage(id: 2)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 5, sourceTier: .archive)

    // A genuine scope change always issues its own fresh page-one fetch (reloadFirstPage),
    // proving this went through the scope-change branch, not the same-scope refresh branch.
    #expect(
      await transport.callCount(Operations.ListImagesApiImagesGet.id) == callsAfterFirst + 1)
    #expect(store.query.sourceTier == .archive)
    #expect(store.images.map(\.id) == [2])
  }

  @Test("Same folder_id AND same tier is genuine re-entry — refreshes, never a duplicate load")
  func sameFolderSameTierIsReEntry() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 5, sourceTier: .local)
    await store.selectShoot(folderID: 5, sourceTier: .local)
    // Both calls hit the SAME code path (reloadFirstPage first time, authoritativeRefresh
    // second time) — each issues exactly one images() call, so two total.
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 2)
    #expect(store.query.sourceTier == .local)
  }

  @Test("Omitting sourceTier reproduces the pre-P7 behavior exactly (nil, unconditionally)")
  func omittedSourceTierDefaultsNil() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 5, sourceTier: .archive)
    #expect(store.query.sourceTier == .archive)
    // A caller that never learned about tiers (every pre-P7 call site) still clears it back to
    // nil on its own next scope change — never silently inherits a stale tier from elsewhere.
    await store.selectShoot(folderID: 6)
    #expect(store.query.sourceTier == nil)
  }

  // MARK: - WP8 P7 (coexistence 7c): mutationCommitCount

  @Test("mutationCommitCount increments on a COMMITTED mark, never on a rolled-back one")
  func mutationCommitCountTracksCommitsOnly() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    #expect(store.mutationCommitCount == 0)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await store.applyMark(.pick, to: [1])
    #expect(store.mutationCommitCount == 1)

    await transport.setMarkStateOutcome(.conflict)
    await store.applyMark(.dislike, to: [1])
    // A refused write (conflict/rollback) must NOT increment — still 1, not 2.
    #expect(store.mutationCommitCount == 1)
  }

  @Test("mutationCommitCount increments on a committed tag write too")
  func mutationCommitCountTracksTagCommits() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setTagsOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await store.addTag("favorite", to: [1])
    #expect(store.mutationCommitCount == 1)
  }

  // MARK: - WP8 P7 round-2 closure (diff-gate round 3)

  private func makeQueueSummary(folderId: Int, sourceTier: String)
    -> Components.Schemas.FolderSummary
  {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderId, kind: "dated",
      lastTouched: nil, nothingLeftUnmarked: false, path: "p/\(folderId)", picked: 0,
      previewOutstanding: 0, readiness: .init(rawValue: "ready_to_review")!,
      sourceTier: sourceTier, sync: nil, total: 1, unmarked: 1, withMasters: 0)
  }

  // B1 (QueueView.swift:66): a queue-card tap used to forward `summary.sourceTier` instead of
  // clearing it — this test routes through the ACTUAL production function `QueueCardRow`'s tap
  // gesture calls (`QueueCardDestination.route(for:)`), never a hand-typed `nil`, so a
  // regression back to `summary.sourceTier` fails THIS test.
  @Test(
    "Queue-card entry clears a prior tree tier at the PRODUCTION forwarding level (B1)"
  )
  func queueCardEntryClearsTreeTierAtProductionForwardingLevel() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [], limit: 100, nextCursor: nil))
    // Tree entry: a Local/Archive branch tap sets a real tier filter.
    await store.selectShoot(folderID: 5, sourceTier: .archive)
    #expect(store.query.sourceTier == .archive)

    // Queue-card entry: the summary's OWN sourceTier is "archive" too (matching the tree's
    // last tier), proving the clear is unconditional -- never a same-tier coincidence.
    let summary = makeQueueSummary(folderId: 6, sourceTier: "archive")
    let destination = QueueCardDestination.route(for: summary)
    await store.selectShoot(folderID: destination.folderID, sourceTier: destination.sourceTier)

    #expect(store.query.folderID == 6)
    #expect(store.query.sourceTier == nil)
  }

  // B2 (GridStore.swift applyMark/undoLastMark/addTag): the commit signal used to sit AFTER the
  // generation guard at all three sites -- a scope change racing an in-flight, server-committed
  // mutation discarded the signal along with the (correctly-discarded) local reconciliation, so
  // the queue never learned a committed mutation happened. Each test below holds the mutation's
  // network call, races a genuine scope change (`selectShoot`, which never touches the mutation
  // lane) while it is suspended, then releases with a SUCCESS outcome.

  @Test(
    "B2 (applyMark): a committed mark still increments mutationCommitCount despite a racing generation change"
  )
  func applyMarkCommitCountFencedGenerationStillIncrements() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    #expect(store.mutationCommitCount == 0)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await transport.holdMarkStateRequests(true)
    async let markCall: Void = store.applyMark(.pick, to: [1])
    await transport.waitUntilMarkStateStarted()

    // The scope change lands and completes WHILE the mark request is still suspended --
    // selectShoot never touches the mutation lane, so nothing here queues behind it.
    await transport.setListImagesPage(.init(items: [], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)

    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    await markCall

    // The write landed server-side (success outcome) -- the commit signal must fire even
    // though the generation moved out from under it in the meantime.
    #expect(store.mutationCommitCount == 1)
    #expect(store.query.folderID == 2)  // the scope change itself was never rolled back
  }

  @Test(
    "B2 (applyMark): a REFUSED (409) mark never increments mutationCommitCount, race or no race"
  )
  func applyMarkConflictFencedGenerationDoesNotIncrement() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(.conflict)
    await transport.holdMarkStateRequests(true)
    async let markCall: Void = store.applyMark(.pick, to: [1])
    await transport.waitUntilMarkStateStarted()

    await transport.setListImagesPage(.init(items: [], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)

    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    await markCall

    #expect(store.mutationCommitCount == 0)
  }

  @Test(
    "B2 (undoLastMark): a committed undo still increments mutationCommitCount despite a racing generation change"
  )
  func undoCommitCountFencedGenerationStillIncrements() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, mark: .dislike, revision: "r0")], limit: 100, nextCursor: nil)
    )
    await store.selectShoot(folderID: 1)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await store.applyMark(.pick, to: [1])
    #expect(store.mutationCommitCount == 1)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r2")])))
    await transport.holdMarkStateRequests(true)
    async let undoCall: Void = store.undoLastMark()
    await transport.waitUntilMarkStateStarted()

    await transport.setListImagesPage(.init(items: [], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)

    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    await undoCall

    #expect(store.mutationCommitCount == 2)
  }

  @Test(
    "B2 (addTag): a committed tag write still increments mutationCommitCount despite a racing generation change"
  )
  func addTagCommitCountFencedGenerationStillIncrements() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    await transport.setTagsOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await transport.holdTagsRequests(true)
    async let tagCall: Void = store.addTag("favorite", to: [1])
    await transport.waitUntilTagsStarted()

    await transport.setListImagesPage(.init(items: [], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)

    await transport.holdTagsRequests(false)
    await transport.releaseTags()
    await tagCall

    #expect(store.mutationCommitCount == 1)
  }
}
