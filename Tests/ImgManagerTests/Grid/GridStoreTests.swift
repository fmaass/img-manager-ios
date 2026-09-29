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

  /// WP13 P8 (IMGMGR-214): the same stub store, but holding its OWN `UserDefaults` suite — the
  /// cadence is preference-driven, and a preference test must neither read nor leave state in
  /// the simulator's shared standard domain (`makeEphemeralDefaults`, P5a's own helper).
  private func makeStoreWithOwnPreferences() -> (GridStore, GridStubTransport, GridPreferences) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let service = GridService(client: client)
    let preferences = GridPreferences(defaults: makeEphemeralDefaults())
    return (GridStore(service: service, preferences: preferences), transport, preferences)
  }

  /// Three loaded frames, the loupe open on the first, and the cadence explicitly `on`/`off` —
  /// the shared setup for every advance-on-mark test below.
  private func makeLoupeAtFirstOfThree(autoAdvance: Bool) async -> (
    GridStore, GridStubTransport, GridPreferences
  ) {
    let (store, transport, preferences) = makeStoreWithOwnPreferences()
    await transport.setListImagesPage(
      .init(items: (1...3).map { makeImage(id: $0, revision: "r0") }, limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.openLoupe(on: 1)
    preferences.autoAdvanceOnMark = autoAdvance
    return (store, transport, preferences)
  }

  private func markCommits(_ transport: GridStubTransport, imageID: Int, revision: String) async {
    await transport.setMarkStateOutcome(
      .success(
        .init(applied: 1, requested: 1, revisions: [.init(imageId: imageID, revision: revision)])))
  }

  // MARK: - WP13 P8 (IMGMGR-214): the advance-on-mark cadence

  @Test("A COMMITTED loupe mark advances to the next frame when auto-advance is on")
  func aCommittedLoupeMarkAdvancesWhenAutoAdvanceIsOn() async {
    let (store, transport, _) = await makeLoupeAtFirstOfThree(autoAdvance: true)
    await markCommits(transport, imageID: 1, revision: "r1")

    let committed = await store.applyLoupeMark(.pick)

    #expect(committed)
    // The mark landed on the frame that was focused when the control was pressed...
    #expect(store.images.first(where: { $0.id == 1 })?.mark.state == .pick)
    // ...and the loupe then moved on to the next one, in the same flat order the grid uses.
    #expect(store.focusedImageID == 2)
    #expect(store.isLoupeOpen)
    // Pre-decided cadence answer (the phase's known-unknown): the undo slot is not
    // frame-scoped, so Undo stays enabled after the advance and reverts the mark just made on
    // the frame the loupe has already left.
    #expect(store.undo.canUndo)
    #expect(store.undo.entry?.priorStates.map(\.imageID) == [1])
    #expect(store.undo.entry?.appliedState == .pick)
  }

  @Test(
    "A refused or rolled-back loupe mark NEVER advances -- the 409 branch, and the empty-target refusal"
  )
  func aRefusedOrRolledBackLoupeMarkNeverAdvances() async {
    let (store, transport, _) = await makeLoupeAtFirstOfThree(autoAdvance: true)
    await transport.setMarkStateOutcome(.conflict)

    let committed = await store.applyLoupeMark(.pick)

    #expect(!committed)
    #expect(store.lastMutationError == .conflict)
    // Type-qualified `.none` -- bare `.none` would match `Optional.none` (nil), not
    // `.some(StatePayload.none)`.
    let none = Components.Schemas.MarkView.StatePayload.none
    #expect(store.images.first(where: { $0.id == 1 })?.mark.state == none)  // rolled back whole
    #expect(store.focusedImageID == 1)  // still the frame the person is judging
    #expect(store.isLoupeOpen)
    #expect(!store.undo.canUndo)  // a refused mutation never enters the undo slot

    // The other refusal shape: nothing focused writes nothing, so there is nothing to advance
    // from either.
    store.focusedImageID = nil
    let refused = await store.applyLoupeMark(.pick)
    #expect(!refused)
    #expect(store.focusedImageID == nil)
  }

  @Test("Auto-advance OFF leaves the frame in place -- the mark itself still commits")
  func autoAdvanceOffLeavesTheFrameInPlace() async {
    let (store, transport, _) = await makeLoupeAtFirstOfThree(autoAdvance: false)
    await markCommits(transport, imageID: 1, revision: "r1")

    let committed = await store.applyLoupeMark(.pick)

    #expect(committed)
    #expect(store.images.first(where: { $0.id == 1 })?.mark.state == .pick)
    #expect(store.focusedImageID == 1)
    #expect(store.isLoupeOpen)
  }

  @Test("Advance at the exhausted tail is a NO-OP that leaves the frame in place, never a close")
  func advanceAtTheExhaustedTailIsANoOpAndNeverCloses() async {
    let (store, transport, preferences) = makeStoreWithOwnPreferences()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.openLoupe(on: 1)
    preferences.autoAdvanceOnMark = true
    // Exhaustion is the SERVER's word: an empty forward-neighbour page is the only thing that
    // latches `loupeExhausted`.
    await transport.setNeighboursPage(.init(items: [], limit: 5, nextCursor: nil))
    await markCommits(transport, imageID: 1, revision: "r1")

    let committed = await store.applyLoupeMark(.dislike)

    #expect(committed)
    #expect(store.images.first?.mark.state == .dislike)
    #expect(store.focusedImageID == 1)  // nothing to advance to: the frame stays put
    #expect(store.loupeExhausted)
    #expect(!store.canLoupeGoNext)
    // The whole point of this test: the end of the pool is not a completion act (ADR-0004) and
    // an advance never dismisses the loupe.
    #expect(store.isLoupeOpen)
  }

  @Test("Auto-advance defaults to ON with nothing stored -- the owner decision of 2026-08-30")
  func autoAdvanceDefaultsToOnWithNoStoredPreference() {
    let defaults = makeEphemeralDefaults()
    #expect((defaults.object(forKey: GridPreferences.autoAdvanceOnMarkKey) as? Bool) == nil)
    #expect(GridPreferences.autoAdvanceOnMarkDefault)
    #expect(GridPreferences(defaults: defaults).autoAdvanceOnMark)

    // A real persisted preference, not a session flag: what the reader turns off stays off.
    let preferences = GridPreferences(defaults: defaults)
    preferences.autoAdvanceOnMark = false
    #expect(GridPreferences(defaults: defaults).autoAdvanceOnMark == false)
    #expect(GridPreferences.persistedKeys.contains(GridPreferences.autoAdvanceOnMarkKey))
  }

  @Test("The GRID's mark path never auto-advances -- Shift+advance stays its own deliberate act")
  func theGridMarkPathNeverAutoAdvances() async {
    let (store, transport, preferences) = makeStoreWithOwnPreferences()
    await transport.setListImagesPage(
      .init(items: (1...3).map { makeImage(id: $0, revision: "r0") }, limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 1  // focused in the GRID -- the loupe was never opened
    preferences.autoAdvanceOnMark = true
    await markCommits(transport, imageID: 1, revision: "r1")

    await store.handlePickShortcut(shiftHeld: false)
    #expect(store.images.first?.mark.state == .pick)
    #expect(store.focusedImageID == 1)  // bare P in the grid marks and stays put
    #expect(!store.isLoupeOpen)

    // ...and Shift+P still advances, exactly as it did before this phase.
    await markCommits(transport, imageID: 1, revision: "r2")
    await store.handlePickShortcut(shiftHeld: true)
    #expect(store.focusedImageID == 2)
  }

  // MARK: - Diff-gate r1, blocker 1: the advance is fenced to the frame that was marked

  @Test("Closing the loupe during an in-flight mark never advances — grid focus is untouched")
  func closingTheLoupeDuringAnInFlightMarkNeverAdvances() async {
    let (store, transport, _) = await makeLoupeAtFirstOfThree(autoAdvance: true)
    await markCommits(transport, imageID: 1, revision: "r1")
    await transport.holdMarkStateRequests(true)

    async let marked: Bool = store.applyLoupeMark(.pick)
    await transport.waitUntilMarkStateStarted()
    // Close stays enabled while a write is in flight (only the MARK controls disable), so this
    // is a real sequence, not a contrived one.
    store.closeLoupe()
    await transport.releaseMarkState()
    let committed = await marked

    // The write itself stands — the fence withholds the ADVANCE, never the mutation.
    #expect(committed)
    #expect(store.images.first(where: { $0.id == 1 })?.mark.state == .pick)
    #expect(!store.isLoupeOpen)
    // The grid's own focus must be exactly where the reader left it: a loupe mark that completes
    // after the loupe is gone has no business moving the grid.
    #expect(store.focusedImageID == 1)
  }

  @Test("Navigating during an in-flight mark never skips — the frame the reader chose stays put")
  func navigatingDuringAnInFlightMarkNeverSkips() async {
    let (store, transport, _) = await makeLoupeAtFirstOfThree(autoAdvance: true)
    await markCommits(transport, imageID: 1, revision: "r1")
    await transport.holdMarkStateRequests(true)

    async let marked: Bool = store.applyLoupeMark(.pick)
    await transport.waitUntilMarkStateStarted()
    // The reader moved on themselves, 1 -> 2, while the write was still in flight.
    await store.loupeNext()
    #expect(store.focusedImageID == 2)
    await transport.releaseMarkState()
    let committed = await marked

    #expect(committed)
    #expect(store.images.first(where: { $0.id == 1 })?.mark.state == .pick)
    // 2, never 3: the completion advances from the frame it MARKED or not at all, so it can
    // never skip the frame the reader deliberately chose.
    #expect(store.focusedImageID == 2)
    #expect(store.isLoupeOpen)
  }

  // MARK: - IMGMGR-269: the LATE completion of an advance's own tail fetch

  /// The half the two fences above do not cover. `applyLoupeMark` checks `isLoupeOpen` before it
  /// calls `loupeNext()`, but at the loaded TAIL that call awaits a forward-neighbour page — and
  /// the reader can close the loupe while that page is in flight. `closeLoupe()` neither clears
  /// `focusedImageID` nor bumps `loadGeneration` (the bumps live only in the two scope reloads),
  /// so the completion's own generation guard passes trivially and the focus advance lands on a
  /// grid the loupe has already left.
  ///
  /// The MERGE must still happen (the grid legitimately gains the fetched row); only the focus
  /// advance is loupe-scoped.
  @Test(
    "A tail advance whose neighbour page lands AFTER the loupe closed merges the row but never moves grid focus (IMGMGR-269)"
  )
  func aTailNeighbourPageLandingAfterCloseNeverMovesGridFocus() async {
    let (store, transport, preferences) = makeStoreWithOwnPreferences()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.openLoupe(on: 1)
    preferences.autoAdvanceOnMark = true
    // A NON-empty forward page: the race is only reachable when the server has something to
    // advance to, so the exhausted-tail no-op is not what this test is measuring.
    await transport.setNeighboursPage(
      .init(items: [makeImage(id: 2, revision: "r0")], limit: 5, nextCursor: nil))
    await markCommits(transport, imageID: 1, revision: "r1")
    await transport.holdNeighboursRequests(true)

    async let marked: Bool = store.applyLoupeMark(.pick)
    await transport.waitUntilNeighboursStarted()
    // The mark has committed and the advance's fetch is in flight. Close is never disabled by a
    // write (only the mark controls are), so this is a real sequence, not a contrived one.
    store.closeLoupe()
    await transport.releaseNeighbours()
    let committed = await marked

    #expect(committed)
    #expect(store.images.first(where: { $0.id == 1 })?.mark.state == .pick)
    #expect(!store.isLoupeOpen)
    // The row merged — the fetch's data is not thrown away...
    #expect(store.images.map(\.id) == [1, 2])
    // ...but the grid's focus is exactly where the reader left it when they closed the loupe.
    #expect(store.focusedImageID == 1)
  }

  /// The hole the first fence left (codex gate round 1, blocker 1). Guarding on "is the loupe
  /// open NOW" is not the same question as "is this the loupe session that ASKED": close the
  /// loupe while the forward page is held, tap the still-focused tile to reopen it on the SAME
  /// image, and both conditions read true again — so the stale completion advances a session that
  /// never requested it, off a frame the reader has only just come back to.
  @Test(
    "A neighbour page from a CLOSED loupe never advances a reopened one, even on the same image (IMGMGR-269)"
  )
  func aNeighbourPageFromAClosedLoupeNeverAdvancesTheReopenedSession() async {
    let (store, transport, preferences) = makeStoreWithOwnPreferences()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.openLoupe(on: 1)
    preferences.autoAdvanceOnMark = true
    await transport.setNeighboursPage(
      .init(items: [makeImage(id: 2, revision: "r0")], limit: 5, nextCursor: nil))
    await markCommits(transport, imageID: 1, revision: "r1")
    await transport.holdNeighboursRequests(true)

    async let marked: Bool = store.applyLoupeMark(.pick)
    await transport.waitUntilNeighboursStarted()
    // Close, then reopen on the SAME image — a tile tap on the frame the grid still has focused,
    // which is the ordinary way back in. Both of the first fence's conditions are true again.
    store.closeLoupe()
    store.openLoupe(on: 1)
    await transport.releaseNeighbours()
    let committed = await marked

    #expect(committed)
    #expect(store.images.map(\.id) == [1, 2])  // the rows still merge
    #expect(store.isLoupeOpen)
    // The reopened session asked for nothing, so it is left exactly where the reader put it.
    #expect(store.focusedImageID == 1)
  }

  /// The SECOND site of the same class, one level up: `applyLoupeMark`'s own cadence guard spans
  /// the mutation's await, so the identical close-then-reopen satisfies it too — and there the
  /// advance is a purely local step that needs no network at all. Enumerated with its sibling
  /// rather than left for the next round.
  @Test(
    "A mark committing into a REOPENED loupe never advances it either — the local step, no fetch (IMGMGR-269)"
  )
  func aMarkCommittingIntoAReopenedLoupeNeverAdvancesIt() async {
    let (store, transport, _) = await makeLoupeAtFirstOfThree(autoAdvance: true)
    await markCommits(transport, imageID: 1, revision: "r1")
    await transport.holdMarkStateRequests(true)

    async let marked: Bool = store.applyLoupeMark(.pick)
    await transport.waitUntilMarkStateStarted()
    store.closeLoupe()
    store.openLoupe(on: 1)
    await transport.releaseMarkState()
    let committed = await marked

    // The mutation always stands — only the cadence is withheld.
    #expect(committed)
    #expect(store.images.first(where: { $0.id == 1 })?.mark.state == .pick)
    #expect(store.isLoupeOpen)
    #expect(store.focusedImageID == 1)
  }

  // MARK: - IMGMGR-270: undo AFTER an auto-advance acts on the frame that was marked

  /// The P8 cadence suite proved the undo SLOT survives an advance (`canUndo`, `priorStates`,
  /// `appliedState`) but never called `undo()`, so a regression that reverted the frame the
  /// loupe advanced ONTO instead of the frame it marked would have passed unchanged. This drives
  /// the real path: mark -> advance -> undo, and reads back both frames plus the write that
  /// actually went out.
  @Test(
    "Undo after an auto-advance reverts the frame that was MARKED, never the one the advance landed on (IMGMGR-270)"
  )
  func undoAfterAnAutoAdvanceRevertsTheMarkedFrameNotTheFocusedOne() async {
    let (store, transport, _) = await makeLoupeAtFirstOfThree(autoAdvance: true)
    await markCommits(transport, imageID: 1, revision: "r1")

    #expect(await store.applyLoupeMark(.pick))
    #expect(store.focusedImageID == 2)  // the advance happened, so the two frames differ

    // Type-qualified `.none` — bare `.none` would match `Optional.none` (nil).
    let none = Components.Schemas.MarkView.StatePayload.none
    #expect(store.images.first(where: { $0.id == 2 })?.mark.state == none)

    // The undo's own write restores frame 1's prior state; the stub answers with its new revision.
    await markCommits(transport, imageID: 1, revision: "r2")
    await store.undoLastMark()

    #expect(store.images.first(where: { $0.id == 1 })?.mark.state == none)  // reverted
    #expect(store.images.first(where: { $0.id == 2 })?.mark.state == none)  // never touched
    #expect(store.images.first(where: { $0.id == 1 })?.mark.revision == "r2")
    // THE assertion the old test could not make: the request named the marked frame, not the
    // focused one. An undo that acted on `focusedImageID` would send [2] here.
    let undone = await transport.lastMarkStateRequest
    #expect(undone?.imageIds == [1])
    // Type-qualified again: bare `.none` on an Optional comparison means nil, not the state.
    #expect(undone?.state == Components.Schemas.MarkStateRequest.StatePayload.none)
    #expect(store.focusedImageID == 2)  // undo is a mutation, never a navigation
    #expect(!store.undo.canUndo)  // the one-slot stack is spent
  }

  // MARK: - IMGMGR-275: the loupe's mark bar REFLECTS the focused photograph's verdict

  /// Owner report 2026-08-31 (iPad): "marks cannot be seen". The grid tile has carried a mark
  /// badge since P4; the loupe — the app's actual culling surface since P8's advance-on-mark —
  /// carried none, so the reader could not tell whether the photograph in front of them was
  /// already picked. This drives the REAL paths the reader drives (mark → advance → step back →
  /// undo) and reads the bar's own presentation, not a re-derivation of it.
  @Test(
    "The loupe mark bar reflects the FOCUSED frame's verdict through advance, navigation and undo (IMGMGR-275)"
  )
  func theLoupeMarkBarReflectsTheFocusedFramesVerdict() async {
    let (store, transport, _) = await makeLoupeAtFirstOfThree(autoAdvance: true)
    // Nothing marked yet: both controls read plain, and say so to VoiceOver.
    #expect(!LoupeMarkPresentation.isActive(.pick, state: store.focusedMarkState))
    #expect(!LoupeMarkPresentation.isActive(.dislike, state: store.focusedMarkState))
    #expect(
      LoupeMarkPresentation.symbol(for: .pick, state: store.focusedMarkState) == "hand.thumbsup")
    #expect(
      LoupeMarkPresentation.accessibilityValue(for: .pick, state: store.focusedMarkState)
        == "Not picked")

    await markCommits(transport, imageID: 1, revision: "r1")
    #expect(await store.applyLoupeMark(.pick))

    // The advance landed on an UNMARKED frame, so the bar must read plain again — a bar that
    // latched on the button press would still be showing the previous frame's verdict.
    #expect(store.focusedImageID == 2)
    #expect(!LoupeMarkPresentation.isActive(.pick, state: store.focusedMarkState))

    // Stepping back to the frame just picked lights the Pick control, and only that one.
    store.loupePrevious()
    #expect(store.focusedImageID == 1)
    #expect(LoupeMarkPresentation.isActive(.pick, state: store.focusedMarkState))
    #expect(!LoupeMarkPresentation.isActive(.dislike, state: store.focusedMarkState))
    #expect(
      LoupeMarkPresentation.symbol(for: .pick, state: store.focusedMarkState)
        == "hand.thumbsup.fill")
    #expect(
      LoupeMarkPresentation.accessibilityValue(for: .pick, state: store.focusedMarkState)
        == "Picked")

    // Undo takes the verdict back — and the control with it.
    await markCommits(transport, imageID: 1, revision: "r2")
    await store.undoLastMark()
    #expect(!LoupeMarkPresentation.isActive(.pick, state: store.focusedMarkState))

    // The other verdict lights its OWN control, never Pick's.
    await markCommits(transport, imageID: 1, revision: "r3")
    #expect(await store.applyLoupeMark(.dislike))
    store.loupePrevious()
    #expect(store.focusedImageID == 1)
    #expect(LoupeMarkPresentation.isActive(.dislike, state: store.focusedMarkState))
    #expect(!LoupeMarkPresentation.isActive(.pick, state: store.focusedMarkState))
    #expect(
      LoupeMarkPresentation.symbol(for: .dislike, state: store.focusedMarkState)
        == "hand.thumbsdown.fill")
    #expect(
      LoupeMarkPresentation.accessibilityValue(for: .dislike, state: store.focusedMarkState)
        == "Disliked")
  }

  /// The store-side half, pinned on its own: with nothing focused there is no verdict to show,
  /// and the answer comes from the ACTIONABLE projection (what the loupe and filmstrip walk).
  @Test("The focused verdict is nil with nothing focused, and follows the focused id otherwise")
  func theFocusedVerdictFollowsFocus() async {
    let (store, transport, _) = await makeLoupeAtFirstOfThree(autoAdvance: false)
    await markCommits(transport, imageID: 1, revision: "r1")
    #expect(await store.applyLoupeMark(.pick))

    #expect(store.focusedMarkState == .pick)
    store.loupeFocus(on: 3)
    let none = Components.Schemas.MarkView.StatePayload.none
    #expect(store.focusedMarkState == none)
    store.focusedImageID = nil
    #expect(store.focusedMarkState == nil)
  }

  // MARK: - Diff-gate r1, blocker 2: bare P/X/U in the loupe ride the same cadence seam

  @Test("A bare keyboard mark in the LOUPE advances on commit — the mark bar's own cadence")
  func aBareKeyboardMarkInTheLoupeAdvancesOnCommit() async {
    let (store, transport, _) = await makeLoupeAtFirstOfThree(autoAdvance: true)
    await markCommits(transport, imageID: 1, revision: "r1")

    await store.handlePickShortcut(shiftHeld: false)
    #expect(store.images.first(where: { $0.id == 1 })?.mark.state == .pick)
    #expect(store.focusedImageID == 2)
    #expect(store.isLoupeOpen)

    // X rides the same seam.
    await markCommits(transport, imageID: 2, revision: "r1")
    await store.handleDislikeShortcut(shiftHeld: false)
    #expect(store.images.first(where: { $0.id == 2 })?.mark.state == .dislike)
    #expect(store.focusedImageID == 3)

    // And U, at the tail: the stub's default forward-neighbour page is empty, so this is the
    // exhausted-tail no-op again — reached through the keyboard this time, and still never a
    // close.
    await markCommits(transport, imageID: 3, revision: "r1")
    await store.handleClearShortcut(shiftHeld: false)
    #expect(store.focusedImageID == 3)
    #expect(store.loupeExhausted)
    #expect(store.isLoupeOpen)
  }

  @Test("A bare keyboard mark in the loupe leaves the frame when auto-advance is OFF")
  func aBareKeyboardMarkInTheLoupeLeavesTheFrameWhenAutoAdvanceIsOff() async {
    let (store, transport, _) = await makeLoupeAtFirstOfThree(autoAdvance: false)
    await markCommits(transport, imageID: 1, revision: "r1")

    await store.handlePickShortcut(shiftHeld: false)

    #expect(store.images.first(where: { $0.id == 1 })?.mark.state == .pick)
    #expect(store.focusedImageID == 1)
    #expect(store.isLoupeOpen)
  }

  @Test("Shift+P in the loupe keeps its OWN path and advances exactly once, toggle or no toggle")
  func shiftAdvanceInTheLoupeIsUnchangedByTheCadence() async {
    let (store, transport, _) = await makeLoupeAtFirstOfThree(autoAdvance: true)
    await markCommits(transport, imageID: 1, revision: "r1")

    await store.handlePickShortcut(shiftHeld: true)

    // ONE step, not two: Shift+advance is the grid's own deliberate mark-and-advance and this
    // phase must not compose it with the loupe cadence (the phase's Do-NOT list).
    #expect(store.images.first(where: { $0.id == 1 })?.mark.state == .pick)
    #expect(store.focusedImageID == 2)
    #expect(store.isLoupeOpen)
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
    _ = store.pickLock.activate(verb: .pick, at: t0)
    _ = store.pickLock.activate(verb: .pick, at: t0.advanced(by: .milliseconds(100)))
    #expect(store.pickLock.state == .latched(.pick))

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
    _ = store.pickLock.activate(verb: .pick, at: t0)
    _ = store.pickLock.activate(verb: .pick, at: t0.advanced(by: .milliseconds(100)))

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

  // MARK: - "Lock Pick"/"Lock Dislike" discoverable menu commands (gate's unasked issue)

  @Test("lockFromMenu() latches immediately -- no timing window, unlike the double-tap path")
  func lockFromMenuLatchesImmediately() {
    for verb in LatchVerb.allCases {
      let (store, _) = makeStore()
      #expect(store.pickLock.state == .idle)
      store.lockFromMenu(verb)
      #expect(store.pickLock.state == .latched(verb))
    }
  }

  @Test("lockFromMenu() is a no-op while Select is active -- for either verb")
  func lockFromMenuNoopDuringSelect() {
    for verb in LatchVerb.allCases {
      let (store, _) = makeStore()
      store.selection.enterSelectExplicitly()
      store.lockFromMenu(verb)
      #expect(store.pickLock.state == .idle)
    }
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
    _ = store.pickLock.activate(verb: .pick, at: t0)
    _ = store.pickLock.activate(verb: .pick, at: t0.advanced(by: .milliseconds(100)))
    #expect(store.pickLock.state == .latched(.pick))

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
    await store.activateLatchButton(.pick)
    #expect(store.pickLock.state == .idle)
  }

  /// WP13 P2 (IMGMGR-222) reverses the WP8 pin this test used to assert ("v1 is PICK-ONLY —
  /// Dislike never latches"): the owner decided on 2026-08-30 that the Dislike BUTTON latches
  /// symmetrically. What survives the reversal untouched is the KEYBOARD half of the pin —
  /// `X`, like `P`, never participates in latch detection — so the test keeps its assertion and
  /// gains the two cases that make it a real invariant rather than a single idle read.
  @Test("Keyboard X never latches, never unlatches, and never arms the double-tap window")
  func keyboardXNeverLatches() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 1
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))

    // Two X presses in immediate succession: if the keyboard shared the button's anchor, this
    // is exactly the pair that would latch.
    await store.handleDislikeShortcut(shiftHeld: false)
    await store.handleDislikeShortcut(shiftHeld: false)
    #expect(store.pickLock.state == .idle)

    // And X while genuinely latched neither unlatches nor switches the verb.
    store.lockFromMenu(.dislike)
    await store.handleDislikeShortcut(shiftHeld: false)
    #expect(store.pickLock.state == .latched(.dislike))
    await store.handlePickShortcut(shiftHeld: false)
    #expect(store.pickLock.state == .latched(.dislike))
  }

  // MARK: - Dislike Lock parity (WP13 P2, IMGMGR-222)

  @Test(
    "A latched Dislike applies DISLIKE on a tile tap and on a pointer-drag crossing — the same lane, the latched verb"
  )
  func latchedDislikeAppliesDislikeOnTapAndOnPointerDragCrossing() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(
        items: [makeImage(id: 1, revision: "r0"), makeImage(id: 2, revision: "r0")],
        limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    // Latched through the button's own double tap, inside the 350 ms window.
    let t0 = ContinuousClock.now
    _ = store.pickLock.activate(verb: .dislike, at: t0)
    _ = store.pickLock.activate(verb: .dislike, at: t0.advanced(by: .milliseconds(100)))
    #expect(store.pickLock.state == .latched(.dislike))

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await store.tapTile(1)
    // The WIRE is the assertion, not a local flag: a latched tap that still hard-coded `.pick`
    // would leave the store looking right and write the wrong mark.
    let tapped = await transport.lastMarkStateRequest
    #expect(tapped?.state == .dislike)
    #expect(tapped?.imageIds == [1])
    #expect(store.images[0].mark.state == .dislike)
    // Preconditions still ride along: the latched lane is the SHIPPED mutation lane, not a
    // second one that skips the revision check.
    #expect(tapped?.preconditions?.first?.revision == "r0")
    #expect(store.undo.canUndo)

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 2, revision: "r1")])))
    store.beginPointerDrag()
    await store.pointerDragCrossed(.image(2))
    let dragged = await transport.lastMarkStateRequest
    #expect(dragged?.state == .dislike)
    #expect(dragged?.imageIds == [2])
    #expect(store.images[1].mark.state == .dislike)
  }

  @Test(
    "Entering Select while Dislike-latched unlatches FIRST and applies nothing during the transition"
  )
  func enteringSelectWhileDislikeLatchedUnlatchesFirstAndAppliesNothing() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 999, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.lockFromMenu(.dislike)
    #expect(store.pickLock.state == .latched(.dislike))

    store.longPressTile(999)
    #expect(store.pickLock.state == .idle)
    #expect(store.selection.mode == .select)
    #expect(store.selection.members == [999])
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == 0)

    // The explicit entry too, from a fresh latch.
    store.done()
    store.lockFromMenu(.dislike)
    #expect(store.pickLock.state == .latched(.dislike))
    store.enterSelectExplicitly()
    #expect(store.pickLock.state == .idle)
    #expect(store.selection.mode == .select)
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == 0)
  }

  @Test("Dislike Lock entry is disabled while Select is active — the button bulk-marks instead")
  func dislikeLockEntryDisabledDuringSelect() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.enterSelectExplicitly()
    store.selection.toggle(1)
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))

    // Two presses in immediate succession: outside Select this pair latches.
    await store.activateLatchButton(.dislike)
    await store.activateLatchButton(.dislike)
    #expect(store.pickLock.state == .idle)
    let bulk = await transport.lastMarkStateRequest
    #expect(bulk?.state == .dislike)
    #expect(bulk?.imageIds == [1])
  }

  @Test(
    "Pressing the other verb's button while latched exits the latch and applies that verb ONCE, through the store"
  )
  func pressingTheOtherLatchVerbExitsAndAppliesOnce() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 1
    store.lockFromMenu(.pick)
    #expect(store.pickLock.state == .latched(.pick))

    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))
    await store.activateLatchButton(.dislike)

    #expect(store.pickLock.state == .idle)
    let applied = await transport.lastMarkStateRequest
    #expect(applied?.state == .dislike)
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == 1)
  }

  /// ADR-0005 decision 4, for the one gesture that cannot be stopped at its own site: a pointer
  /// drag does not choose which cells it crosses, so the refusal has to live in the lane. The
  /// generalization to a verb must not have turned "a card has no image id" into "a card gets
  /// the latched verb".
  @Test(
    "The latched write boundary stays actionable-only: a Dislike-latched drag across a collapsed scene card writes nothing"
  )
  func latchedDislikeNeverWritesThroughASceneCard() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.lockFromMenu(.dislike)
    #expect(store.pickLock.state == .latched(.dislike))

    store.beginPointerDrag()
    await store.pointerDragCrossed(.stack(1))
    await store.pointerDragCrossed(.stack(2))
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == 0)
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

  // MARK: - Stats-tab facet taps reach the wire (WP12 compact filter surface)

  /// Same construction as `makeStore()`. The service is NOT handed to the tests to call
  /// directly — driving `GridService.facets` by hand would prove nothing about the app, since
  /// deleting the store's own refresh would leave such a test green. Every assertion below goes
  /// through `applyFacetFilter`/`clearFacetFilters`/`refreshFacets`, which is exactly what the
  /// Stats row's Button and the inspector's `.task(id:)` call and all they call.
  private func makeStoreWithFacets(total: Int) async -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let store = GridStore(service: GridService(client: client))
    await transport.setFacetsResult(.init(total: total))
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1, revision: "r0")], limit: 100, nextCursor: nil))
    return (store, transport)
  }

  @Test("A facet-row tap carries the filter into BOTH the images and the facets request")
  func facetTapReachesImagesAndFacetsRequests() async {
    let (store, transport) = await makeStoreWithFacets(total: 42)
    await store.selectShoot(folderID: 7)
    await store.refreshFacets()  // what the inspector's `.task(id:)` does on appearance
    let identityBeforeTap = store.queryIdentity
    let facetsBeforeTap = await transport.callCount(Operations.ImageFacetsApiFacetsGet.id)

    // Exactly what the Stats row's Button does when "pick" under Mark is tapped — no test-only
    // call path, and nothing else in between.
    await store.applyFacetFilter(.mark, value: "pick")

    #expect(store.query.mark == "pick")
    let imagesQuery = await transport.lastListImagesQuery
    #expect(imagesQuery?["mark"] == "pick")
    #expect(imagesQuery?["folder_id"] == "7")

    // The counts were refetched BY THE TAP, under the new filter — not by the test.
    let facetsAfterTap = await transport.callCount(Operations.ImageFacetsApiFacetsGet.id)
    #expect(facetsAfterTap == facetsBeforeTap + 1)
    let facetsQuery = await transport.lastFacetsQuery
    #expect(facetsQuery?["mark"] == "pick")
    #expect(facetsQuery?["folder_id"] == "7")
    #expect(store.facets?.total == 42)
    #expect(store.queryIdentity != identityBeforeTap)

    // The inspector's `.task(id:)` re-fires on that same identity change: it must not fetch the
    // same counts a second time.
    await store.refreshFacets()
    let facetsAfterTaskRefire = await transport.callCount(Operations.ImageFacetsApiFacetsGet.id)
    #expect(facetsAfterTaskRefire == facetsAfterTap)
  }

  @Test("A second tap on the active value clears that filter from the next images request")
  func secondTapClearsTheFilterOnTheWire() async {
    let (store, transport) = await makeStoreWithFacets(total: 9)
    await store.selectShoot(folderID: 7)

    await store.applyFacetFilter(.mark, value: "pick")
    await store.applyFacetFilter(.mark, value: "pick")

    #expect(store.query.mark == nil)
    let imagesQuery = await transport.lastListImagesQuery
    #expect(imagesQuery?["mark"] == nil)
    #expect(imagesQuery?["folder_id"] == "7")
    // The counts followed the filter back out, too.
    let facetsQuery = await transport.lastFacetsQuery
    #expect(facetsQuery?["mark"] == nil)
  }

  @Test("Clear filters drops every facet field from the wire but keeps the shoot scope")
  func clearFiltersKeepsTheShootScope() async {
    let (store, transport) = await makeStoreWithFacets(total: 13)
    await store.selectShoot(folderID: 7, sourceTier: .archive)

    await store.applyFacetFilter(.mark, value: "pick")
    await store.applyFacetFilter(.ext, value: "raf")
    #expect(InspectorFacetFilters.activeCount(store.currentQuery) == 2)

    let reloadsBefore = await transport.callCount(Operations.ListImagesApiImagesGet.id)
    let facetsBefore = await transport.callCount(Operations.ImageFacetsApiFacetsGet.id)
    await store.clearFacetFilters()
    let reloadsAfter = await transport.callCount(Operations.ListImagesApiImagesGet.id)
    let facetsAfter = await transport.callCount(Operations.ImageFacetsApiFacetsGet.id)

    // Clearing is a real filter change: same generation-fenced reload every facet tap does, and
    // the counts are refetched for the now-unfiltered scope — never a silent local reset.
    #expect(reloadsAfter == reloadsBefore + 1)
    #expect(facetsAfter == facetsBefore + 1)
    #expect(InspectorFacetFilters.activeCount(store.currentQuery) == 0)
    let imagesQuery = await transport.lastListImagesQuery
    #expect(imagesQuery?["mark"] == nil)
    #expect(imagesQuery?["ext"] == nil)
    #expect(imagesQuery?["folder_id"] == "7")
    #expect(imagesQuery?["source_tier"] == "archive")
    let facetsQuery = await transport.lastFacetsQuery
    #expect(facetsQuery?["mark"] == nil)
    #expect(facetsQuery?["source_tier"] == "archive")
  }

  @Test("A failed facets fetch leaves the last good counts standing, and retries next time")
  func failedFacetsFetchKeepsLastGoodCounts() async {
    let (store, transport) = await makeStoreWithFacets(total: 42)
    await store.selectShoot(folderID: 7)
    await store.refreshFacets()
    #expect(store.facets?.total == 42)

    // The next facets call fails; the tap still applies, and the tab keeps the counts it had
    // rather than blanking (absence renders as absence, never as zeros).
    await transport.setFacetsShouldFail(true)
    await store.applyFacetFilter(.mark, value: "pick")
    #expect(store.query.mark == "pick")
    #expect(store.facets?.total == 42)

    // ...and because the failure never recorded an identity, the next refresh really retries.
    await transport.setFacetsResult(.init(total: 7))
    await store.refreshFacets()
    #expect(store.facets?.total == 7)
  }

  @Test("A refresh firing while one is in flight for the SAME query issues no second GET")
  func concurrentRefreshesForTheSameQueryCoalesce() async {
    let (store, transport) = await makeStoreWithFacets(total: 42)
    await store.selectShoot(folderID: 7)
    await transport.holdFacetsRequests(true)

    // The tap's own refresh, suspended inside the transport — the new filter is already written
    // to `query`, which is the window the MainActor does NOT serialize away.
    async let tap: Void = store.applyFacetFilter(.mark, value: "pick")
    await transport.waitUntilFacetsStarted()

    // The inspector's `.task(id: queryIdentity)` firing for that same new identity, inside the
    // window where the in-flight refresh has not yet written `facetsIdentity`.
    async let taskRefresh: Void = store.refreshFacets()
    await Task.yield()
    await Task.yield()

    // Counted at transport ENTRY, so a request that merely sits held is still counted: one call
    // means the second refresh joined the first rather than issuing its own.
    #expect(await transport.callCount(Operations.ImageFacetsApiFacetsGet.id) == 1)

    // Disabled BEFORE the release, so a NON-coalesced second request would complete and be
    // counted too: a regression fails this test on the assertion below instead of hanging it.
    await transport.holdFacetsRequests(false)
    await transport.releaseFacets()
    _ = await tap
    _ = await taskRefresh

    #expect(await transport.callCount(Operations.ImageFacetsApiFacetsGet.id) == 1)
    #expect(store.query.mark == "pick")
    #expect(store.facets?.total == 42)
    #expect(store.facetsIdentity == store.currentQuery)
  }

  @Test("A refresh for a DIFFERENT query is never joined — it supersedes, and the stale one loses")
  func aRefreshForADifferentQuerySupersedes() async {
    let (store, transport) = await makeStoreWithFacets(total: 42)
    await store.selectShoot(folderID: 7)
    await store.refreshFacets()
    #expect(store.facets?.total == 42)
    await transport.holdFacetsRequests(true)

    // Refresh A: the counts for "mark = pick", suspended inside the transport.
    async let first: Void = store.applyFacetFilter(.mark, value: "pick")
    await transport.waitUntilFacetsStarted()

    // Refresh B, for a DIFFERENT identity (a second facet on top). Its response is resolved at
    // request entry, so this new value belongs to B alone and A still carries the old one.
    await transport.setFacetsResult(.init(total: 7))
    async let second: Void = store.applyFacetFilter(.ext, value: "raf")
    await Task.yield()
    await Task.yield()

    await transport.holdFacetsRequests(false)
    await transport.releaseFacets()
    _ = await first
    _ = await second

    // Three calls: the priming refresh, A, and B — B was NOT joined to A. And whichever of the
    // two came home last, the published counts are B's: A's guard discards a response for a
    // query the app has already moved past.
    #expect(await transport.callCount(Operations.ImageFacetsApiFacetsGet.id) == 3)
    #expect(store.facets?.total == 7)
    #expect(store.query.mark == "pick")
    #expect(store.query.ext == "raf")
    #expect(store.facetsIdentity == store.currentQuery)
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
    store.lockFromMenu(.pick)
    #expect(store.pickLock.state == .latched(.pick))

    store.openLoupe(on: 1)

    #expect(store.isLoupeOpen)
    #expect(store.focusedImageID == 1)
    #expect(store.selection.mode == .browse)
    #expect(store.selection.members.isEmpty)
    // PickLockState.exit() is "grid-only, never the loupe".
    #expect(store.pickLock.state == .latched(.pick))
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
    // IMGMGR-269 made the tail advance loupe-scoped, so the setup opens the loupe rather than
    // seeding focus alone: `loupeNext()` has exactly three call sites in production (the loupe's
    // Next control, its drag advance, and `applyLoupeMark`) and every one of them runs with the
    // loupe open. Seeding `focusedImageID` was a shortcut for a state the app cannot be in.
    store.openLoupe(on: 1)
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
    // Open, not merely focused — same reason as `loupeNextFetchesAndMergesNeighboursAtTail`
    // above: since IMGMGR-269 the tail advance only lands while the loupe is the surface, which
    // is the only state production can reach `loupeNext()` from anyway.
    store.openLoupe(on: 1)

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
    await transport.setNeighboursPage(.init(items: [], limit: 5, nextCursor: nil))
    await store.loupeNext()
    #expect(store.loupeExhausted)

    await transport.setListImagesPage(
      .init(items: [makeImage(id: 2, revision: "r0")], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)

    #expect(!store.isLoupeOpen)
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

    // WP13 P8 (IMGMGR-214): `Bool`, not `Void`. `applyMark` answers now, and
    // `@discardableResult` covers a discarded call EXPRESSION — never an explicit `: Void` type
    // annotation like this one. All eight sites of that shape (grep `: Void = ...applyMark` over
    // Sources/ + Tests/) are converted together; the concurrency shape is unchanged.
    async let firstCall: Bool = store.applyMark(.pick, to: [1])
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
    async let secondCall: Bool = store.applyMark(.dislike, to: [1])
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

    async let markCall: Bool = store.applyMark(.pick, to: [1])
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
        ext: "jpg", fileSize: 4_096, filename: "vanished.jpg", folderId: 1, id: 1,
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
    async let markCall: Bool = store.applyMark(.pick, to: [1])
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

  // MARK: - WP14: the mutation lane's silent races (IMGMGR-204, IMGMGR-250, IMGMGR-251)

  /// Suspends until `count` calls are genuinely QUEUED on the mutation lane behind its holder.
  ///
  /// A CONDITION, never a fixed number of yields: it cannot pass before the milestone actually
  /// holds, so a test gated on it either proves the interleaving it claims or hangs — it can
  /// never quietly assert against a call that had not started yet.
  private func waitUntilQueuedOnLane(_ store: GridStore, count: Int = 1) async {
    while store.laneWaiterCount < count {
      await Task.yield()
    }
  }

  /// Takes the mutation lane with a refresh whose own read is held open, so a caller can queue
  /// behind it deterministically. Returns the in-flight refresh to await after the release.
  ///
  /// A refresh rather than a mark: it holds the lane without spending a `setMarkState` call, so a
  /// test that counts mark writes counts only the writes it is actually asking about.
  private func holdLaneWithRefresh(_ store: GridStore, _ transport: GridStubTransport) async
    -> Task<Bool, Never>
  {
    await transport.holdNextListImagesRequest()
    let refresh = Task { @MainActor in await store.authoritativeRefresh() }
    await transport.waitUntilListImagesStarted()
    return refresh
  }

  @Test(
    "IMGMGR-204: a tag write queued behind an authoritative refresh REPORTS the ids that refresh pruned, instead of silently writing fewer than it was asked to"
  )
  func aQueuedTagWriteReportsIdsPrunedWhileItWaitedOnTheLane() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(
        items: [makeImage(id: 1, revision: "r0"), makeImage(id: 2, revision: "r0")], limit: 100,
        nextCursor: nil))
    await store.selectShoot(folderID: 1)
    // POSITIVE CONTROL: both ids really are writable at the moment of submission, so a dropped
    // one below means the RACE, not the pre-existing "was never loaded" skip.
    #expect(store.actionableImages.map(\.id) == [1, 2])

    // The refresh's own response — the stub resolves it at REQUEST time, before its hold — no
    // longer contains id 1. That is what a refresh landing under a queued write looks like.
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 2, revision: "r0")], limit: 200, nextCursor: nil))
    await transport.holdNextListImagesRequest()
    async let refresh: Bool = store.authoritativeRefresh()
    await transport.waitUntilListImagesStarted()

    await transport.setTagsOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 2, revision: "r1")])))
    async let tagCall: Void = store.addTag("landscape", to: [1, 2])
    // Gated on the MILESTONE, not on a guessed number of yields: this cannot proceed until the
    // tag write has actually reached `acquireLaneQueueing()` and suspended on the lane — which
    // is exactly the moment that guarantees it already captured its submission-time id set, with
    // the prune still ahead of it. A fixed yield count could pass before that and quietly test
    // nothing.
    await waitUntilQueuedOnLane(store)
    // ...and it issued NOTHING to get there: genuinely queued, not refused and not dropped.
    #expect(await transport.callCount(Operations.EditMarkTagsApiMarksTagsPost.id) == 0)

    await transport.releaseListImages()
    _ = await refresh
    _ = await tagCall

    // The write itself still covers only what is loaded — the actionable-only write boundary,
    // deliberately unchanged...
    #expect(store.images.map(\.id) == [2])
    #expect(await transport.lastTagsRequest?.imageIds == [2])
    // ...but the id the wait cost the reader is now STATED rather than silently missing.
    #expect(
      store.droppedWriteIDs == [1],
      "the pruned id left the write with no signal of any kind to the reader")
    #expect(GridNotices.notices(store: store).contains(.droppedWrites(count: 1)))

    store.dismissDroppedWriteNotice()
    #expect(store.droppedWriteIDs.isEmpty)
    #expect(GridNotices.notices(store: store).isEmpty)
  }

  @Test(
    "IMGMGR-250: a latched crossing made while the previous crossing's write is in flight is QUEUED, never refused into nothing"
  )
  func latchedCrossingsDuringAnInFlightMarkAreQueuedNotDropped() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(
        items: [makeImage(id: 1, revision: "r0"), makeImage(id: 2, revision: "r0")], limit: 100,
        nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.pickLock.forceLatch(.pick)
    store.beginPointerDrag()

    // One outcome for both writes, set BEFORE the hold: the stub resolves a held call's outcome
    // after it resumes, so changing it mid-test would only make the assertions ambiguous.
    await transport.setMarkStateOutcome(
      .success(
        .init(
          applied: 1, requested: 1,
          revisions: [.init(imageId: 1, revision: "r1"), .init(imageId: 2, revision: "r1")])))
    await transport.holdMarkStateRequests(true)
    async let crossingA: Void = store.pointerDragCrossed(.image(1))
    await transport.waitUntilMarkStateStarted()

    // The pointer keeps moving while that write is genuinely in flight — which is the whole
    // point of a lock, and over a VPN is the common case rather than the corner one.
    await store.pointerDragCrossed(.image(2))

    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    _ = await crossingA

    #expect(
      MarkStateValue(store.images.first(where: { $0.id == 2 })?.mark.state) == .pick,
      "the crossing made during the in-flight write was refused into nothing")
    // POSITIVE CONTROL: the first crossing — the one that was never contended — still applied,
    // so the assertion above is about the SECOND crossing rather than about marks in general.
    #expect(MarkStateValue(store.images.first(where: { $0.id == 1 })?.mark.state) == .pick)
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == 2)
    #expect(await transport.lastMarkStateRequest?.imageIds == [2])
    // Applied, not merely reported as unapplied.
    #expect(store.droppedWriteIDs.isEmpty)
  }

  @Test(
    "IMGMGR-250 (gate round 1, B1): every crossing queued during ONE lane wait coalesces into a single write with a single undo entry"
  )
  func crossingsQueuedDuringOneLaneWaitCoalesceIntoOneWrite() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(
        items: (1...3).map { makeImage(id: $0, revision: "r0") }, limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.pickLock.forceLatch(.pick)
    store.beginPointerDrag()
    await transport.setMarkStateOutcome(
      .success(
        .init(
          applied: 3, requested: 3,
          revisions: (1...3).map { .init(imageId: $0, revision: "r1") })))

    // The lane is ALREADY taken when the drag starts — the ticket's own scenario, and the one
    // where the drain has to wait rather than write straight through.
    let refresh = await holdLaneWithRefresh(store, transport)
    async let crossOne: Void = store.pointerDragCrossed(.image(1))
    await waitUntilQueuedOnLane(store)  // the drain owner is genuinely parked on the lane

    // ...and the pointer keeps moving while it waits. Both return at once: a drain is live.
    await store.pointerDragCrossed(.image(2))
    await store.pointerDragCrossed(.image(3))

    await transport.releaseListImages()
    _ = await refresh.value
    _ = await crossOne

    // ONE write. TWO would mean the first crossing dequeued itself before the wait and left the
    // rest to a second batch — whose undo entry overwrites the first's, so the very first tile
    // the reader painted becomes un-undoable while looking exactly as marked as the others.
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == 1)
    #expect(await transport.lastMarkStateRequest?.imageIds.sorted() == [1, 2, 3])
    #expect(
      store.undo.entry?.priorStates.map(\.imageID).sorted() == [1, 2, 3],
      "the undo slot does not cover every tile the one write marked")
    for id in 1...3 {
      #expect(MarkStateValue(store.images.first(where: { $0.id == id })?.mark.state) == .pick)
    }
    #expect(store.droppedWriteIDs.isEmpty)
  }

  @Test(
    "IMGMGR-250 (gate round 1, B2): a crossing whose query changed DURING the lane wait is discarded — never written into the new scope, never reported dropped"
  )
  func aCrossingWhoseScopeChangedDuringTheLaneWaitIsDiscarded() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(
        items: [makeImage(id: 1, revision: "r0"), makeImage(id: 2, revision: "r0")], limit: 100,
        nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.pickLock.forceLatch(.pick)
    store.beginPointerDrag()
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))

    let refresh = await holdLaneWithRefresh(store, transport)
    async let crossOne: Void = store.pointerDragCrossed(.image(1))
    await waitUntilQueuedOnLane(store)

    // The reader leaves the scope while that crossing is still parked. A filter change does not
    // take the lane, so it lands squarely INSIDE the wait — and its reload leaves id 1 loaded, so
    // a write into the new scope would genuinely go out rather than being stopped by absence.
    await store.applyFilterChange { $0.mark = "pick" }
    #expect(store.images.map(\.id) == [1, 2])  // POSITIVE CONTROL: writable HERE, if anything asked

    await transport.releaseListImages()
    _ = await refresh.value
    _ = await crossOne

    // A crossing describes a photograph in the query it was made in. That query is gone, so the
    // crossing goes with it: nothing is written into a scope the reader never painted...
    #expect(await transport.callCount(Operations.SetMarkStateApiMarksStatePost.id) == 0)
    #expect(await transport.lastMarkStateRequest == nil)
    #expect(MarkStateValue(store.images.first(where: { $0.id == 1 })?.mark.state) == .none)
    // ...and no "couldn't write this" notice either. It was not dropped, it was abandoned, and
    // saying otherwise would put a warning on every scope change made mid-drag.
    #expect(store.droppedWriteIDs.isEmpty)
  }

  @Test(
    "IMGMGR-204 (gate round 1, B4): a SUCCESSFUL refresh of the same scope clears the dropped-write notice — it names photographs from a window that no longer stands"
  )
  func aSuccessfulRefreshOfTheSameScopeClearsTheDroppedWriteNotice() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(
        items: [makeImage(id: 1, revision: "r0"), makeImage(id: 2, revision: "r0")], limit: 100,
        nextCursor: nil))
    await store.selectShoot(folderID: 1)

    // Earn a real notice, exactly the way IMGMGR-204's own test earns one.
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 2, revision: "r0")], limit: 200, nextCursor: nil))
    let refresh = await holdLaneWithRefresh(store, transport)
    await transport.setTagsOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 2, revision: "r1")])))
    async let tagCall: Void = store.addTag("landscape", to: [1, 2])
    await waitUntilQueuedOnLane(store)
    await transport.releaseListImages()
    _ = await refresh.value
    _ = await tagCall
    // POSITIVE CONTROL: the notice really is standing before the refresh below.
    #expect(store.droppedWriteIDs == [1])

    await store.authoritativeRefresh()

    // A refresh republishes the very window the notice was naming photographs from. Same shoot,
    // so `reloadFirstPage`'s own clear never runs — without this the notice outlives the state it
    // describes and the reader is warned about a set that is no longer on screen.
    #expect(store.droppedWriteIDs.isEmpty)
    #expect(GridNotices.notices(store: store).isEmpty)
  }

  @Test(
    "IMGMGR-251: a failed rows fetch never lets FRESH group headers publish over the abandoned query's photographs"
  )
  func aFailedRowsFetchSuppressesTheNewQuerysGroupHeaders() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1), makeImage(id: 2)], limit: 100, nextCursor: nil))
    await transport.setImageGroupsResult(
      .init(
        costHint: .standard, groupBy: .camera,
        headers: [.init(count: 2, key: "FUJIFILM X-T2", label: "FUJIFILM X-T2")],
        timezone: nil, total: 2))
    await store.selectShoot(folderID: 1)
    await store.selectGrouping(.key(.camera))
    // POSITIVE CONTROL: this scope really is vouched and sectioned before the failure below.
    #expect(store.groupHeaders[.known("FUJIFILM X-T2")]?.count == 2)
    #expect(store.images.map(\.id) == [1, 2])

    // The scope moves. `/api/images` fails for the NEW query while `/api/image-groups` succeeds
    // for it — the narrow partial-failure window the ticket describes.
    await transport.setImageGroupsResult(
      .init(
        costHint: .standard, groupBy: .camera,
        headers: [.init(count: 989, key: "SONY ILCE-7RM5", label: "SONY ILCE-7RM5")],
        timezone: nil, total: 989))
    await transport.setListImagesShouldFail(true)
    await store.applyFilterChange { $0.mark = "pick" }

    // The rows on screen are the ABANDONED query's — kept deliberately rather than blanked...
    #expect(store.images.map(\.id) == [1, 2])
    // ...so nothing may vouch the new query's sections over them.
    #expect(
      store.groupHeaders.isEmpty,
      "headers vouched for the new query published over the abandoned query's photographs")
    #expect(store.groupTimezone == nil)
    #expect(
      store.groupHeadersIdentity != store.currentQuery,
      "the new query was vouched for even though its rows never arrived")
    // And the failed reload is a state the reader is actually told about — `lastPageLoadError`
    // had no rendering consumer anywhere in the app sources before this.
    #expect(store.lastPageLoadError != nil)
    #expect(GridNotices.notices(store: store).contains(.pageLoadFailed))
  }

  @Test(
    "IMGMGR-251: a later SUCCESSFUL reload of that same query publishes its sections normally — the fix is a gate, not a permanent refusal"
  )
  func headersReturnOnTheNextSuccessfulReloadOfTheSameQuery() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1), makeImage(id: 2)], limit: 100, nextCursor: nil))
    await transport.setImageGroupsResult(
      .init(
        costHint: .standard, groupBy: .camera,
        headers: [.init(count: 989, key: "SONY ILCE-7RM5", label: "SONY ILCE-7RM5")],
        timezone: "Europe/Zurich", total: 989))
    await store.selectShoot(folderID: 1)
    await store.selectGrouping(.key(.camera))

    // `setListImagesShouldFail` is self-disarming: this reload fails, the retry below does not.
    await transport.setListImagesShouldFail(true)
    await store.applyFilterChange { $0.mark = "pick" }
    #expect(store.lastPageLoadError != nil)

    await store.fullReload()

    #expect(store.lastPageLoadError == nil)
    #expect(store.groupHeaders[.known("SONY ILCE-7RM5")]?.count == 989)
    #expect(store.groupTimezone == "Europe/Zurich")
    #expect(store.groupHeadersIdentity == store.currentQuery)
    #expect(GridNotices.notices(store: store).isEmpty)
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
    async let markTask: Bool = store.applyMark(.pick, to: [1])
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
    async let markTask: Bool = store.applyMark(.pick, to: [1])
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
        ext: "jpg", fileSize: 4_096, filename: "vanished.jpg", folderId: 1, id: 1,
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
    async let markCall: Bool = store.applyMark(.pick, to: [1])
    await transport.waitUntilMarkStateStarted()

    // The scope change lands and completes WHILE the mark request is still suspended --
    // selectShoot never touches the mutation lane, so nothing here queues behind it.
    await transport.setListImagesPage(.init(items: [], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)

    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    _ = await markCall

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
    async let markCall: Bool = store.applyMark(.pick, to: [1])
    await transport.waitUntilMarkStateStarted()

    await transport.setListImagesPage(.init(items: [], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)

    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    _ = await markCall

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

  // MARK: - WP13 P5b (IMGMGR-221 part 2): sort, grouping and ADR-0005 decision 6

  @Test("Changing the sort restarts paging from page one and resets selection")
  func changingSortRestartsPagingAndResetsSelection() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: "page-2-token"))
    await store.selectShoot(folderID: 1)
    store.selection.enterSelectExplicitly()
    store.selection.toggle(1)
    store.focusedImageID = 1
    #expect(store.nextCursor == "page-2-token")

    await store.setSortKey(.rating)

    // The server puts `sort`, `direction` and `group_by` INSIDE the cursor fingerprint
    // (live-probed 2026-08-30: a cross-sort replay is refused `400 cursor_scope_mismatch`), so
    // the only safe response to a sort change is to restart. The client therefore must never
    // send the old cursor with the new sort.
    let sent = await transport.lastListImagesQuery
    #expect(sent?["sort"] == "rating")
    #expect(sent?["cursor"] == nil, "the sort change replayed a cursor from the old scope")
    #expect(store.selection.mode == .browse)
    #expect(store.selection.members.isEmpty)
    #expect(store.focusedImageID == nil)
    #expect(store.activeSortKey == .rating)
  }

  @Test("Setting a group key fetches /api/image-groups under the IDENTICAL filters")
  func settingAGroupKeyFetchesImageGroupsUnderTheIdenticalFilters() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await transport.setImageGroupsResult(
      .init(
        costHint: .standard, groupBy: .camera,
        headers: [.init(count: 280, key: "FUJIFILM X-T2", label: "FUJIFILM X-T2")],
        timezone: nil, total: 280))
    await store.selectShoot(folderID: 1)
    await store.applyFilterChange { $0.mark = "pick" }

    await store.selectGrouping(.key(.camera))

    let page = await transport.lastListImagesQuery
    let groups = await transport.lastImageGroupsQuery
    #expect(groups != nil, "no /api/image-groups request was made at all")
    // A header that describes a DIFFERENT filter scope than the page it labels is a lie about
    // the photographs on screen — so every filter field must match, field for field.
    for field in [
      "folder_id", "rating_min", "good", "label", "keyword", "q", "tag", "source_tier", "tree",
      "ext", "has_master", "mark", "date_from", "date_to", "camera_preview_only", "missing",
      "group_by",
    ] {
      let pageValue = String(describing: page?[field])
      let groupsValue = String(describing: groups?[field])
      #expect(
        page?[field] == groups?[field],
        "page and headers disagree on \(field): \(pageValue) vs \(groupsValue)")
    }
    // POSITIVE CONTROL: the two fields that MUST agree and are not defaults did travel.
    #expect(groups?["group_by"] == "camera")
    #expect(groups?["mark"] == "pick")
    // The published lookup is the server's, keyed so a tile's own `group_key` finds it.
    #expect(store.groupHeaders[.known("FUJIFILM X-T2")]?.count == 280)
    #expect(store.groupHeaders.count == 1)
  }

  @Test("Clearing the grouping drops the headers rather than leaving stale sections standing")
  func clearingTheGroupingDropsTheHeaders() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await transport.setImageGroupsResult(
      .init(
        costHint: .standard, groupBy: .camera,
        headers: [.init(count: 280, key: "FUJIFILM X-T2", label: "FUJIFILM X-T2")],
        timezone: nil, total: 280))
    await store.selectShoot(folderID: 1)
    await store.selectGrouping(.key(.camera))
    #expect(!store.groupHeaders.isEmpty)

    await store.selectGrouping(.none)

    #expect(store.groupHeaders.isEmpty)
    #expect(store.currentQuery.groupBy == nil)
    #expect(store.activeGrouping == .none)
  }

  @Test("Entering Scene mode suspends and leaving restores the EXACT sort/group presentation")
  func enteringSceneModeSuspendsAndLeavingRestoresTheExactSortGroupPresentation() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    await store.setSortKey(.rating)
    await store.setSortDirection(.desc)
    await store.selectGrouping(.key(.camera))
    let before = SortGroupPresentation(of: store.currentQuery)
    #expect(before == SortGroupPresentation(sort: "rating", direction: "desc", groupBy: "camera"))

    await store.setDisplayMode(.scene)

    // SUSPENDED, not merely remembered: `/api/browse/stacks` accepts none of the three
    // (ADR-0005 decision 1), so they must be off the query while Scene is on — and the stacks
    // request the mode switch made must carry neither.
    #expect(store.currentQuery.sort == nil)
    #expect(store.currentQuery.direction == nil)
    #expect(store.currentQuery.groupBy == nil)
    let stacks = await transport.lastBrowseStacksQuery
    #expect(stacks?["sort"] == nil)
    #expect(stacks?["group_by"] == nil)
    #expect(stacks?["folder_id"] == "1")  // positive control: the filters DID travel

    await store.setDisplayMode(.flat)

    #expect(SortGroupPresentation(of: store.currentQuery) == before)
    let page = await transport.lastListImagesQuery
    #expect(page?["sort"] == "rating")
    #expect(page?["direction"] == "desc")
    #expect(page?["group_by"] == "camera")
  }

  @Test("Choosing Scene suspends the sort/group presentation and leaving restores it")
  func choosingSceneSuspendsTheSortGroupPresentationAndLeavingRestoresIt() async {
    // The same rule as above, driven through the MENU's own single entry point rather than
    // through `setDisplayMode` — the coordinator is what every Group row actually calls.
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    await store.setSortKey(.filename)
    await store.selectGrouping(.key(.lens))
    #expect(store.activeGrouping == .key(.lens))

    await store.selectGrouping(.scene)
    #expect(store.displayMode == .scene)
    #expect(store.activeGrouping == .scene)
    #expect(store.currentQuery.groupBy == nil)
    #expect(store.currentQuery.sort == nil)

    // A filter edited WHILE Scene is on survives the way back — it says WHICH photographs, not
    // how they are arranged, so it is not part of the suspended presentation.
    await store.applyFilterChange { $0.mark = "pick" }

    await store.selectGrouping(.key(.lens))
    #expect(store.displayMode == .flat)
    #expect(store.currentQuery.sort == "filename")
    #expect(store.currentQuery.groupBy == "lens")
    #expect(store.currentQuery.mark == "pick")
  }

  @Test("Choosing a group key while Scene is active LEAVES Scene and applies the key")
  func choosingAGroupKeyWhileSceneIsActiveLeavesSceneAndAppliesTheKey() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    await store.setDisplayMode(.scene)
    #expect(store.displayMode == .scene)

    await store.selectGrouping(.key(.camera))

    // `applyFilterChange` alone would have left `displayMode == .scene` and the chosen row
    // would visibly have done nothing — `browseStacks` carries no `group_by` at all. This is
    // the gate's round-1 BLOCKING finding, asserted.
    #expect(store.displayMode == .flat)
    #expect(store.currentQuery.groupBy == "camera")
    #expect(store.activeGrouping == .key(.camera))
    let page = await transport.lastListImagesQuery
    #expect(page?["group_by"] == "camera")

    // And the other direction: choosing Scene while a key is active leaves the key behind.
    await store.selectGrouping(.scene)
    #expect(store.displayMode == .scene)
    #expect(store.currentQuery.groupBy == nil)
    #expect(store.activeGrouping == .scene)
  }

  // MARK: - Diff-gate r1 blockers

  @Test("A failed header fetch after a filter change renders NO sections, never the old scope's")
  func aFailedHeaderFetchAfterAFilterChangeRendersNoStaleSections() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1), makeImage(id: 2)], limit: 100, nextCursor: nil))
    await transport.setImageGroupsResult(
      .init(
        costHint: .standard, groupBy: .camera,
        headers: [.init(count: 36568, key: "SONY ILCE-7RM5", label: "SONY ILCE-7RM5")],
        timezone: "Europe/Zurich", total: 36568))
    await store.selectShoot(folderID: 1)
    await store.selectGrouping(.key(.camera))
    // POSITIVE CONTROL: the server DID vouch for this scope, so the emptiness below is the
    // identity gate doing its job rather than a header fetch that never happened.
    #expect(store.groupHeaders.count == 1)
    #expect(store.groupTimezone == "Europe/Zurich")

    // The scope moves AND the header fetch for the new scope fails.
    await transport.setImageGroupsShouldFail(true)
    await store.applyFilterChange { $0.mark = "pick" }

    // A header describes a filter scope. Rendering the previous scope's label, count and
    // timezone over the new photographs states something false about what is on screen — worse
    // than stating nothing, which is what an unvouched scope gets.
    #expect(store.groupHeaders.isEmpty, "the previous scope's headers survived a failed fetch")
    #expect(store.groupTimezone == nil, "the previous scope's timezone survived a failed fetch")

    // ...and the photographs themselves still render, unsectioned. Absence of a header is never
    // absence of a photograph.
    let rendered = GridSectionLayout.renderRows(
      rows: store.images.map(SceneDisplayRow.image),
      groupBy: store.activeGrouping.groupByKey,
      headers: store.groupHeaders, timezone: store.groupTimezone,
      paneWidth: 800, targetRowHeight: 200, displayScale: 2,
      availability: { _, _ in .ok(width: 4000, height: 4000) })
    #expect(rendered.allSatisfy { $0.packedRow != nil }, "a section header rendered unvouched")
    #expect(GridSectionLayout.navigationRows(rendered).flatMap { $0 }.count == 2)
  }

  @Test("Returning to a vouched scope shows its sections again, and does not refetch them")
  func returningToAVouchedScopeShowsItsSectionsAgain() async {
    // The other half of the rule, so the fix reads as a GATE on identity rather than as
    // "destroy everything the moment anything fails": headers the server vouched for a query
    // are still that query's answer when the reader comes back to it.
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await transport.setImageGroupsResult(
      .init(
        costHint: .standard, groupBy: .camera,
        headers: [.init(count: 280, key: "FUJIFILM X-T2", label: "FUJIFILM X-T2")],
        timezone: nil, total: 280))
    await store.selectShoot(folderID: 1)
    await store.selectGrouping(.key(.camera))
    #expect(store.groupHeaders.count == 1)
    let afterVouching = await transport.callCount(Operations.ImageGroupsApiImageGroupsGet.id)

    // Away, where the header fetch fails: nothing is published for the new scope.
    await transport.setImageGroupsShouldFail(true)
    await store.applyFilterChange { $0.mark = "pick" }
    #expect(store.groupHeaders.isEmpty)

    // ...and back.
    await store.applyFilterChange { $0.mark = nil }

    #expect(store.groupHeaders[.known("FUJIFILM X-T2")]?.count == 280)
    // Idempotent per identity: coming back to an already-vouched query costs no request.
    let afterReturning = await transport.callCount(Operations.ImageGroupsApiImageGroupsGet.id)
    #expect(
      afterReturning == afterVouching + 1,
      "the return trip refetched a scope the server had already vouched for")
  }

  @Test("Choosing a sort key while Scene is active LEAVES Scene and applies the key")
  func choosingASortKeyWhileSceneIsActiveLeavesSceneAndAppliesTheKey() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    await store.setSortKey(.filename)
    await store.setDisplayMode(.scene)
    #expect(store.displayMode == .scene)
    // The control tells the truth in Scene mode: the presentation is suspended, not forgotten.
    #expect(store.activeSortKey == .filename)

    await store.setSortKey(.rating)

    // Scene reloads through `browseStacks`, which ignores sort/direction/group_by by contract
    // (ADR-0005 decision 1) — so a sort chosen here and left in Scene would be enabled and
    // inert, and leaving Scene would then restore the suspension over it.
    #expect(store.displayMode == .flat, "a sort choice left the reader in Scene, where it is inert")
    #expect(store.currentQuery.sort == "rating")
    #expect(store.activeSortKey == .rating)
    #expect(store.suspendedPresentation == nil, "the suspension outlived the choice it would undo")
    let page = await transport.lastListImagesQuery
    #expect(page?["sort"] == "rating")
  }

  @Test("Choosing a sort DIRECTION while Scene is active LEAVES Scene and applies it")
  func choosingASortDirectionWhileSceneIsActiveLeavesSceneAndAppliesIt() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    await store.setSortKey(.rating)
    await store.setDisplayMode(.scene)
    #expect(store.displayMode == .scene)

    await store.setSortDirection(.desc)

    #expect(store.displayMode == .flat)
    #expect(store.currentQuery.direction == "desc")
    // The suspended sort key came back with it — leaving Scene restores the presentation, and
    // the direction is applied ON TOP of it rather than onto a cleared query.
    #expect(store.currentQuery.sort == "rating")
    #expect(store.activeDirection == .desc)
    let page = await transport.lastListImagesQuery
    #expect(page?["direction"] == "desc")
    #expect(page?["sort"] == "rating")
  }

  @Test("⌥⌘R in Scene mode reverses the SUSPENDED direction, not the cleared query's default")
  func togglingDirectionInSceneModeReversesTheSuspendedDirection() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    await store.setSortDirection(.desc)
    await store.setDisplayMode(.scene)
    // While Scene is on the query carries no direction at all, so a toggle that read the QUERY
    // would see the `asc` default and "reverse" it to `desc` — the value already in force.
    #expect(store.currentQuery.direction == nil)
    #expect(store.activeDirection == .desc)

    await store.toggleSortDirection()

    #expect(store.displayMode == .flat)
    #expect(store.currentQuery.direction == "asc")
    #expect(store.activeDirection == .asc)
  }

  @Test("Grouping is single-select: activeGrouping is never Scene AND a key at once")
  func groupingIsNeverSceneAndAKeyAtOnce() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    for choice in SortGroupOptions.groupingChoices {
      await store.selectGrouping(choice)
      #expect(store.activeGrouping == choice, "selectGrouping(\(choice)) did not take effect")
      // The invariant, stated as the two facts that cannot both hold: Scene mode with a
      // `group_by` on the query, or a key chosen while the stacks endpoint is being paged.
      #expect(!(store.displayMode == .scene && store.currentQuery.groupBy != nil))
    }
  }
}

/// WP13 P1 (IMGMGR-212, and the shipped defect IMGMGR-223 it closes): Select mode stops being a
/// tagging-only mode. Every test here drives a REAL loaded page through `GridStubTransport` and
/// reads what the generated client actually put on the wire — an assertion about
/// `markTargetImageIDs` alone would pass just as well if no control consumed it.
@MainActor
@Suite("GridStore — bulk marks consume the selection set (WP13 P1)")
struct GridStoreBulkMarkTests {

  private func makeImage(
    id: Int, mark: Components.Schemas.MarkView.StatePayload = .none, revision: String = "r0"
  ) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: revision, state: mark, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStore() -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    return (GridStore(service: GridService(client: client)), transport)
  }

  private func loadedStore(_ images: [Components.Schemas.ImageSummary]) async -> (
    GridStore, GridStubTransport
  ) {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: images, limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    return (store, transport)
  }

  private var markStateOperation: String { Operations.SetMarkStateApiMarksStatePost.id }
  private var tagsOperation: String { Operations.EditMarkTagsApiMarksTagsPost.id }

  // MARK: - The whole selection, in the actionable order

  @Test(
    "Bulk Pick from the action bar writes EVERY selected id, ordered by actionableImages position"
  )
  func bulkPickAppliesToEveryOrderedSelectionMember() async {
    // Loaded in an order that is neither ascending nor the tap order below, so the assertion
    // pins the ACTIONABLE order specifically — not "sorted", and not a Set's own iteration
    // order, which is unspecified and would reach the wire and the undo entry.
    let (store, transport) = await loadedStore(
      [makeImage(id: 40), makeImage(id: 10), makeImage(id: 30), makeImage(id: 20)])
    store.enterSelectExplicitly()
    await store.tapTile(20)
    await store.tapTile(40)
    await store.tapTile(30)
    await store.tapTile(10)

    await transport.setMarkStateOutcome(
      .success(
        .init(
          applied: 4, requested: 4,
          revisions: [
            .init(imageId: 40, revision: "r1"), .init(imageId: 10, revision: "r1"),
            .init(imageId: 30, revision: "r1"), .init(imageId: 20, revision: "r1"),
          ])))
    await store.activateLatchButton(.pick)

    let sent = await transport.lastMarkStateRequest
    #expect(sent?.imageIds == [40, 10, 30, 20])
    #expect(sent?.preconditions?.map(\.imageId) == [40, 10, 30, 20])
    #expect(sent?.state == .pick)
    // ONE call through the shipped multi-id lane, never a loop of single-id writes.
    #expect(await transport.callCount(markStateOperation) == 1)
    #expect(store.images.allSatisfy { $0.mark.state == .pick })
  }

  @Test("P/X/U in Select mode mark the whole selection, never the focused photograph")
  func shortcutsMarkTheWholeSelectionInSelectMode() async {
    let (store, transport) = await loadedStore(
      [makeImage(id: 5), makeImage(id: 6), makeImage(id: 7)])
    await store.tapTile(5)  // browse: a real focus, deliberately NOT part of the selection
    store.enterSelectExplicitly()
    await store.tapTile(6)
    await store.tapTile(7)
    #expect(store.focusedImageID == 5)

    await transport.setMarkStateOutcome(.success(.init(applied: 2, requested: 2, revisions: [])))

    // ALL THREE, not one: a focused-id regression in P or U would hide behind a correct X, and
    // each shortcut has its own guard and its own state argument to get wrong.
    await store.handlePickShortcut(shiftHeld: false)
    var sent = await transport.lastMarkStateRequest
    #expect(sent?.imageIds == [6, 7])
    #expect(sent?.state == .pick)

    await store.handleDislikeShortcut(shiftHeld: false)
    sent = await transport.lastMarkStateRequest
    #expect(sent?.imageIds == [6, 7])
    #expect(sent?.state == .dislike)

    await store.handleClearShortcut(shiftHeld: false)
    sent = await transport.lastMarkStateRequest
    let clearState = Components.Schemas.MarkStateRequest.StatePayload.none
    #expect(sent?.imageIds == [6, 7])
    #expect(sent?.state == clearState)

    // One call per shortcut, never a per-id loop; and the focused photograph is untouched by
    // all three.
    #expect(await transport.callCount(markStateOperation) == 3)
    #expect(store.focusedImageID == 5)
  }

  @Test("Clear from the grid bar applies to the whole selection")
  func clearAppliesToTheSelectionFromTheGridBar() async {
    let (store, transport) = await loadedStore(
      [makeImage(id: 7, mark: .pick), makeImage(id: 8, mark: .dislike)])
    store.enterSelectExplicitly()
    await store.tapTile(8)
    await store.tapTile(7)

    await transport.setMarkStateOutcome(.success(.init(applied: 2, requested: 2, revisions: [])))
    // Written through the SAME table the bar's Clear button renders and acts from, so a button
    // wired to the wrong state fails HERE rather than shipping green: this test asserts the
    // wire carries `none`, and `ActionBarMarkControl.clear.state` is the only declaration of
    // what that control writes. That the button EXISTS and reaches the mark lane at all is the
    // rendered half, in `SelectModeScreenshotUITests.testClearControlInTheGridBarDrivesTheMarkLane`.
    await store.applyMarkToTarget(ActionBarMarkControl.clear.state)

    let sent = await transport.lastMarkStateRequest
    // Type-qualified: a bare `.none` here matches `Optional.none`, not the wire state.
    let clearState = Components.Schemas.MarkStateRequest.StatePayload.none
    #expect(sent?.state == clearState)
    #expect(sent?.imageIds == [7, 8])
    let noneMark = Components.Schemas.MarkView.StatePayload.none
    #expect(store.images.allSatisfy { $0.mark.state == noneMark })
  }

  @Test("Outside Select mode the target is the focused photograph, and only it")
  func markTargetIsTheFocusedImageOutsideSelectMode() async {
    let (store, transport) = await loadedStore(
      [makeImage(id: 1), makeImage(id: 2), makeImage(id: 3)])
    await store.tapTile(2)

    #expect(store.selection.mode == .browse)
    #expect(store.markTargetImageIDs == [2])

    await transport.setMarkStateOutcome(.success(.init(applied: 1, requested: 1, revisions: [])))
    await store.applyMarkToTarget(.pick)

    let sent = await transport.lastMarkStateRequest
    #expect(sent?.imageIds == [2])
    #expect(await transport.callCount(markStateOperation) == 1)
  }

  // MARK: - Undo, and the actionable-only write boundary

  @Test("One undo entry covers every member and restores each to its OWN prior state")
  func bulkMarkRetainsSelectionAndRecordsOneUndoEntryCoveringEveryMember() async {
    // DIFFERENT priors per member on purpose: an implementation that restores them all to one
    // state (the entry's `appliedState`, or the first prior it sees) passes a same-prior fixture.
    let (store, transport) = await loadedStore([
      makeImage(id: 1, mark: .pick, revision: "r1"),
      makeImage(id: 2, mark: .dislike, revision: "r2"),
      makeImage(id: 3, mark: .none, revision: "r3"),
    ])
    store.enterSelectExplicitly()
    await store.tapTile(1)
    await store.tapTile(2)
    await store.tapTile(3)

    await transport.setMarkStateOutcome(
      .success(
        .init(
          applied: 3, requested: 3,
          revisions: [
            .init(imageId: 1, revision: "s1"), .init(imageId: 2, revision: "s2"),
            .init(imageId: 3, revision: "s3"),
          ])))
    await store.applyMarkToTarget(.dislike)

    #expect(store.undo.entry?.priorStates.count == 3)
    #expect(store.undo.entry?.appliedState == .dislike)
    #expect(store.undo.entry?.priorStates.map(\.state) == [.pick, .dislike, MarkStateValue.none])
    // A successful bulk action RETAINS the selection for a second bulk action.
    #expect(store.selection.mode == .select)
    #expect(store.selection.members == [1, 2, 3])

    await transport.setMarkStateOutcome(.success(.init(applied: 3, requested: 3, revisions: [])))
    await store.undoLastMark()

    let noneMark = Components.Schemas.MarkView.StatePayload.none
    #expect(store.images.first { $0.id == 1 }?.mark.state == .pick)
    #expect(store.images.first { $0.id == 2 }?.mark.state == .dislike)
    #expect(store.images.first { $0.id == 3 }?.mark.state == noneMark)
    #expect(!store.undo.canUndo)
  }

  @Test("A selected id that is no longer actionable never reaches the wire")
  func bulkMarkExcludesAMemberThatIsNoLongerActionable() async {
    let (store, transport) = await loadedStore(
      [makeImage(id: 1), makeImage(id: 2), makeImage(id: 3)])
    store.enterSelectExplicitly()
    await store.tapTile(1)
    await store.tapTile(2)
    await store.tapTile(3)

    // A real, reachable state: the refreshed window no longer holds 3, and the FLAT refresh
    // publishes the smaller window without pruning the selection (only Scene's refresh prunes
    // today). So a selected id genuinely outlives its own actionability here, which is exactly
    // what the actionable-only filter on the write target exists for.
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1), makeImage(id: 2)], limit: 100, nextCursor: nil))
    #expect(await store.authoritativeRefresh())
    #expect(store.selection.members == [1, 2, 3])
    #expect(store.markTargetImageIDs == [1, 2])

    await transport.setMarkStateOutcome(.success(.init(applied: 2, requested: 2, revisions: [])))
    await store.applyMarkToTarget(.pick)

    let sent = await transport.lastMarkStateRequest
    #expect(sent?.imageIds == [1, 2])
    #expect(sent?.preconditions?.map(\.imageId) == [1, 2])
  }

  // MARK: - The empty Select (IMGMGR-223)

  @Test("An empty Select is an empty target: Pick, Dislike, Clear and Tag all write NOTHING")
  func anEmptySelectionIsAnEmptyTargetAndWritesNothing() async {
    let (store, transport) = await loadedStore([makeImage(id: 1), makeImage(id: 2)])
    await store.tapTile(1)  // a focused photograph IS present — the one a fallback would take
    #expect(store.focusedImageID == 1)

    store.enterSelectExplicitly()  // ... and an explicit Select starts EMPTY
    #expect(store.selection.members.isEmpty)
    #expect(store.markTargetImageIDs.isEmpty)
    #expect(store.tagTargetImageIDs.isEmpty)

    await store.activateLatchButton(.pick)
    await store.applyMarkToTarget(.dislike)
    await store.applyMarkToTarget(.none)
    await store.handlePickShortcut(shiftHeld: false)
    await store.handleClearShortcut(shiftHeld: false)
    store.handleTagShortcut()

    #expect(await transport.callCount(markStateOperation) == 0)
    #expect(await transport.callCount(tagsOperation) == 0)
    #expect(!store.isTagEntryPresented)
    #expect(!store.undo.canUndo)
    let noneMark = Components.Schemas.MarkView.StatePayload.none
    #expect(store.images.allSatisfy { $0.mark.state == noneMark })

    // Positive control, in this SAME test: with one member selected the very same controls
    // record exactly one mutation — a transport recorder that never sees anything at all
    // cannot pass the zero-assertions above vacuously.
    await store.tapTile(2)
    #expect(store.markTargetImageIDs == [2])
    await transport.setMarkStateOutcome(.success(.init(applied: 1, requested: 1, revisions: [])))
    await store.activateLatchButton(.pick)
    #expect(await transport.callCount(markStateOperation) == 1)
    let sent = await transport.lastMarkStateRequest
    #expect(sent?.imageIds == [2])
  }

  @Test("An empty Select disables every mark control, and the row still states the count")
  func anEmptySelectionDisablesTheMarkControlsAndShowsZeroSelected() async {
    let (store, _) = await loadedStore([makeImage(id: 1), makeImage(id: 2)])
    await store.tapTile(1)
    store.enterSelectExplicitly()

    #expect(store.selectedCount == 0)
    #expect(SelectCopy.caption(selectedCount: store.selectedCount) == "0 selected")
    #expect(store.isMarkActionUnavailable)
    #expect(store.isLatchControlDisabled)

    // Positive control: one member and every control is live again, with an honest count.
    await store.tapTile(2)
    #expect(store.selectedCount == 1)
    #expect(SelectCopy.caption(selectedCount: store.selectedCount) == "1 selected")
    #expect(!store.isMarkActionUnavailable)
    #expect(!store.isLatchControlDisabled)

    // BROWSE with nothing focused is a different case on purpose: there is nothing to write to,
    // but each latch control also owns its own lock entry (a latched tap acts on the tile it
    // lands on), so BOTH stay live there. WP13 P2: Dislike joined Pick under this rule — under
    // the old one it was disabled here, and its double tap could never reach the latch machine.
    let (fresh, _) = makeStore()
    #expect(fresh.markTargetImageIDs.isEmpty)
    #expect(fresh.isMarkActionUnavailable)
    #expect(!fresh.isLatchControlDisabled)
  }

  @Test("Tag obeys the same empty-Select rule as the marks (the shipped-defect guard)")
  func tagTargetObeysTheSameEmptySelectRuleAsMarkTarget() async {
    let (store, _) = await loadedStore(
      [makeImage(id: 1), makeImage(id: 2), makeImage(id: 3)])
    await store.tapTile(1)
    store.enterSelectExplicitly()

    #expect(store.tagTargetImageIDs.isEmpty)
    #expect(store.tagTargetImageIDs == store.markTargetImageIDs)
    store.handleTagShortcut()
    #expect(!store.isTagEntryPresented)

    // And once there IS a selection, the tag target is the mark target — same ids, same order.
    await store.tapTile(3)
    await store.tapTile(2)
    #expect(store.tagTargetImageIDs == [2, 3])
    #expect(store.tagTargetImageIDs == store.markTargetImageIDs)
    store.handleTagShortcut()
    #expect(store.isTagEntryPresented)
  }
}

/// WP13 P1, diff-gate rounds 1 and 5. Adding Clear made the action bar SIX controls, and six
/// 44-pt controls at the shipped 24-pt rhythm do not fit an iPhone (416 pt against 402). The
/// iPad landscape leg then showed the roomy 376-pt layout does not fit the Regular-3 GRID COLUMN
/// either — the middle column of a three-pane split whose width this app never pins. So the
/// bar no longer bets on a width: `ActionBarMetrics.layout(forWidth:)` picks a tier for the
/// width it is handed, and every number below comes from that type, which is what
/// `ActionBarView` lays out with.
@Suite("Grid action bar geometry (the bar must fit the column it is given)")
struct ActionBarMetricsTests {

  /// IMGMGR-475 added Tap to Pick beside Pick: seven controls at rest, which the 402-pt iPhone
  /// fits at the TIGHT rhythm (the roomy one needs 436).
  @Test("Seven 44-pt controls fit the narrowest Compact width at the tight rhythm")
  func sevenControlsFitTheNarrowestCompactWidth() {
    #expect(ActionBarMetrics.controlCount == 7)
    #expect(ActionBarMetrics.minimumControlSide == 44)
    #expect(ActionBarMetrics.unfoldedFloor <= ActionBarMetrics.narrowestCompactWidth)
    let compact = ActionBarMetrics.layout(forWidth: ActionBarMetrics.narrowestCompactWidth)
    #expect(compact.name == "tight")
    #expect(!compact.foldsClearIntoMore)
    #expect(compact.spacing == ActionBarMetrics.tightSpacing)
  }

  @Test("The MEASURED Regular-3 column still takes a Compact tier: folded at the narrowest gap")
  func theMeasuredRegular3ColumnFoldsClearIntoMore() {
    // 315 pt, derived from the gate's own landscape geometry attachment rather than assumed —
    // see `ActionBarMetrics.measuredRegular3GridColumn`. Seven controls need 372 even at the
    // tight rhythm, and the folded six need 320 at it, so only the narrowest gap fits.
    #expect(ActionBarMetrics.unfoldedFloor > ActionBarMetrics.measuredRegular3GridColumn)
    #expect(ActionBarMetrics.foldedFloor <= ActionBarMetrics.measuredRegular3GridColumn)
    let column = ActionBarMetrics.layout(forWidth: ActionBarMetrics.measuredRegular3GridColumn)
    #expect(column.foldsClearIntoMore)
    #expect(column.name == "folded-tight")
    #expect(column.spacing == ActionBarMetrics.narrowestSpacing)
    // The window constant stays the layout's own, never a second copy of 1197.
    #expect(ActionBarMetrics.narrowestRegular3Window == LayoutResolver.regular3Threshold)
    #expect(ActionBarMetrics.measuredRegular3GridColumn < ActionBarMetrics.narrowestRegular3Window)
  }

  @Test("The rhythms that stopped fitting are pinned as executable facts, not comments")
  func theShippedRhythmsWouldNotHaveFit() {
    // Six controls: 6×44 + 5×24 + 2×16 = 416 against 402 — the Compact overflow the first diff
    // gate found; 6×44 + 5×16 + 2×16 = 376 is what the iPad landscape leg showed does NOT fit a
    // Regular-3 grid column.
    #expect(ActionBarMetrics.requiredWidth(controlCount: 6, spacing: 24) == 416)
    #expect(ActionBarMetrics.requiredWidth(controlCount: 6) == 376)
    // Seven (IMGMGR-475): 436 roomy, which no 402-pt iPhone fits — hence the tight tier there.
    #expect(ActionBarMetrics.requiredWidth() == 436)
    #expect(ActionBarMetrics.requiredWidth() > ActionBarMetrics.narrowestCompactWidth)
    #expect(ActionBarMetrics.unfoldedFloor == 372)
    #expect(ActionBarMetrics.foldedFloor == 300)
  }

  @Test("The bar tightens, then folds Clear into More, then narrows the gap, as the column narrows")
  func layoutTightensThenFoldsAsTheColumnNarrows() {
    let roomy = ActionBarMetrics.layout(forWidth: ActionBarMetrics.requiredWidth())
    #expect(roomy.name == "roomy")
    #expect(roomy.spacing == ActionBarMetrics.controlSpacing)
    #expect(roomy.horizontalPadding == ActionBarMetrics.horizontalPadding)
    #expect(!roomy.foldsClearIntoMore)

    let tight = ActionBarMetrics.layout(forWidth: ActionBarMetrics.requiredWidth() - 1)
    #expect(tight.spacing == ActionBarMetrics.tightSpacing)
    #expect(tight.horizontalPadding == ActionBarMetrics.tightHorizontalPadding)
    #expect(!tight.foldsClearIntoMore)

    let atFloor = ActionBarMetrics.layout(forWidth: ActionBarMetrics.unfoldedFloor)
    #expect(!atFloor.foldsClearIntoMore)

    let folded = ActionBarMetrics.layout(forWidth: ActionBarMetrics.unfoldedFloor - 1)
    #expect(folded.name == "folded")
    #expect(folded.foldsClearIntoMore)
    #expect(folded.spacing == ActionBarMetrics.tightSpacing)

    let foldedTight = ActionBarMetrics.layout(
      forWidth: ActionBarMetrics.requiredWidth(for: ActionBarMetrics.folded) - 1)
    #expect(foldedTight.name == "folded-tight")
    #expect(foldedTight.spacing == ActionBarMetrics.narrowestSpacing)
  }

  @Test("Every tier fits the width that selects it, with no control under 44 pt")
  func everyTierFitsTheWidthThatSelectsIt() {
    #expect(
      ActionBarMetrics.requiredWidth(
        spacing: ActionBarMetrics.tightSpacing,
        horizontalPadding: ActionBarMetrics.tightHorizontalPadding)
        == ActionBarMetrics.unfoldedFloor)
    #expect(ActionBarMetrics.foldedFloor < ActionBarMetrics.unfoldedFloor)
    // The folded tier buys exactly one control's worth of room, and buys it by MOVING the
    // control into the More menu — never by shrinking one.
    #expect(
      ActionBarMetrics.unfoldedFloor - ActionBarMetrics.requiredWidth(for: ActionBarMetrics.folded)
        == ActionBarMetrics.minimumControlSide + ActionBarMetrics.tightSpacing)
  }

  @Test("The tier list is ordered widest-first, which is the order the bar renders them in")
  func tiersAreOrderedWidestFirst() {
    // `ActionBarView` feeds these, in this order, to `ViewThatFits`, which takes the first
    // that fits the column. `layout(forWidth:)` walks the same list, so this ordering is what
    // makes the arithmetic below and the rendered result the same statement.
    let widths = ActionBarMetrics.tiers.map(ActionBarMetrics.requiredWidth(for:))
    #expect(widths == [436, 372, 320, 300])
    #expect(widths == widths.sorted(by: >))
    #expect(ActionBarMetrics.tiers.map(\.name) == ["roomy", "tight", "folded", "folded-tight"])
    #expect(
      ActionBarMetrics.tiers.filter { $0.foldsClearIntoMore }.map { $0.name }
        == ["folded", "folded-tight"])
    // Only the folded tiers drop a control, and each drops exactly one.
    #expect(
      ActionBarMetrics.tiers.map(\.controlCount) == [
        ActionBarMetrics.controlCount, ActionBarMetrics.controlCount,
        ActionBarMetrics.foldedControlCount, ActionBarMetrics.foldedControlCount,
      ])
    // The renderer branches on `foldsClearIntoMore` while the arithmetic counts `controlCount`:
    // this is the one place those two could drift, so it is asserted rather than assumed.
    #expect(
      ActionBarMetrics.tiers.allSatisfy {
        $0.controlCount
          == ($0.foldsClearIntoMore
            ? ActionBarMetrics.foldedControlCount : ActionBarMetrics.controlCount)
      })
    // Names are the ForEach identity `ActionBarView` renders the list with — they must be
    // unique or a tier would silently replace another in the rendered candidates.
    #expect(Set(ActionBarMetrics.tiers.map(\.name)).count == ActionBarMetrics.tiers.count)
  }

  /// WP29 P1 (IMGMGR-452): at Regular More is the grid bar's own item, so the action bar is
  /// five controls and never folds Clear — the measured 315-pt expanded column included.
  @Test("No Regular tier folds Clear, and the tightest Regular tier fits the 315-pt column")
  func regularTiersNeverFoldClear() {
    let regular = ActionBarMetrics.tiers(carriesMore: false)
    #expect(regular.map(\.name) == ["regular-titled", "regular-roomy", "regular-tight"])
    #expect(regular.allSatisfy { !$0.foldsClearIntoMore && !$0.carriesMore })
    #expect(regular.allSatisfy { $0.controlCount == 6 })
    let widths = regular.map(ActionBarMetrics.requiredWidth(for:))
    #expect(widths == [472, 376, 300])
    #expect(widths == widths.sorted(by: >))
    let tightest = regular[regular.count - 1]
    #expect(
      ActionBarMetrics.requiredWidth(for: tightest)
        <= ActionBarMetrics.measuredRegular3GridColumn)
    let column = ActionBarMetrics.layout(
      forWidth: ActionBarMetrics.measuredRegular3GridColumn, carriesMore: false)
    #expect(column.name == "regular-tight")
    #expect(!column.foldsClearIntoMore)
    // Narrower than any tier: the narrowest Regular tier, still without a fold.
    #expect(!ActionBarMetrics.layout(forWidth: 100, carriesMore: false).foldsClearIntoMore)
    // Names are ForEach identities — unique within the list the bar renders.
    #expect(Set(regular.map(\.name)).count == regular.count)
  }

  @Test("Compact's tiers are unchanged and every one carries More")
  func compactTiersUnchanged() {
    #expect(
      ActionBarMetrics.tiers(carriesMore: true).map(\.name)
        == ["roomy", "tight", "folded", "folded-tight"])
    #expect(ActionBarMetrics.tiers(carriesMore: true).allSatisfy { $0.carriesMore })
    #expect(
      ActionBarMetrics.layout(forWidth: ActionBarMetrics.narrowestCompactWidth)
        == ActionBarMetrics.layout(
          forWidth: ActionBarMetrics.narrowestCompactWidth, carriesMore: true))
    #expect(WorkspaceChromePlacement.actionBarCarriesMore(for: .compact))
    #expect(!WorkspaceChromePlacement.actionBarCarriesMore(for: .regular2))
    #expect(!WorkspaceChromePlacement.actionBarCarriesMore(for: .regular3))
  }

  @Test("An eighth control would not fit the tight tier — the guard covers the count too")
  func anEighthControlWouldNotFit() {
    #expect(
      ActionBarMetrics.requiredWidth(controlCount: 7) > ActionBarMetrics.narrowestCompactWidth)
    #expect(
      ActionBarMetrics.requiredWidth(
        controlCount: 8, spacing: ActionBarMetrics.tightSpacing,
        horizontalPadding: ActionBarMetrics.tightHorizontalPadding)
        > ActionBarMetrics.narrowestCompactWidth)
  }
}
