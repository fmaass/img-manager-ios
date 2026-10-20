import Foundation
import ImgManagerAPI
import SwiftUI
import Testing

@testable import ImgManager

/// WP442 P12 (IMGMGR-540): a scene card PUSHES a scene screen. One entered scene, one writer
/// (`transitionScene`), the stream never swaps a card for its members, and a topology edit made
/// inside the scene navigates only while the reader still owns that screen.
///
/// Each test names the planned mutant it kills (plan §4, `PLAN_2026-10-18_wp442-p12-scene-push`).
///
/// Fixture: one folder; the stream is loose 10, scene 5 {1, 2, 3} (cover 900), scene 6 {7, 8}
/// (cover 901), loose 11. The covers are NOT members, so a cover that leaks into the actionable
/// projection is visible as its own id.
@MainActor
@Suite("WP442 P12 — a scene card pushes a scene screen (IMGMGR-540)")
struct ScenePushTests {
  private typealias MarkPayload = Components.Schemas.MarkView.StatePayload
  private typealias Item = Components.Schemas.StackBrowsePage.ItemsPayloadPayload

  private let t0: TimeInterval = 1_700_000_000
  private let t1: TimeInterval = 1_700_003_600
  private let t2: TimeInterval = 1_700_100_000
  private let markOp = Operations.SetMarkStateApiMarksStatePost.id
  private let membersOp = Operations.ListStackMembersApiStacksStackIdMembersGet.id
  private let stackRowOp = Operations.GetStackApiStacksStackIdGet.id
  private let browseOp = Operations.BrowseStacksApiBrowseStacksGet.id

  // MARK: - Fixtures

  private func image(_ id: Int, mark: MarkPayload = MarkPayload.none)
    -> Components.Schemas.ImageSummary
  {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "raf", filename: "DSCF\(id).raf", folderId: 1, hasEdit: false,
      id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: mark, tags: []), missing: false,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func row(_ id: Int, count: Int, anchor: TimeInterval, cover: Int, picked: Int = 0)
    -> Components.Schemas.StackBrowseStackRow
  {
    Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: Date(timeIntervalSince1970: anchor), editedCount: 0, hasPick: picked > 0,
      kind: .stack, matchedCount: count, memberCount: count, pickedCount: picked,
      representative: image(cover), stackId: id)
  }

  private func scene(_ id: Int, count: Int, anchor: TimeInterval, cover: Int, picked: Int = 0)
    -> Item
  {
    .init(value1: nil, value2: row(id, count: count, anchor: anchor, cover: cover, picked: picked))
  }

  private func loose(_ id: Int) -> Item {
    .init(value1: .init(image: image(id), kind: .image), value2: nil)
  }

  private func page(_ items: [Item], next: String? = nil) -> Components.Schemas.StackBrowsePage {
    Components.Schemas.StackBrowsePage(items: items, limit: 100, nextCursor: next)
  }

  private func members(_ ids: [Int], of stackID: Int, next: String? = nil)
    -> Components.Schemas.StackMemberPage
  {
    Components.Schemas.StackMemberPage(
      items: ids.map { image($0) }, limit: 100, nextCursor: next, stackId: stackID)
  }

  private func editResult(stacks: [Int], dissolved: [Int] = [])
    -> Components.Schemas.StackEditResult
  {
    Components.Schemas.StackEditResult(
      dissolvedStackIds: dissolved, loosenedImageIds: [], stackIds: stacks)
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

  /// After a split of 5 at member 2: 5 keeps {1}, the new scene 9 holds {2, 3}.
  private var splitItems: [Item] {
    [
      loose(10), scene(5, count: 1, anchor: t0, cover: 900),
      scene(9, count: 2, anchor: t0 + 30, cover: 902),
      scene(6, count: 2, anchor: t1, cover: 901), loose(11),
    ]
  }

  private func makeStore() -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    return (GridStore(service: GridService(client: client)), transport)
  }

  private func sceneStore() async -> (GridStore, GridStubTransport) {
    let (store, transport) = makeStore()
    await transport.setBrowseStacksPage(page(streamItems))
    await transport.setStackMemberPage(members([1, 2, 3], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([7, 8], of: 6), forStack: 6)
    await store.selectShoot(folderID: 1)
    await store.setDisplayMode(.scene)
    return (store, transport)
  }

  /// Scene 5 entered, the focus on its SECOND member (a split there is legal).
  private func enteredStore() async -> (GridStore, GridStubTransport) {
    let (store, transport) = await sceneStore()
    await store.enterScene(5)
    store.focusedImageID = 2
    return (store, transport)
  }

  private func shown(_ store: GridStore, _ scope: GridScope) -> [GridDisplayID] {
    store.displayRows(for: scope).map(\.id)
  }

  private func markRequests(_ transport: GridStubTransport) async -> Int {
    await transport.recordedWire.filter { $0.operationID == markOp }.count
  }

  private func wireCount(_ transport: GridStubTransport, path: String) async -> Int {
    await transport.recordedWire.filter { $0.path.hasPrefix(path) }.count
  }

  // MARK: - U1–U4: the write boundary (ADR-0005)

  /// U1 · kills M1 (`actionableImages` returns the stream while entered).
  @Test("Entering makes only the scene's members actionable; Back restores the stream")
  func enteringMakesOnlyItsMembersActionable() async {
    let (store, _) = await sceneStore()
    #expect(store.actionableImages.map(\.id) == [10, 11])
    await store.enterScene(5)
    #expect(store.actionableImages.map(\.id) == [1, 2, 3])
    store.leaveScene()
    #expect(store.actionableImages.map(\.id) == [10, 11])
  }

  /// U2 · kills M2 (the builder emits the representative as an `.image`).
  @Test("A card is never actionable, in the stream or inside a scene")
  func aCardIsNeverActionableInsideOrOutside() async {
    let (store, _) = await sceneStore()
    #expect(shown(store, .stream) == [.image(10), .stack(5), .stack(6), .image(11)])
    #expect(!store.actionableImages.contains { [900, 901].contains($0.id) })
    await store.enterScene(5)
    #expect(!store.actionableImages.contains { [900, 901].contains($0.id) })
    #expect(!shown(store, .scene(5)).contains { if case .stack = $0 { true } else { false } })
  }

  /// U2b · kills M2: a focus that leaked onto a cover id writes nothing; a loose id writes once.
  @Test("P on a leaked cover focus writes nothing; on a loose photograph it writes once")
  func pOnALeakedCoverFocusWritesNothing() async {
    let (store, transport) = await sceneStore()
    await transport.setMarkStateOutcome(applied(10))
    store.focusedImageID = 900
    await store.handlePickShortcut(shiftHeld: false)
    #expect(await markRequests(transport) == 0)
    // Control: the same gesture on a loose photograph does reach the server.
    store.focusedImageID = 10
    await store.handlePickShortcut(shiftHeld: false)
    #expect(await markRequests(transport) == 1)
  }

  /// U3 · kills M17 (`capturePriorSnapshots` falls back to every loaded summary).
  @Test("The actionable fence refuses an id that is loaded but not on screen")
  func theActionableFenceRefusesAnUnlistedID() async {
    let (store, transport) = await sceneStore()
    await store.enterScene(5)
    store.leaveScene()
    // Member 1 is still CACHED (re-entry costs no request), but it is not on the stream.
    #expect(store.sceneMembers[5]?.map(\.id) == [1, 2, 3])
    await transport.setMarkStateOutcome(applied(1))
    _ = await store.applyMark(.pick, to: [1])
    _ = await store.applyMark(.pick, to: [900])
    #expect(await markRequests(transport) == 0)
    await transport.setMarkStateOutcome(applied(10))
    _ = await store.applyMark(.pick, to: [10])
    #expect(await markRequests(transport) == 1)
  }

  /// U4 · kills M19 (a latched `tapCell(.stack)` marks the representative).
  @Test("A card tap enters in every mode — browse, Pick, Dislike, Select — and writes nothing")
  func aCardTapEntersInEveryModeAndWritesNothing() async {
    for mode in ["browse", "pick", "dislike", "select"] {
      let (store, transport) = await sceneStore()
      switch mode {
      case "pick": store.pickLock.forceLatch(.pick)
      case "dislike": store.pickLock.forceLatch(.dislike)
      case "select": store.enterSelectExplicitly()
      default: break
      }
      await store.tapCell(.stack(5))
      #expect(store.enteredSceneID == 5, "\(mode): the card did not push its scene")
      #expect(await markRequests(transport) == 0, "\(mode): a card tap wrote a mark")
      #expect(store.selection.members.isEmpty, "\(mode): a card tap selected something")
    }
  }

  // MARK: - U5–U12: the transition

  /// U5 · kills M3 (keeps focus), M4 (exits the latch), M29 (resets the stream anchor).
  @Test("The transition clears selection, focus and loupe; keeps latch, undo, query and anchor")
  func theTransitionClearsSelectionFocusLoupeRecoveryKeepsLatchUndoQueryAnchor() async {
    let (store, transport) = await sceneStore()
    store.recordScrollAnchor(.image(10), for: .stream)
    await transport.setMarkStateOutcome(applied(10))
    _ = await store.applyMark(.pick, to: [10])
    #expect(store.undo.canUndo)
    let queryBefore = store.query

    // Phase A: a selection and a focus.
    store.enterSelectExplicitly()
    store.selection.toggle(10)
    store.focusedImageID = 11
    await store.enterScene(5)
    #expect(store.selection.members.isEmpty)
    #expect(store.selection.mode == .browse)
    #expect(store.focusedImageID == nil)
    #expect(store.conflictRecovery == nil)

    // Phase B: the loupe open and Pick latched.
    store.leaveScene()
    store.openLoupe(on: 10)
    store.pickLock.forceLatch(.pick)
    #expect(store.isLoupeOpen)
    await store.enterScene(5)
    #expect(!store.isLoupeOpen)
    #expect(store.pickLock.latchedVerb == .pick)
    #expect(store.undo.canUndo)
    #expect(store.query == queryBefore)
    #expect(store.scrollAnchor(for: .stream) == .image(10))
  }

  /// U6 · kills M5 (a mark made inside never reaches the card the reader goes Back to).
  @Test("A mark made inside the scene is on the card after Back")
  func aMarkInsideIsOnTheCardAfterBack() async {
    let (store, transport) = await sceneStore()
    await store.enterScene(5)
    await transport.setStackRow(row(5, count: 3, anchor: t0, cover: 900, picked: 1), forStack: 5)
    await transport.setMarkStateOutcome(applied(2))
    #expect(await store.applyMark(.pick, to: [2]))
    store.leaveScene()
    let card = store.sceneRows.compactMap { item -> Int? in
      if case .stack(let stack) = item, stack.stackId == 5 { return stack.pickedCount }
      return nil
    }
    #expect(card == [1])
    #expect(store.sceneMembers[5]?.first { $0.id == 2 }?.mark.state == .pick)
  }

  /// U7 · kills M30 (a stored `sceneExpanded` that Back forgets to clear).
  @Test("The scene-edit subject follows the entry")
  func theEditSubjectFollowsTheEntry() async {
    let (store, _) = await enteredStore()
    #expect(store.sceneEditSubject == SceneEditSubject(stackID: 5, focusedImageID: 2))
    store.leaveScene()
    store.focusedImageID = 2
    #expect(store.sceneEditSubject == nil)
    await store.enterScene(6)
    store.focusedImageID = 7
    #expect(store.sceneEditSubject == SceneEditSubject(stackID: 6, focusedImageID: 7))
  }

  /// U8 · kills M7 (no leave at the site).
  @Test("A filter change inside leaves with the new query and keeps the latch")
  func aFilterChangeInsideLeavesWithTheNewQueryAndKeepsTheLatch() async {
    let (store, _) = await enteredStore()
    store.pickLock.forceLatch(.pick)
    await store.applyFilterChange { $0.ratingMin = 3 }
    #expect(store.enteredSceneID == nil)
    #expect(store.query.ratingMin == 3)
    #expect(store.pickLock.latchedVerb == .pick)
  }

  /// U8 · kills M7.
  @Test("A sort change inside leaves the scene")
  func aSortChangeInsideLeaves() async {
    let (store, _) = await enteredStore()
    await store.setSortKey(.filename)
    #expect(store.enteredSceneID == nil)
  }

  /// U8 · kills M31 (leave on every query write, before the `next != query` guard). Stage B: in
  /// this tree every Scene-mode sort goes through `applyFlatPresentation` (Flat), so the "sort
  /// that only changes the suspended presentation" the plan names is the no-op query write.
  @Test("A query write that changes nothing keeps the scene")
  func aSuspendedSortChangeKeepsTheScene() async {
    let (store, _) = await enteredStore()
    await store.applyFilterChange { _ in }
    #expect(store.enteredSceneID == 5)
  }

  /// U8 · kills M31 (a non-query Arrange change treated as a scope change).
  @Test("A thumbnail size change stays inside")
  func aThumbnailSizeChangeStaysInside() async {
    let (store, _) = await enteredStore()
    let next = GridRowHeight.allCases.first { $0 != store.rowHeight } ?? .step400
    store.setRowHeight(next)
    #expect(store.enteredSceneID == 5)
  }

  /// U8 · kills M7.
  @Test("Switching to Flat leaves the scene")
  func switchingToFlatLeaves() async {
    let (store, transport) = await enteredStore()
    await transport.setListImagesPage(.init(items: [image(1)], limit: 100, nextCursor: nil))
    await store.setDisplayMode(.flat)
    #expect(store.enteredSceneID == nil)
  }

  /// U9 · kills M8 (no Scene-mode guard on enter).
  @Test("Entering in Flat mode is a no-op")
  func enteringInFlatModeIsANoOp() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [image(1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    await store.enterScene(5)
    #expect(store.enteredSceneID == nil)
    #expect(await transport.callCount(membersOp) == 0)
  }

  /// U9 · kills M8 (no listed-card guard on enter).
  @Test("Entering a stack that is not listed is refused")
  func enteringAnUnlistedStackIsRefused() async {
    let (store, transport) = await sceneStore()
    await store.enterScene(99)
    #expect(store.enteredSceneID == nil)
    #expect(await transport.callCount(membersOp) == 0)
  }

  /// U10 · kills M9 (no single-flight on the members read).
  @Test("A second enter while the first page loads asks once")
  func aSecondEnterWhileLoadingAsksOnce() async {
    let (store, transport) = await sceneStore()
    await transport.holdStackMembersRequests(true)
    let first = Task { await store.enterScene(5) }
    await transport.waitUntilStackMembersStarted()
    await store.enterScene(5)
    await transport.holdStackMembersRequests(false)
    await transport.releaseStackMembers()
    await first.value
    #expect(await transport.callCount(membersOp) == 1)
    #expect(shown(store, .scene(5)) == [.image(1), .image(2), .image(3)])
  }

  /// U10 · kills M9 (no `enteredSceneID == stackID` fence on the late page).
  @Test("A page that lands after Back is not actionable")
  func aLatePageAfterBackIsNotActionable() async {
    let (store, transport) = await sceneStore()
    await transport.holdStackMembersRequests(true)
    let first = Task { await store.enterScene(5) }
    await transport.waitUntilStackMembersStarted()
    store.leaveScene()
    await transport.holdStackMembersRequests(false)
    await transport.releaseStackMembers()
    await first.value
    #expect(store.enteredSceneID == nil)
    #expect(store.actionableImages.map(\.id) == [10, 11])
  }

  /// U11 · kills M10 (the strip walks the stream).
  @Test("The filmstrip is the entered scene")
  func theFilmstripIsTheEnteredScene() async {
    let (store, _) = await sceneStore()
    await store.enterScene(5)
    store.openLoupe(on: 2)
    #expect(FilmstripScope.resolve(for: store).frames.map(\.id) == [1, 2, 3])
  }

  /// U12 · kills M11 (restore the in-place card → members swap).
  @Test("The stream never swaps a card for its members")
  func theStreamNeverSwapsACardForItsMembers() async {
    let (store, _) = await sceneStore()
    await store.enterScene(5)
    #expect(shown(store, .stream) == [.image(10), .stack(5), .stack(6), .image(11)])
    #expect(store.sceneDisplayRows.map(\.id) == [.image(10), .stack(5), .stack(6), .image(11)])
    #expect(shown(store, .scene(5)) == [.image(1), .image(2), .image(3)])
  }

  // MARK: - U13: topology edits made inside the scene

  /// U13 · kills M12 (leave then re-enter), M49 (no candidate load → `[]` for 6).
  @Test("A merge inside follows the survivor, with both of its membership pages")
  func mergeInsideFollowsTheSurvivor() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [6], dissolved: [5])))
    await transport.setBrowseStacksPage(
      page([loose(10), scene(6, count: 5, anchor: t0, cover: 901), loose(11)]))
    await transport.setStackMemberPage(members([7, 8, 1], of: 6, next: "six-2"), forStack: 6)
    await transport.setStackMemberPage(members([2, 3], of: 6), forCursor: "six-2")

    await store.mergeFocusedScene(into: 6)

    #expect(store.enteredSceneID == 6)
    #expect(shown(store, .scene(6)) == [7, 8, 1, 2, 3].map { GridDisplayID.image($0) })
    #expect(await wireCount(transport, path: "/api/stacks/6/members") >= 1)
    #expect(store.focusedImageID == 2)
  }

  /// U13 · kills M12, M50 (the anchor looked up in the cache, not the loaded candidates).
  @Test("A split inside retargets to the part holding the anchor")
  func splitInsideRetargetsToTheAnchorsPart() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [5, 9])))
    await transport.setBrowseStacksPage(page(splitItems))
    await transport.setStackMemberPage(members([1], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([2, 3], of: 9), forStack: 9)

    await store.splitFocusedScene()

    #expect(store.enteredSceneID == 9)
    #expect(shown(store, .scene(9)) == [.image(2), .image(3)])
    #expect(store.focusedImageID == 2)
  }

  /// U13i · a merge survivor whose membership reads back empty is gone, never an entered scene
  /// stuck on Loading (no members, nothing in flight, no failure).
  @Test("A merge survivor that reads back empty leaves the scene")
  func anEmptyMergeSurvivorLeaves() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [6], dissolved: [5])))
    await transport.setBrowseStacksPage(
      page([loose(10), scene(6, count: 5, anchor: t0, cover: 901), loose(11)]))
    await transport.setStackMemberPage(members([], of: 6), forStack: 6)

    await store.mergeFocusedScene(into: 6)

    #expect(store.enteredSceneID == nil)
  }

  /// U13 · kills M12 (a dissolving result keeps a dead entry).
  @Test("An edit whose result dissolves the entered scene leaves it")
  func aDissolvingEditLeaves() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [], dissolved: [5])))
    await transport.setBrowseStacksPage(
      page([loose(10), loose(1), loose(2), loose(3), scene(6, count: 2, anchor: t1, cover: 901)]))
    await store.splitFocusedScene()
    #expect(store.enteredSceneID == nil)
  }

  /// U13 · kills M12: the entry is read while the coordinator's candidate read is held.
  @Test("The entry is never nil during a topology reload")
  func theEntryIsNeverNilDuringATopologyReload() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [5, 9])))
    await transport.setBrowseStacksPage(page(splitItems))
    await transport.setStackMemberPage(members([1], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([2, 3], of: 9), forStack: 9)
    await transport.holdStackMembersRequests(true)

    let edit = Task { await store.splitFocusedScene() }
    await transport.waitUntilStackMembersStarted()
    #expect(store.enteredSceneID == 5, "the coordinator left the scene during its reload")
    await transport.holdStackMembersRequests(false)
    await transport.releaseStackMembers()
    await edit.value
    #expect(store.enteredSceneID == 9)
  }

  /// U13b · kills M40 (retarget unconditionally).
  @Test("A Back during a held topology edit is not undone")
  func aBackDuringAHeldTopologyEditIsNotUndone() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [5, 9])))
    await transport.setBrowseStacksPage(page(splitItems))
    await transport.setStackMemberPage(members([1], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([2, 3], of: 9), forStack: 9)
    await transport.holdStackEditRequests(true)

    let edit = Task { await store.splitFocusedScene() }
    await transport.waitUntilStackEditStarted()
    store.leaveScene()
    await transport.holdStackEditRequests(false)
    await transport.releaseStackEdit()
    await edit.value

    #expect(store.enteredSceneID == nil)
    #expect(store.focusedImageID == nil)
    let stream = shown(store, .stream)
    #expect(stream.contains(.stack(5)) && stream.contains(.stack(9)))
    #expect(!stream.contains { [1, 2, 3].map { GridDisplayID.image($0) }.contains($0) })
  }

  /// U13c · kills M39 (owner compares the stack id only), M51 (step 6 does not restore).
  @Test("Leaving and re-entering during the hold is not retargeted")
  func leavingAndReenteringDuringTheHoldIsNotRetargeted() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [5, 9])))
    await transport.holdStackEditRequests(true)

    let edit = Task { await store.splitFocusedScene() }
    await transport.waitUntilStackEditStarted()
    store.leaveScene()
    await store.enterScene(5)
    let revision = store.sceneRevision
    await transport.setBrowseStacksPage(page(splitItems))
    await transport.setStackMemberPage(members([1], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([2, 3], of: 9), forStack: 9)
    await transport.holdStackEditRequests(false)
    await transport.releaseStackEdit()
    await edit.value

    #expect(store.enteredSceneID == 5)
    #expect(store.sceneRevision == revision, "the completion navigated a screen it did not own")
    #expect(shown(store, .scene(5)) == [.image(1)])
  }

  /// U13d · kills M40.
  @Test("A folder-row tap during the hold lands on the stream")
  func aFolderRowTapDuringTheHoldLandsOnTheStream() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [5, 9])))
    await transport.setBrowseStacksPage(page(splitItems))
    await transport.setStackMemberPage(members([1], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([2, 3], of: 9), forStack: 9)
    await transport.holdStackEditRequests(true)

    let edit = Task { await store.splitFocusedScene() }
    await transport.waitUntilStackEditStarted()
    await store.openShoot(folderID: 1)
    await transport.holdStackEditRequests(false)
    await transport.releaseStackEdit()
    await edit.value

    #expect(store.enteredSceneID == nil)
    #expect(
      shown(store, .stream) == [.image(10), .stack(5), .stack(9), .stack(6), .image(11)])
  }

  /// U13e · kills M41 (retarget when `owner.stackID == nil`).
  @Test("An absorb from the stream never pushes")
  func anAbsorbFromTheStreamNeverPushes() async {
    let (store, transport) = await sceneStore()
    store.focusedImageID = 10
    await transport.setStackEditOutcome(.success(editResult(stacks: [6])))
    await transport.setBrowseStacksPage(
      page([
        scene(5, count: 3, anchor: t0, cover: 900), scene(6, count: 3, anchor: t1, cover: 901),
        loose(11),
      ]))
    await transport.setStackMemberPage(members([7, 8, 10], of: 6), forStack: 6)
    await store.absorbFocusedPhoto(into: 6)
    #expect(store.enteredSceneID == nil)
    #expect(await wireCount(transport, path: "/api/stacks/6/members") == 0)
  }

  /// U13e · kills M47 (drop the dissolved check in step 6).
  @Test("An edit whose entered scene dissolved during the hold leaves it")
  func anEditWhoseEnteredSceneDissolvedLeaves() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [6], dissolved: [5])))
    await transport.holdStackEditRequests(true)
    let edit = Task { await store.mergeFocusedScene(into: 6) }
    await transport.waitUntilStackEditStarted()
    store.leaveScene()
    await store.enterScene(5)
    await transport.setBrowseStacksPage(
      page([loose(10), scene(6, count: 5, anchor: t0, cover: 901), loose(11)]))
    await transport.holdStackEditRequests(false)
    await transport.releaseStackEdit()
    await edit.value
    #expect(store.enteredSceneID == nil)
  }

  /// U13e · kills M53 (the dissolved rule runs before the owned commit).
  @Test("An owned merge is not left for its own dissolved scene")
  func anOwnedMergeIsNotLeftForItsOwnDissolvedScene() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [6], dissolved: [5])))
    await transport.setBrowseStacksPage(
      page([loose(10), scene(6, count: 5, anchor: t0, cover: 901), loose(11)]))
    await transport.setStackMemberPage(members([7, 8, 1, 2, 3], of: 6), forStack: 6)
    await store.mergeFocusedScene(into: 6)
    #expect(store.enteredSceneID == 6)
  }

  /// U13f · kills M51 (no restore), M40 (retarget the new scene).
  @Test("Entering another scene during the hold keeps its members")
  func enteringAnotherSceneDuringTheHoldKeepsItsMembers() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [5, 9])))
    await transport.holdStackEditRequests(true)
    let edit = Task { await store.splitFocusedScene() }
    await transport.waitUntilStackEditStarted()
    store.leaveScene()
    await store.enterScene(6)
    #expect(shown(store, .scene(6)) == [.image(7), .image(8)])
    await transport.setBrowseStacksPage(page(splitItems))
    await transport.setStackMemberPage(members([1], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([2, 3], of: 9), forStack: 9)
    let before = await transport.recordedWire.count
    await transport.holdStackEditRequests(false)
    await transport.releaseStackEdit()
    await edit.value

    #expect(store.enteredSceneID == 6)
    #expect(shown(store, .scene(6)) == [.image(7), .image(8)])
    let after = await transport.recordedWire.dropFirst(before)
    #expect(!after.contains { $0.path.hasPrefix("/api/stacks/5/members") })
    #expect(!after.contains { $0.path.hasPrefix("/api/stacks/9/members") })
  }

  /// U13g · kills M52 (ownership checked once, before the candidate loads only).
  @Test("A Back during the candidate load wins")
  func aBackDuringTheCandidateLoadWins() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [6], dissolved: [5])))
    await transport.setBrowseStacksPage(
      page([loose(10), scene(6, count: 5, anchor: t0, cover: 901), loose(11)]))
    await transport.setStackMemberPage(members([7, 8, 1, 2, 3], of: 6), forStack: 6)
    await transport.holdStackMembersRequests(true)

    let edit = Task { await store.mergeFocusedScene(into: 6) }
    await transport.waitUntilStackMembersStarted()
    store.leaveScene()
    let revision = store.sceneRevision
    await transport.holdStackMembersRequests(false)
    await transport.releaseStackMembers()
    await edit.value

    #expect(store.enteredSceneID == nil)
    #expect(store.sceneRevision == revision)
    #expect(shown(store, .stream).contains(.stack(6)))
  }

  /// U13g variant · kills M52: Back then a different enter during the held candidate load.
  @Test("Back then another enter during the candidate load keeps the new scene")
  func anEnterDuringTheCandidateLoadWins() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [6], dissolved: [5])))
    await transport.setBrowseStacksPage(
      page([
        loose(10), scene(6, count: 5, anchor: t0, cover: 901),
        scene(12, count: 2, anchor: t2, cover: 903), loose(11),
      ]))
    await transport.setStackMemberPage(members([7, 8, 1, 2, 3], of: 6), forStack: 6)
    await transport.setStackMemberPage(members([20, 21], of: 12), forStack: 12)
    await transport.holdStackMembersRequests(true)

    let edit = Task { await store.mergeFocusedScene(into: 6) }
    await transport.waitUntilStackMembersStarted()
    store.leaveScene()
    await transport.holdStackMembersRequests(false)
    await store.enterScene(12)
    await transport.releaseStackMembers()
    await edit.value

    #expect(store.enteredSceneID == 12)
    #expect(shown(store, .scene(12)) == [.image(20), .image(21)])
  }

  /// U13h · kills M55 (the first-id fallback also on a failed read), M56 (Retry ignores the
  /// pending resolution and revalidates the entered scene).
  @Test("A failed candidate read never resolves to the first part; Retry resolves it")
  func aFailedCandidateReadNeverResolvesToTheFirstPart() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [5, 9])))
    await transport.setBrowseStacksPage(page(splitItems))
    await transport.setStackMemberPage(members([1], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([2, 3], of: 9), forStack: 9)
    await transport.failStackMembers(9)
    let revision = store.sceneRevision

    await store.splitFocusedScene()

    #expect(store.enteredSceneID == 5)
    #expect(store.sceneRevision == revision, "a failed read retargeted the screen")
    #expect(shown(store, .scene(5)).isEmpty, "the first part's members were installed")
    #expect(store.sceneScreenState(for: 5) == .failed)
    #expect(store.sceneLoadFailed == [5])
    #expect(store.sceneDestinationRetry != nil)
    // Step 4b leaves the focus alone, but nothing is actionable: a P reaches no server.
    #expect(store.actionableImages.isEmpty)
    await store.handlePickShortcut(shiftHeld: false)
    #expect(await markRequests(transport) == 0)

    await transport.failStackMembers(9, false)
    await store.retryEnteredScene()

    #expect(store.enteredSceneID == 9)
    #expect(shown(store, .scene(9)) == [.image(2), .image(3)])
    #expect(store.focusedImageID == 2)
    #expect(store.sceneDestinationRetry == nil)
  }

  /// U13h control · fallback (c): every candidate read, none holds the anchor → the first part.
  @Test("Every candidate loaded without the anchor falls back to the first")
  func everyCandidateLoadedWithoutTheAnchorFallsBackToTheFirst() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [5, 9])))
    await transport.setBrowseStacksPage(page(splitItems))
    await transport.setStackMemberPage(members([1], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([3], of: 9), forStack: 9)

    await store.splitFocusedScene()

    #expect(store.enteredSceneID == 5)
    #expect(shown(store, .scene(5)) == [.image(1)])
    #expect(store.sceneDestinationRetry == nil)
  }

  /// U13h variant (r6) · kills M57 (the record is cleared only by a real `transitionScene`, so a
  /// same-id commit leaves it and the next revalidation re-runs the stale resolution).
  @Test("A Retry that resolves to the entered scene drops the retry record")
  func aRetryThatResolvesToTheEnteredSceneDropsTheRecord() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [5, 9])))
    await transport.setBrowseStacksPage(page(splitItems))
    await transport.setStackMemberPage(members([1, 2], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([3], of: 9), forStack: 9)
    await transport.failStackMembers(5)

    await store.splitFocusedScene()
    #expect(store.sceneDestinationRetry != nil, "precondition: step 4b did not engage")
    let revision = store.sceneRevision

    await transport.failStackMembers(5, false)
    await store.retryEnteredScene()

    #expect(store.enteredSceneID == 5)
    #expect(store.sceneRevision == revision)
    #expect(shown(store, .scene(5)) == [.image(1), .image(2)])
    #expect(store.sceneDestinationRetry == nil)

    // A later KEEP revalidation reads scene 5 itself, never the stale resolution's parts.
    await transport.markStackGone(5)
    await transport.setBrowseStacksPage(
      page([loose(10), scene(9, count: 1, anchor: t0 + 30, cover: 902), loose(11)]))
    let before = await transport.recordedWire.count
    await store.fullReload()
    let after = await transport.recordedWire.dropFirst(before)
    #expect(after.contains { $0.operationID == stackRowOp && $0.path.hasPrefix("/api/stacks/5") })
    #expect(!after.contains { $0.path.hasPrefix("/api/stacks/9/members") })
    #expect(store.enteredSceneID == nil)
  }

  // MARK: - U14–U17: refresh keeps, revalidates, or leaves

  private func storeWithSceneBeyondPageOne() async -> (GridStore, GridStubTransport) {
    let (store, transport) = makeStore()
    await transport.setBrowseStacksPage(
      page(
        [
          loose(10), scene(5, count: 3, anchor: t0, cover: 900),
          scene(6, count: 2, anchor: t1, cover: 901),
        ], next: "p2"))
    await transport.setBrowseStacksPage(
      page([scene(30, count: 2, anchor: t2, cover: 940)]), forCursor: "p2")
    await transport.setStackMemberPage(members([40, 41], of: 30), forStack: 30)
    await store.selectShoot(folderID: 1)
    await store.setDisplayMode(.scene)
    await store.loadMoreScenesIfNeeded(currentRowID: .stack(6))
    await store.enterScene(30)
    return (store, transport)
  }

  /// U14 · kills M20 (leave when page one lacks the entered scene).
  @Test("A scene opened beyond page one survives a refresh")
  func aSceneOpenedBeyondPageOneSurvivesARefresh() async {
    let (store, transport) = await storeWithSceneBeyondPageOne()
    #expect(store.enteredSceneID == 30)
    await transport.setStackRow(row(30, count: 2, anchor: t2, cover: 940), forStack: 30)
    #expect(await store.authoritativeRefresh())
    #expect(store.enteredSceneID == 30)
    #expect(store.sceneRows.contains { $0.displayID == .stack(30) })
    #expect(await wireCount(transport, path: "/api/stacks/30") >= 2)
    #expect(await transport.callCount(stackRowOp) == 1)
    #expect(shown(store, .scene(30)) == [.image(40), .image(41)])
  }

  /// U15 · kills M21 (a 404 treated as unreachable).
  @Test("A scene gone on the server is left")
  func aSceneGoneOnTheServerIsLeft() async {
    let (store, transport) = await storeWithSceneBeyondPageOne()
    await transport.markStackGone(30)
    _ = await store.authoritativeRefresh()
    #expect(store.enteredSceneID == nil)
  }

  /// U15 · kills M21.
  @Test("An empty membership leaves the scene")
  func anEmptyMembershipLeaves() async {
    let (store, transport) = await sceneStore()
    await store.enterScene(5)
    await transport.setStackMemberPage(members([], of: 5), forStack: 5)
    _ = await store.authoritativeRefresh()
    #expect(store.enteredSceneID == nil)
  }

  /// U16 · kills M22 (leave on any lookup error).
  @Test("A failed lookup keeps the scene and the window")
  func aFailedLookupKeepsTheSceneAndTheWindow() async {
    let (store, _) = await storeWithSceneBeyondPageOne()
    let rowsBefore = store.sceneRows.map(\.displayID)
    // No stack row is configured for 30: the lookup is unreachable, not a 404.
    #expect(await store.authoritativeRefresh() == false)
    #expect(store.enteredSceneID == 30)
    #expect(store.sceneRows.map(\.displayID) == rowsBefore)
  }

  /// U17 · kills M32 (the foreground reload clears the entry).
  @Test("A foreground full reload keeps the scene")
  func aForegroundFullReloadKeepsTheScene() async {
    let (store, _) = await sceneStore()
    await store.enterScene(5)
    await store.fullReload()
    #expect(store.enteredSceneID == 5)
    #expect(shown(store, .scene(5)) == [.image(1), .image(2), .image(3)])
  }

  /// U17 · kills M33 (no `enteredSceneID == id` fence after the revalidation's await).
  @Test("A Back during revalidation wins")
  func aBackDuringRevalidationWins() async {
    let (store, transport) = await sceneStore()
    await store.enterScene(5)
    await transport.holdStackMembersRequests(true)
    let reload = Task { await store.fullReload() }
    await transport.waitUntilStackMembersStarted()
    store.leaveScene()
    await transport.holdStackMembersRequests(false)
    await transport.releaseStackMembers()
    await reload.value
    #expect(store.enteredSceneID == nil)
    #expect(store.actionableImages.map(\.id) == [10, 11])
  }

  // MARK: - U18–U19: one scroll slot per scope, one rows writer, queued crossings

  /// U18a · kills M27 (one shared slot), M27b (the transition writes the stream anchor), M44
  /// (the transition leaves the scene anchor set).
  @Test("A scene scroll never writes the stream anchor")
  func aSceneScrollNeverWritesTheStreamAnchor() async {
    let (store, _) = await sceneStore()
    store.recordScrollAnchor(.image(10), for: .stream)
    await store.enterScene(5)
    store.recordScrollAnchor(.image(2), for: .scene(5))
    store.recordScrollAnchor(.image(7), for: .scene(6))  // not entered: dropped
    #expect(store.scrollAnchor(for: .stream) == .image(10))
    #expect(store.scrollAnchor(for: .scene(5)) == .image(2))
    store.leaveScene()
    #expect(store.scrollAnchor(for: .stream) == .image(10))
    await store.enterScene(5)
    #expect(store.scrollAnchor(for: .scene(5)) == nil)
  }

  /// U18b · kills M24 (drop the inactive-scope refusal in `publishRows`).
  @Test("Rows published from the inactive scope are refused")
  func rowsFromTheInactiveScopeAreRefused() async {
    let (store, _) = await sceneStore()
    await store.enterScene(5)
    store.publishRows([[.image(1), .image(2)]], from: .scene(5))
    #expect(store.rows == [[.image(1), .image(2)]])
    store.publishRows([[.image(10)]], from: .stream)
    #expect(store.rows == [[.image(1), .image(2)]])
    store.leaveScene()
    store.publishRows([[.image(1)]], from: .scene(5))
    #expect(store.rows.isEmpty)
    store.publishRows([[.image(10)]], from: .stream)
    #expect(store.rows == [[.image(10)]])
  }

  /// U19 · kills M1, M45 (the transition removes pending crossings silently).
  @Test("A crossing queued in the stream is dropped and reported inside the scene")
  func aCrossingQueuedInTheStreamIsDroppedAndReportedInsideTheScene() async {
    let (store, transport) = await sceneStore()
    await transport.setMarkStateOutcome(applied(10))
    await transport.holdMarkStateRequests(true)
    store.pickLock.forceLatch(.pick)
    store.beginPointerDrag()
    async let crossing: Void = store.pointerDragCrossed(.image(10))
    await transport.waitUntilMarkStateStarted()
    await store.pointerDragCrossed(.image(11))
    await store.enterScene(5)
    await transport.holdMarkStateRequests(false)
    await transport.releaseMarkState()
    _ = await crossing

    #expect(await transport.callCount(markOp) == 1)
    #expect(await transport.lastMarkStateRequest?.imageIds == [10])
    #expect(store.droppedWriteIDs == [11])
    #expect(GridNotices.notices(store: store).contains(.droppedWrites(count: 1)))
  }

  // MARK: - U20–U28

  /// U20 · kills M36 (Retry calls `fullReload`).
  @Test("A failed scene load retries in place")
  func aFailedSceneLoadRetriesInPlace() async {
    let (store, transport) = await sceneStore()
    await transport.failStackMembers(5)
    await store.enterScene(5)
    #expect(store.sceneScreenState(for: 5) == .failed)
    let browseBefore = await transport.callCount(browseOp)
    await transport.failStackMembers(5, false)
    await store.retryEnteredScene()
    #expect(store.sceneScreenState(for: 5) == .loaded)
    #expect(shown(store, .scene(5)) == [.image(1), .image(2), .image(3)])
    #expect(await transport.callCount(browseOp) == browseBefore)
  }

  /// U20 · kills M36 (the state mapping off).
  @Test("The scene screen state covers loading, failed and loaded")
  func sceneScreenStateCoversLoadingFailedLoaded() {
    #expect(
      SceneScreenState.resolve(hasMembers: true, isInFlight: true, hasFailed: true) == .loaded)
    #expect(
      SceneScreenState.resolve(hasMembers: false, isInFlight: true, hasFailed: true) == .loading)
    #expect(
      SceneScreenState.resolve(hasMembers: false, isInFlight: false, hasFailed: true) == .failed)
    #expect(
      SceneScreenState.resolve(hasMembers: false, isInFlight: false, hasFailed: false) == .loading)
  }

  /// U21 · kills M37 (a same-folder row tap keeps the scene).
  @Test("A folder-row tap leaves the scene even for the same shoot")
  func aRowTapLeavesTheSceneEvenForTheSameShoot() async {
    let (store, _) = await enteredStore()
    await store.openShoot(folderID: 1)
    #expect(store.enteredSceneID == nil)
  }

  /// U22 · kills M13 (the title counts something else, or mis-pluralises).
  @Test("The scene screen title counts photos")
  func sceneScreenTitleCountsPhotos() async {
    #expect(SceneScreenTitle.title(memberCount: 1) == "Scene · 1 photo")
    #expect(SceneScreenTitle.title(memberCount: 41) == "Scene · 41 photos")
    let (store, _) = await sceneStore()
    #expect(store.sceneTitle(for: 5) == "Scene · 3 photos")
  }

  /// U23 · kills M38 (any failure mapped to `.notFound`, or 404 not mapped).
  @Test("notFound is mapped only for a 404")
  func notFoundIsMappedOnlyFor404() async {
    let transport = GridStubTransport()
    let service = GridService(client: ImgManagerAPIClient.make(transport: transport))
    await transport.markStackGone(5)
    var rowError: GridServiceError?
    do { _ = try await service.stackRow(stackID: 5, query: GridImagesQuery()) } catch {
      rowError = error as? GridServiceError
    }
    #expect(rowError == .notFound)
    var membersError: GridServiceError?
    do { _ = try await service.stackMembers(stackID: 5, cursor: nil, limit: 100) } catch {
      membersError = error as? GridServiceError
    }
    #expect(membersError == .notFound)
    // An unreachable server is not "gone".
    var otherError: Error?
    do { _ = try await service.stackRow(stackID: 77, query: GridImagesQuery()) } catch {
      otherError = error
    }
    #expect(otherError != nil)
    #expect((otherError as? GridServiceError) != .notFound)
  }

  /// U24 · kills M18s (card focus does not clear the photo focus).
  @Test("Card focus clears the photo focus, and P is then a no-op")
  func cardFocusClearsThePhotoFocusAndPIsANoOp() async {
    let (store, transport) = await sceneStore()
    await transport.setMarkStateOutcome(applied(10))
    store.focusedImageID = 10
    store.cardDidTakeFocus(5)
    #expect(store.focusedImageID == nil)
    await store.handlePickShortcut(shiftHeld: false)
    #expect(await markRequests(transport) == 0)
    #expect(store.markTargetImageIDs.isEmpty)
    // Control: the photo focus back → P writes exactly once.
    store.focusedImageID = 10
    await store.handlePickShortcut(shiftHeld: false)
    #expect(await markRequests(transport) == 1)
  }

  /// U25 · kills M42 (the setter writes while inactive).
  @Test("The presentation gate drops an inactive dismissal")
  func presentationGateDropsAnInactiveDismissal() {
    @MainActor final class Box { var value = true }
    let box = Box()
    let flag = Binding(get: { box.value }, set: { box.value = $0 })
    let inactive = PresentationGate.binding(flag, active: false)
    #expect(inactive.wrappedValue == false, "an inactive instance shows the presentation")
    inactive.wrappedValue = false
    #expect(box.value == true, "an inactive instance dismissed the active one's presentation")
    let active = PresentationGate.binding(flag, active: true)
    #expect(active.wrappedValue == true)
    active.wrappedValue = false
    #expect(box.value == false)
  }

  /// U26 · kills M48 (the lookup catch does not mark failed), M36.
  @Test("A stack-row lookup failure shows Failed, and Retry re-runs it")
  func aStackRowLookupFailureShowsFailedAndRetryReruns() async {
    let (store, transport) = await storeWithSceneBeyondPageOne()
    await store.fullReload()
    #expect(store.enteredSceneID == 30)
    #expect(store.sceneLoadFailed == [30])
    #expect(store.sceneScreenState(for: 30) == .failed)
    let lookups = await transport.callCount(stackRowOp)
    await transport.setStackRow(row(30, count: 2, anchor: t2, cover: 940), forStack: 30)
    await store.retryEnteredScene()
    #expect(await transport.callCount(stackRowOp) == lookups + 1)
    #expect(store.sceneScreenState(for: 30) == .loaded)
  }

  /// U27 · kills M46 (drop `dismissGridPresentations` from the transition).
  @Test("The transition closes every grid presentation")
  func theTransitionClosesEveryGridPresentation() async {
    let (store, transport) = await enteredStore()
    await transport.setStackEditOutcome(.conflict(.membershipChanged))
    store.selection.enterSelectExplicitly()
    store.selection.toggle(2)
    await store.extractSelectionFromFocusedScene()
    store.isTagEntryPresented = true
    store.isStatusPresented = true
    store.isSceneMergePickerPresented = true
    store.isSceneAbsorbPickerPresented = true
    #expect(store.sceneEditError != nil, "precondition: no edit error to close")
    #expect(store.isTagEntryPresented && store.isStatusPresented)
    #expect(store.isSceneMergePickerPresented && store.isSceneAbsorbPickerPresented)

    store.leaveScene()
    #expect(!store.isTagEntryPresented && !store.isStatusPresented)
    #expect(!store.isSceneMergePickerPresented && !store.isSceneAbsorbPickerPresented)
    #expect(store.sceneEditError == nil)

    // The same from the stream, into a scene.
    store.focusedImageID = 10
    await store.absorbFocusedPhoto(into: 6)
    store.isTagEntryPresented = true
    store.isStatusPresented = true
    store.isSceneMergePickerPresented = true
    store.isSceneAbsorbPickerPresented = true
    #expect(store.sceneEditError != nil, "precondition: no edit error to close")
    await store.enterScene(6)
    #expect(!store.isTagEntryPresented && !store.isStatusPresented)
    #expect(!store.isSceneMergePickerPresented && !store.isSceneAbsorbPickerPresented)
    #expect(store.sceneEditError == nil)
  }

  /// U28 · kills M54 (`.stream` returns `sceneDisplayRows` unconditionally → Flat reads `[]`).
  @Test("The stream scope renders the flat grid in Flat mode")
  func theStreamScopeRendersTheFlatGridInFlatMode() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [image(1), image(2)], limit: 100, nextCursor: nil))
    await transport.setBrowseStacksPage(page(streamItems))
    await store.selectShoot(folderID: 1)
    let flat = shown(store, .stream)
    #expect(flat == [.image(1), .image(2)])
    await store.setDisplayMode(.scene)
    #expect(shown(store, .stream) == [.image(10), .stack(5), .stack(6), .image(11)])
    await store.setDisplayMode(.flat)
    #expect(shown(store, .stream) == flat)
  }
}
