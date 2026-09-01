import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP14 P4 (IMGMGR-277): native scene EDITING — the three actions, the topology coordinator, and
/// the non-banner refusal surface.
///
/// Every test drives a REAL loaded Scene window through `GridStubTransport`, because the whole
/// subject rule is about what is on screen: an assertion that an action is disabled would be
/// worthless against an empty store, where nothing is enabled for reasons that have nothing to do
/// with this lane. The disablement tests therefore come in pairs with a positive control that DOES
/// fire, and the intersection tests use two open scenes so "scoped to the subject" is a difference
/// rather than a coincidence.
///
/// What is NOT claimed here: the derivation fence (a manual stack is never re-joined by the
/// deriver) is a BACKEND gate, `tests/test_api_stack_edit.py`. Nothing in this file stubs it.
@MainActor
@Suite("GridStore — scene editing (WP14 P4)")
struct GridStoreSceneEditTests {

  // MARK: - Fixtures

  private func makeImage(id: Int, folderID: Int = 1, captured: Date? = nil)
    -> Components.Schemas.ImageSummary
  {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, capturedAt: captured, ext: "raf", filename: "DSCF\(id).raf",
      folderId: folderID, hasEdit: false, id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []), missing: false,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStackRow(
    id: Int, memberCount: Int, anchor: Date?, representative: Components.Schemas.ImageSummary
  ) -> Components.Schemas.StackBrowseStackRow {
    Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: anchor, hasPick: false, kind: .stack, matchedCount: memberCount,
      memberCount: memberCount, pickedCount: 0, representative: representative, stackId: id)
  }

  private func stackItem(_ row: Components.Schemas.StackBrowseStackRow)
    -> Components.Schemas.StackBrowsePage.ItemsPayloadPayload
  {
    .init(value1: nil, value2: row)
  }

  private func imageItem(_ image: Components.Schemas.ImageSummary)
    -> Components.Schemas.StackBrowsePage.ItemsPayloadPayload
  {
    .init(value1: .init(image: image, kind: .image), value2: nil)
  }

  private func page(
    _ items: [Components.Schemas.StackBrowsePage.ItemsPayloadPayload], nextCursor: String? = nil
  ) -> Components.Schemas.StackBrowsePage {
    Components.Schemas.StackBrowsePage(items: items, limit: 100, nextCursor: nextCursor)
  }

  private func members(_ ids: [Int], stackID: Int, nextCursor: String? = nil)
    -> Components.Schemas.StackMemberPage
  {
    Components.Schemas.StackMemberPage(
      items: ids.map { makeImage(id: $0) }, limit: 100, nextCursor: nextCursor, stackId: stackID)
  }

  private func editResult(stacks: [Int], dissolved: [Int] = [])
    -> Components.Schemas.StackEditResult
  {
    Components.Schemas.StackEditResult(
      dissolvedStackIds: dissolved, loosenedImageIds: [], stackIds: stacks)
  }

  private let anchorT0 = Date(timeIntervalSince1970: 1_700_000_000)
  private let anchorT1 = Date(timeIntervalSince1970: 1_700_003_600)

  private func makeStore() -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    return (GridStore(service: GridService(client: client)), transport)
  }

  /// The standard editing fixture: two scenes of one folder and a loose photograph, scene 5 open
  /// with the focus on its SECOND member (so a split at the focus is legal — a split before the
  /// first member is the server's `empty_split_side`).
  private func loadedEditableStore() async -> (GridStore, GridStubTransport) {
    let (store, transport) = makeStore()
    await transport.setBrowseStacksPage(
      page([
        stackItem(
          makeStackRow(id: 5, memberCount: 3, anchor: anchorT0, representative: makeImage(id: 1))),
        stackItem(
          makeStackRow(id: 6, memberCount: 2, anchor: anchorT1, representative: makeImage(id: 7))),
        imageItem(makeImage(id: 20)),
      ]))
    await transport.setStackMemberPage(members([1, 2, 3], stackID: 5), forStack: 5)
    await transport.setStackMemberPage(members([7, 8], stackID: 6), forStack: 6)
    await store.selectShoot(folderID: 1)
    await store.setDisplayMode(.scene)
    await store.toggleSceneExpanded(5)
    store.focusedImageID = 2
    return (store, transport)
  }

  /// One scene row as a browse item, in one line — the same value
  /// `stackItem(makeStackRow(…))` builds.
  private func sceneItem(id: Int, count: Int, anchor: Date?, cover: Int)
    -> Components.Schemas.StackBrowsePage.ItemsPayloadPayload
  {
    stackItem(
      makeStackRow(
        id: id, memberCount: count, anchor: anchor, representative: makeImage(id: cover)))
  }

  /// A bounded wait for a request to reach the transport — used where the action under test
  /// starts a `Task` (the alert's buttons do, exactly as SwiftUI runs them).
  private func waitForEdits(_ transport: GridStubTransport, count: Int) async {
    for _ in 0..<200 {
      if await transport.recordedStackEdits.count >= count { return }
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  private func decoded(_ record: GridStubTransport.RecordedStackEdit) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: record.body)) as? [String: Any] ?? [:]
  }

  // MARK: - Decision 2: the subject is the focused member's scene

  @Test("The subject is the focused member's OPEN scene — and nothing else is a subject")
  func theSubjectIsTheFocusedMembersOpenScene() async {
    let (store, _) = await loadedEditableStore()

    #expect(store.sceneEditSubject == SceneEditSubject(stackID: 5, focusedImageID: 2))

    // A loose photograph is not in a scene.
    store.focusedImageID = 20
    #expect(store.sceneEditSubject == nil)
    // Nothing focused at all.
    store.focusedImageID = nil
    #expect(store.sceneEditSubject == nil)
    // A member of a CLOSED scene: membership survives the collapse (reopening costs no request),
    // so this is the case a `sceneMembers` lookup alone would get wrong.
    await store.toggleSceneExpanded(5)
    store.focusedImageID = 2
    #expect(store.sceneMembers[5]?.map(\.id) == [1, 2, 3])
    #expect(store.sceneEditSubject == nil)
    // Positive control for the three nils above.
    await store.toggleSceneExpanded(5)
    #expect(store.sceneEditSubject == SceneEditSubject(stackID: 5, focusedImageID: 2))
  }

  @Test("With no subject, none of the three actions reaches the server")
  func withoutASubjectNothingIsSent() async {
    let (store, transport) = await loadedEditableStore()
    store.focusedImageID = 20  // a loose photograph

    #expect(store.canMergeFocusedScene == false)
    #expect(store.canSplitFocusedScene == false)
    #expect(store.canExtractSelectionFromScene == false)
    store.presentSceneMergePicker()
    await store.mergeFocusedScene(into: 6)
    await store.splitFocusedScene()
    await store.extractSelectionFromFocusedScene()
    #expect(store.isSceneMergePickerPresented == false)
    #expect(await transport.recordedStackEdits.isEmpty)

    // Positive control: with the focus back on a member, the split DOES go out.
    store.focusedImageID = 2
    await transport.setStackEditOutcome(.success(editResult(stacks: [5])))
    await store.splitFocusedScene()
    #expect(await transport.recordedStackEdits.count == 1)
  }

  @Test("Split is disabled at the FIRST member — the half the server refuses as empty")
  func splitIsDisabledAtTheFirstMember() async {
    let (store, transport) = await loadedEditableStore()
    store.focusedImageID = 1
    #expect(store.canSplitFocusedScene == false)
    await store.splitFocusedScene()
    #expect(await transport.recordedStackEdits.isEmpty)
    // Positive control.
    store.focusedImageID = 2
    #expect(store.canSplitFocusedScene)
  }

  // MARK: - Decision 1: the merge target sheet

  @Test("Merge targets are the LOADED same-folder scenes, in capture order, minus the subject")
  func mergeTargetsAreLoadedSameFolderScenesInCaptureOrder() async {
    let (store, transport) = makeStore()
    let earlier = Date(timeIntervalSince1970: 1_699_000_000)
    await transport.setBrowseStacksPage(
      page([
        stackItem(
          makeStackRow(id: 5, memberCount: 3, anchor: anchorT0, representative: makeImage(id: 1))),
        stackItem(
          makeStackRow(id: 6, memberCount: 2, anchor: anchorT1, representative: makeImage(id: 7))),
        stackItem(
          makeStackRow(id: 7, memberCount: 4, anchor: earlier, representative: makeImage(id: 30))),
        // Another folder entirely: scenes are folder-scoped, so this can never be a target.
        stackItem(
          makeStackRow(
            id: 8, memberCount: 2, anchor: anchorT1,
            representative: makeImage(id: 40, folderID: 99))),
      ]))
    await transport.setStackMemberPage(members([1, 2, 3], stackID: 5), forStack: 5)
    await store.selectShoot(folderID: 1)
    await store.setDisplayMode(.scene)
    await store.toggleSceneExpanded(5)
    store.focusedImageID = 2

    #expect(store.sceneMergeTargets.map(\.stackID) == [7, 6])
    #expect(store.sceneMergeTargets.map(\.memberCount) == [4, 2])
    // Positive control for the 0-hit folder assertion: the list really was populated.
    #expect(store.sceneMergeTargets.contains { $0.stackID == 6 })
    #expect(!store.sceneMergeTargets.contains { $0.stackID == 8 })
    #expect(!store.sceneMergeTargets.contains { $0.stackID == 5 })
  }

  @Test("The sheet flow: raise, pick a target, one merge goes out and the sheet closes")
  func theMergeSheetFlowSendsOneMergeAndCloses() async throws {
    let (store, transport) = await loadedEditableStore()
    #expect(store.canMergeFocusedScene)

    store.presentSceneMergePicker()
    #expect(store.isSceneMergePickerPresented)

    // The window AFTER the merge: the server kept 5 and dissolved 6.
    await transport.setStackEditOutcome(.success(editResult(stacks: [5], dissolved: [6])))
    await transport.setBrowseStacksPage(
      page([
        stackItem(
          makeStackRow(id: 5, memberCount: 5, anchor: anchorT0, representative: makeImage(id: 1))),
        imageItem(makeImage(id: 20)),
      ]))
    await transport.setStackMemberPage(members([1, 2, 3, 7, 8], stackID: 5), forStack: 5)

    await store.mergeFocusedScene(into: 6)

    #expect(store.isSceneMergePickerPresented == false)
    let records = await transport.recordedStackEdits
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.path.hasSuffix("/api/stacks/merge"))
    // The SUBJECT first, the picked target second — and nothing else.
    #expect(decoded(record)["stack_ids"] as? [Int] == [5, 6])
    #expect(store.sceneEditError == nil)
  }

  @Test("A target that has left the window while the sheet stood open is a no-op, not a request")
  func aVanishedMergeTargetIsANoOp() async {
    let (store, transport) = await loadedEditableStore()
    store.presentSceneMergePicker()
    await store.mergeFocusedScene(into: 4242)
    #expect(await transport.recordedStackEdits.isEmpty)
    // Positive control.
    await transport.setStackEditOutcome(.success(editResult(stacks: [5], dissolved: [6])))
    await store.mergeFocusedScene(into: 6)
    #expect(await transport.recordedStackEdits.count == 1)
  }

  // MARK: - The topology coordinator (four cases)

  /// Coordinator cases 1 and 2: the scene the edit CREATED comes back open, and the focused
  /// member is found in its new home.
  @Test("Split: the new scene opens and the focus follows the member into it")
  func splitOpensTheNewSceneAndFocusFollows() async throws {
    let (store, transport) = await loadedEditableStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [5, 9])))
    await transport.setBrowseStacksPage(
      page([
        stackItem(
          makeStackRow(id: 5, memberCount: 1, anchor: anchorT0, representative: makeImage(id: 1))),
        stackItem(
          makeStackRow(id: 9, memberCount: 2, anchor: anchorT0, representative: makeImage(id: 2))),
        stackItem(
          makeStackRow(id: 6, memberCount: 2, anchor: anchorT1, representative: makeImage(id: 7))),
        imageItem(makeImage(id: 20)),
      ]))
    await transport.setStackMemberPage(members([1], stackID: 5), forStack: 5)
    await transport.setStackMemberPage(members([2, 3], stackID: 9), forStack: 9)

    await store.splitFocusedScene()

    let records = await transport.recordedStackEdits
    #expect(records.count == 1)
    // `#require`, never a subscript: on a regression this array is EMPTY, and `records[0]` would
    // trap and restart the whole test runner instead of failing this one test (observed in the
    // RED run, 2026-09-01).
    let record = try #require(records.first)
    #expect(record.path.hasSuffix("/api/stacks/5/split"))
    #expect(decoded(record)["at_image_id"] as? Int == 2)

    // The survivor was open and stays open; the NEW scene is open because the edit produced it.
    #expect(store.sceneExpanded == [5, 9])
    #expect(store.sceneMembers[9]?.map(\.id) == [2, 3])
    // …and the reader is left on the photograph they cut at, in its new home.
    #expect(store.focusedImageID == 2)
    // Scene 6 was never open and is not opened by an edit that did not touch it.
    #expect(!store.sceneExpanded.contains(6))
  }

  /// Coordinator case 3: the SURVIVOR is the server's choice — here the target, not the subject —
  /// and it is what comes back open. The dissolved scene does not.
  @Test("Merge: the survivor the server chose is reopened; the dissolved scene is not")
  func mergeReopensTheSurvivorAndDropsTheDissolved() async {
    let (store, transport) = await loadedEditableStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [6], dissolved: [5])))
    await transport.setBrowseStacksPage(
      page([
        stackItem(
          makeStackRow(id: 6, memberCount: 5, anchor: anchorT0, representative: makeImage(id: 1))),
        imageItem(makeImage(id: 20)),
      ]))
    await transport.setStackMemberPage(members([1, 2, 3, 7, 8], stackID: 6), forStack: 6)

    await store.mergeFocusedScene(into: 6)

    #expect(store.sceneExpanded == [6])
    #expect(store.sceneMembers[6]?.map(\.id) == [1, 2, 3, 7, 8])
    // The previously focused member is INSIDE the survivor, so it keeps the focus.
    #expect(store.focusedImageID == 2)
    #expect(store.sceneMembers[5] == nil)
  }

  /// Coordinator case 3, the other half: the anchor did not come back (a member can vanish between
  /// the edit and the reload — membership is the server's answer, not the client's). The rule's
  /// `else` then names the survivor's first member, rather than leaving the reader nowhere.
  @Test("Merge: with the anchor gone, focus falls back to the survivor's first member")
  func mergeFallsBackToTheSurvivorsFirstMember() async {
    let (store, transport) = await loadedEditableStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [6], dissolved: [5])))
    await transport.setBrowseStacksPage(
      page([
        stackItem(
          makeStackRow(id: 6, memberCount: 4, anchor: anchorT0, representative: makeImage(id: 1)))
      ]))
    await transport.setStackMemberPage(members([1, 3, 7, 8], stackID: 6), forStack: 6)

    await store.mergeFocusedScene(into: 6)

    #expect(store.sceneMembers[6]?.map(\.id) == [1, 3, 7, 8])
    #expect(store.focusedImageID == 1)
  }

  /// Coordinator case 4: the EDITED scene comes back WHOLE — past page one — while a scene that
  /// was merely reopened keeps a tap's contract of one page. The focus proves the completion
  /// mattered: the member the reader was on is only on page two.
  @Test("The edited scene is completed past page one; a merely reopened one is not")
  func onlyTheEditedSceneIsCompletedPastPageOne() async {
    let (store, transport) = makeStore()
    await transport.setBrowseStacksPage(
      page([
        stackItem(
          makeStackRow(id: 5, memberCount: 2, anchor: anchorT0, representative: makeImage(id: 1))),
        stackItem(
          makeStackRow(id: 6, memberCount: 3, anchor: anchorT1, representative: makeImage(id: 7))),
        stackItem(
          makeStackRow(id: 11, memberCount: 4, anchor: anchorT1, representative: makeImage(id: 50))),
      ]))
    await transport.setStackMemberPage(members([1, 2], stackID: 5), forStack: 5)
    await transport.setStackMemberPage(members([7, 8], stackID: 6), forStack: 6)
    await transport.setStackMemberPage(
      members([50, 51], stackID: 11, nextCursor: "eleven-2"), forStack: 11)
    await transport.setStackMemberPage(members([52, 53], stackID: 11), forCursor: "eleven-2")
    await store.selectShoot(folderID: 1)
    await store.setDisplayMode(.scene)
    await store.toggleSceneExpanded(5)
    await store.toggleSceneExpanded(6)
    await store.toggleSceneExpanded(11)
    store.focusedImageID = 7  // subject = scene 6

    // Before the edit, scene 11 holds its first page only.
    #expect(store.sceneMembers[11]?.map(\.id) == [50, 51])

    // Merge 6 into 5; the server keeps 5. Its merged membership PAGES.
    await transport.setStackEditOutcome(.success(editResult(stacks: [5], dissolved: [6])))
    await transport.setBrowseStacksPage(
      page([
        stackItem(
          makeStackRow(id: 5, memberCount: 4, anchor: anchorT0, representative: makeImage(id: 1))),
        stackItem(
          makeStackRow(id: 11, memberCount: 4, anchor: anchorT1, representative: makeImage(id: 50))),
      ]))
    await transport.setStackMemberPage(
      members([1, 2], stackID: 5, nextCursor: "five-2"), forStack: 5)
    await transport.setStackMemberPage(members([7, 8], stackID: 5), forCursor: "five-2")

    await store.mergeFocusedScene(into: 5)

    // The EDITED scene came back whole — both pages.
    #expect(store.sceneMembers[5]?.map(\.id) == [1, 2, 7, 8])
    // …which is the only reason the focus could land on a member of page two.
    #expect(store.focusedImageID == 7)
    // The scene nobody edited was reopened as loaded as a tap leaves it: page one.
    #expect(store.sceneExpanded.contains(11))
    #expect(store.sceneMembers[11]?.map(\.id) == [50, 51])
  }

  /// The coordinator's unconditional clause (codex gate, blocker 2): "ensure the RESULT stacks are
  /// open" is not "…if they happen to be on page one".
  ///
  /// A reader edits the scene they are looking at, and the scene they are looking at is wherever
  /// they have scrolled to. The reload rebuilds the window from page ONE, so a result stack that
  /// lives on a later page is simply absent from it — and reopening only what the reloaded page
  /// contains loses the survivor entirely: not open, not completed, no focus, and the selection
  /// pruned out from under the reader. Here the edited scene sits on page two and its results are
  /// nowhere in page one.
  @Test("A result stack from a later browse page is still reopened, completed and focused")
  func aResultStackBeyondPageOneIsStillEnsured() async throws {
    let (store, transport) = makeStore()
    let later = Date(timeIntervalSince1970: 1_700_100_000)
    await transport.setBrowseStacksPage(
      page(
        [
          sceneItem(id: 5, count: 3, anchor: anchorT0, cover: 1),
          sceneItem(id: 6, count: 2, anchor: anchorT1, cover: 7),
        ], nextCursor: "page-2"))
    await transport.setBrowseStacksPage(
      page([sceneItem(id: 30, count: 4, anchor: later, cover: 40)]), forCursor: "page-2")
    await transport.setStackMemberPage(members([1, 2, 3], stackID: 5), forStack: 5)
    await transport.setStackMemberPage(members([40, 41, 42, 43], stackID: 30), forStack: 30)
    await store.selectShoot(folderID: 1)
    await store.setDisplayMode(.scene)
    #expect(store.sceneRows.count == 2)

    // Page forward through the ONE scene pager, the way the grid does, and open the scene there.
    await store.loadMoreScenesIfNeeded(currentRowID: .stack(6))
    #expect(store.sceneRows.map(\.displayID).contains(.stack(30)))
    await store.toggleSceneExpanded(30)
    store.focusedImageID = 42
    #expect(store.sceneEditSubject == SceneEditSubject(stackID: 30, focusedImageID: 42))

    // Split 30 at member 42: the server keeps 30 and makes 31 — and NEITHER is on page one.
    await transport.setStackEditOutcome(.success(editResult(stacks: [30, 31])))
    await transport.setStackRow(
      makeStackRow(id: 30, memberCount: 2, anchor: later, representative: makeImage(id: 40)),
      forStack: 30)
    await transport.setStackRow(
      makeStackRow(id: 31, memberCount: 2, anchor: later, representative: makeImage(id: 42)),
      forStack: 31)
    await transport.setStackMemberPage(members([40, 41], stackID: 30), forStack: 30)
    // The new scene's membership PAGES, so "completed past page one" is observable rather than
    // vacuous: member 43 only exists on its second page.
    await transport.setStackMemberPage(
      members([42], stackID: 31, nextCursor: "thirtyone-2"), forStack: 31)
    await transport.setStackMemberPage(members([43], stackID: 31), forCursor: "thirtyone-2")

    await store.splitFocusedScene()

    // Both result stacks are OPEN, whatever page they lived on…
    #expect(store.sceneExpanded.contains(30), "the survivor was lost with its page")
    #expect(store.sceneExpanded.contains(31), "the new scene was lost with its page")
    // …the EDITED scenes came back whole…
    #expect(store.sceneMembers[31]?.map(\.id) == [42, 43])
    #expect(store.sceneMembers[30]?.map(\.id) == [40, 41])
    // …and the reader is still on the photograph they cut at, in its new home.
    #expect(store.focusedImageID == 42)
    // Chronological order survives the ensure: the re-read rows sit after page one's, which is
    // where their anchors put them.
    #expect(store.sceneRows.map(\.displayID) == [.stack(5), .stack(6), .stack(30), .stack(31)])
  }

  @Test("A row the reload dropped is placed by its anchor, never at the head of the window")
  func insertionIsChronological() {
    let rows: [SceneBrowseRow] = [
      .stack(makeStackRow(id: 5, memberCount: 1, anchor: anchorT0, representative: makeImage(id: 1))),
      .image(makeImage(id: 20, captured: anchorT1)),
    ]
    let before = Date(timeIntervalSince1970: 1_699_000_000)
    let between = Date(timeIntervalSince1970: 1_700_001_000)
    let after = Date(timeIntervalSince1970: 1_700_100_000)
    #expect(SceneEditPlanner.insertionIndex(for: before, in: rows) == 0)
    #expect(SceneEditPlanner.insertionIndex(for: between, in: rows) == 1)
    #expect(SceneEditPlanner.insertionIndex(for: after, in: rows) == 2)
    // No anchor: the end, never the head the reader is looking at.
    #expect(SceneEditPlanner.insertionIndex(for: nil, in: rows) == 2)
    #expect(SceneEditPlanner.insertionIndex(for: after, in: []) == 0)
  }

  // MARK: - Decision 3: extraction is the selection ∩ the subject's membership

  @Test("Extraction sends the subject scene's selected members, in membership order, and no others")
  func extractionSendsTheIntersectionScopedToTheSubject() async throws {
    let (store, transport) = await loadedEditableStore()
    await store.toggleSceneExpanded(6)
    store.selection.enterSelectExplicitly()
    // Selected out of order, and across TWO open scenes.
    store.selection.toggle(3)
    store.selection.toggle(2)
    store.selection.toggle(8)
    store.focusedImageID = 2

    #expect(store.sceneExtractionSelection == [2, 3])
    #expect(store.canExtractSelectionFromScene)

    await transport.setStackEditOutcome(.success(editResult(stacks: [5, 9])))
    await transport.setBrowseStacksPage(
      page([
        stackItem(
          makeStackRow(id: 5, memberCount: 1, anchor: anchorT0, representative: makeImage(id: 1))),
        stackItem(
          makeStackRow(id: 9, memberCount: 2, anchor: anchorT0, representative: makeImage(id: 2))),
      ]))
    await transport.setStackMemberPage(members([1], stackID: 5), forStack: 5)
    await transport.setStackMemberPage(members([2, 3], stackID: 9), forStack: 9)

    await store.extractSelectionFromFocusedScene()

    let records = await transport.recordedStackEdits
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.path.hasSuffix("/api/stacks/5/extract"))
    // Membership order, scoped to the subject: 8 belongs to the OTHER open scene and is untouched.
    #expect(decoded(record)["image_ids"] as? [Int] == [2, 3])
    #expect(store.focusedImageID == 2)
    #expect(store.sceneExpanded == [5, 9])
  }

  @Test("Extraction is not offered for an empty selection, nor for a COMPLETE whole membership")
  func extractionIsNotOfferedWhenItCannotBeDone() async {
    let (store, transport) = await loadedEditableStore()
    #expect(store.sceneExtractionSelection.isEmpty)
    #expect(store.canExtractSelectionFromScene == false)

    store.selection.enterSelectExplicitly()
    store.selection.toggle(1)
    store.selection.toggle(2)
    store.selection.toggle(3)
    // Every member, and the membership is fully loaded — the remainder would be a memberless row.
    #expect(store.sceneMemberCursors[5] == .exhausted)
    #expect(store.canExtractSelectionFromScene == false)
    await store.extractSelectionFromFocusedScene()
    #expect(await transport.recordedStackEdits.isEmpty)

    // Positive control: one member fewer and it IS offered.
    store.selection.toggle(3)
    #expect(store.canExtractSelectionFromScene)
  }

  @Test("A whole-selection extraction IS offered while the membership is still paging")
  func extractionIsOfferedWhenMembershipIsIncomplete() async {
    let (store, transport) = makeStore()
    await transport.setBrowseStacksPage(
      page([
        stackItem(
          makeStackRow(id: 5, memberCount: 9, anchor: anchorT0, representative: makeImage(id: 1)))
      ]))
    await transport.setStackMemberPage(
      members([1, 2], stackID: 5, nextCursor: "five-2"), forStack: 5)
    await store.selectShoot(folderID: 1)
    await store.setDisplayMode(.scene)
    await store.toggleSceneExpanded(5)
    store.focusedImageID = 2
    store.selection.enterSelectExplicitly()
    store.selection.toggle(1)
    store.selection.toggle(2)

    // Everything LOADED is selected, but the scene has more the client has not seen — refusing
    // here would refuse an extraction the server would allow.
    #expect(store.sceneMemberCursors[5] == .more("five-2"))
    #expect(store.canExtractSelectionFromScene)
  }

  // MARK: - The refusal surface (non-banner, typed)

  @Test("A typed 409 is surfaced by its named reason, and nothing is reloaded")
  func aTypedConflictIsSurfacedAndNothingIsReloaded() async {
    let (store, transport) = await loadedEditableStore()
    store.selection.enterSelectExplicitly()
    store.selection.toggle(2)
    let reloadsBefore = await transport.callCount(Operations.BrowseStacksApiBrowseStacksGet.id)

    await transport.setStackEditOutcome(.conflict(.membershipChanged))
    await store.extractSelectionFromFocusedScene()

    #expect(store.sceneEditError == .conflict(.membershipChanged))
    #expect(SceneEditCopy.offersRetry(.conflict(.membershipChanged)) == false)
    // Nothing was changed server-side, so nothing is re-read: the window the reader is looking at
    // is still the truth.
    #expect(
      await transport.callCount(Operations.BrowseStacksApiBrowseStacksGet.id) == reloadsBefore)
    #expect(store.sceneExpanded == [5])

    store.dismissSceneEditError()
    #expect(store.sceneEditError == nil)
  }

  @Test("A 503 raises the busy answer with its wait, and the retry is offered")
  func aBusyFolderRaisesTheRetryableAnswer() async {
    let (store, transport) = await loadedEditableStore()
    await transport.setStackEditOutcome(.busy(retryAfterSeconds: 12))
    await store.splitFocusedScene()

    #expect(store.sceneEditError == .busy(retryAfterSeconds: 12))
    #expect(SceneEditCopy.offersRetry(.busy(retryAfterSeconds: 12)))
    #expect(SceneEditCopy.message(for: .busy(retryAfterSeconds: 12)).contains("12 seconds"))
  }

  /// THE FROZEN PAYLOAD (plan §Phase 4). The retry replays the edit the reader ASKED for — not the
  /// edit their current selection and focus would describe now. A reader waiting out a busy folder
  /// is exactly the reader who changes both in the meantime.
  @Test("The 503 retry replays the FROZEN payload — byte-identical after selection and focus moved")
  func theBusyRetryReplaysTheFrozenPayloadByteForByte() async throws {
    let (store, transport) = await loadedEditableStore()
    store.selection.enterSelectExplicitly()
    store.selection.toggle(2)
    store.selection.toggle(3)
    #expect(store.sceneExtractionSelection == [2, 3])

    // First the folder is busy; the retry then succeeds.
    await transport.enqueueStackEditOutcomes([
      .busy(retryAfterSeconds: 5),
      .success(editResult(stacks: [5, 9])),
    ])
    await transport.setBrowseStacksPage(
      page([
        stackItem(
          makeStackRow(id: 5, memberCount: 1, anchor: anchorT0, representative: makeImage(id: 1))),
        stackItem(
          makeStackRow(id: 9, memberCount: 2, anchor: anchorT0, representative: makeImage(id: 2))),
      ]))
    await transport.setStackMemberPage(members([1], stackID: 5), forStack: 5)
    await transport.setStackMemberPage(members([2, 3], stackID: 9), forStack: 9)

    await store.extractSelectionFromFocusedScene()
    #expect(store.sceneEditError == .busy(retryAfterSeconds: 5))

    // The reader changes BOTH inputs while they wait: a different selection and a different focus,
    // which would describe a different extraction entirely if the retry recomputed anything.
    store.selection.toggle(3)
    store.selection.toggle(1)
    store.focusedImageID = 1
    #expect(store.sceneExtractionSelection == [1, 2])

    await store.retrySceneEdit()

    let records = await transport.recordedStackEdits
    #expect(records.count == 2)
    let first = try #require(records.first)
    let second = try #require(records.last)
    // BYTE-IDENTICAL, not merely equivalent.
    #expect(first.body == second.body)
    #expect(first.path == second.path)
    #expect(decoded(second)["image_ids"] as? [Int] == [2, 3])
    #expect(store.sceneEditError == nil)
  }

  /// THE WIRING, not the store method (codex gate, blocker 1). SwiftUI dismisses an alert by
  /// running the `isPresented` binding's SETTER first and the tapped button's action after it —
  /// and the setter is `dismissSceneEditError()`, which clears the frozen payload. A retry action
  /// that read that payload when it RAN would therefore read nil and send nothing, which is the
  /// one thing this whole surface exists to prevent.
  ///
  /// So this test builds the alert's buttons the way the view does, fires them IN SWIFTUI'S ORDER,
  /// and asserts a second request actually went out and is byte-identical to the first.
  @Test("The alert's Retry survives the dismissal SwiftUI fires before it")
  func theAlertRetrySurvivesTheDismissalFiredBeforeIt() async throws {
    let (store, transport) = await loadedEditableStore()
    store.selection.enterSelectExplicitly()
    store.selection.toggle(2)
    store.selection.toggle(3)

    await transport.enqueueStackEditOutcomes([
      .busy(retryAfterSeconds: 5),
      .success(editResult(stacks: [5, 9])),
    ])
    await transport.setBrowseStacksPage(
      page([
        sceneItem(id: 5, count: 1, anchor: anchorT0, cover: 1),
        sceneItem(id: 9, count: 2, anchor: anchorT0, cover: 2),
      ]))
    await transport.setStackMemberPage(members([1], stackID: 5), forStack: 5)
    await transport.setStackMemberPage(members([2, 3], stackID: 9), forStack: 9)

    await store.extractSelectionFromFocusedScene()
    let failure = try #require(store.sceneEditError)

    // RENDER TIME: the alert is built while the refusal stands, exactly as the view builds it.
    let actions = SceneEditAlert.actions(for: failure, replaying: store.pendingSceneEdit)
    let retry = try #require(actions.first { $0.id == "sceneEditAlert.retry" })

    // SWIFTUI'S ORDER: the dismissal binding's setter runs FIRST…
    store.dismissSceneEditError()
    #expect(store.pendingSceneEdit == nil)
    // …and the button's own action only afterwards.
    retry.run(store)
    await waitForEdits(transport, count: 2)

    let records = await transport.recordedStackEdits
    #expect(records.count == 2, "the retry sent nothing after the dismissal cleared the payload")
    let first = try #require(records.first)
    let second = try #require(records.last)
    #expect(first.body == second.body)
    #expect(first.path == second.path)
    #expect(decoded(second)["image_ids"] as? [Int] == [2, 3])
  }

  @Test("The alert offers no Retry when there is nothing frozen to replay")
  func theAlertOffersNoRetryWithoutAFrozenPayload() {
    let withPayload = SceneEditAlert.actions(
      for: .busy(retryAfterSeconds: 5),
      replaying: .split(stackID: 5, atImageID: 2))
    #expect(withPayload.map(\.id) == ["sceneEditAlert.retry", "sceneEditAlert.dismiss"])
    // Same failure, no payload: the button that would replay nothing is not offered at all.
    #expect(
      SceneEditAlert.actions(for: .busy(retryAfterSeconds: 5), replaying: nil).map(\.id)
        == ["sceneEditAlert.dismiss"])
    // A refusal that is not retryable never offers it either, payload or not.
    #expect(
      SceneEditAlert.actions(
        for: .conflict(.membershipChanged), replaying: .split(stackID: 5, atImageID: 2)
      ).map(\.id) == ["sceneEditAlert.dismiss"])
  }

  @Test("Dismissing a busy answer abandons the retry — nothing replays afterwards")
  func dismissingTheBusyAnswerAbandonsTheRetry() async {
    let (store, transport) = await loadedEditableStore()
    await transport.setStackEditOutcome(.busy(retryAfterSeconds: nil))
    await store.splitFocusedScene()
    #expect(store.sceneEditError == .busy(retryAfterSeconds: nil))

    store.dismissSceneEditError()
    await store.retrySceneEdit()
    #expect(await transport.recordedStackEdits.count == 1)
    #expect(store.sceneEditError == nil)
  }

  @Test("Every refusal names its own reason, and only the busy one offers a retry")
  func everyRefusalNamesItsOwnReason() {
    let messages = [
      SceneEditCopy.message(for: .busy(retryAfterSeconds: nil)),
      SceneEditCopy.message(for: .conflict(.foreignFolderMember)),
      SceneEditCopy.message(for: .conflict(.membershipChanged)),
      SceneEditCopy.message(for: .refused),
      SceneEditCopy.message(for: .unreachable),
    ]
    #expect(Set(messages).count == messages.count, "two refusals say the same thing: \(messages)")
    for message in messages {
      #expect(message.contains("Nothing was changed"))
    }
    #expect(SceneEditCopy.message(for: .conflict(.foreignFolderMember)).contains("folder"))
    #expect(SceneEditCopy.offersRetry(.busy(retryAfterSeconds: nil)))
    #expect(SceneEditCopy.offersRetry(.refused) == false)
    #expect(SceneEditCopy.offersRetry(.unreachable) == false)
  }

  // MARK: - One edit at a time

  /// The time limit is not decoration. `waitUntilStackEditStarted()` is a CONTINUATION handshake —
  /// deterministic when the edit really goes out, and an indefinite wait when it does not, which
  /// is exactly the state a regression here produces. Bounded, that regression FAILS; unbounded it
  /// would hang the whole test run instead (observed, RED run 2026-09-01: with the derivations
  /// inert, this test blocked until the gate's own 1800s cap killed it).
  @Test(
    "A second action while an edit is genuinely in flight is refused, not queued",
    .timeLimit(.minutes(1)))
  func oneEditAtATime() async {
    let (store, transport) = await loadedEditableStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [5])))
    await transport.holdStackEditRequests(true)

    let running = Task { await store.splitFocusedScene() }
    await transport.waitUntilStackEditStarted()

    #expect(store.isSceneEditInFlight)
    #expect(store.canSplitFocusedScene == false)
    #expect(store.canMergeFocusedScene == false)
    await store.mergeFocusedScene(into: 6)
    #expect(await transport.recordedStackEdits.count == 1)

    await transport.holdStackEditRequests(false)
    await transport.releaseStackEdit()
    await running.value
    #expect(store.isSceneEditInFlight == false)
  }
}
