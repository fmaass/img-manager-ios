import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-347: absorbing a LOOSE photograph into an existing scene — the gesture the scene-edit
/// family was missing, and the one the owner's device pass could not find ("i dont think this
/// works im missing a menu basically to do so", TestFlight 0.11.0 (14)).
///
/// Every test drives a REAL loaded Scene window through `GridStubTransport`, for the reason its
/// WP14 P4 sibling states: the whole subject rule is about what the server put on screen, and an
/// assertion about enablement against an empty store would pass for reasons that have nothing to
/// do with this lane. So each disablement comes with a positive control that DOES fire.
///
/// What is NOT claimed here: the server's own guards — the folder lock, the rowcount fence, the
/// derivation fence — are backend gates (`tests/test_api_stack_edit.py`, IMGMGR-289). Nothing
/// here stubs them, and the client's job is only to ask the right question and to say what came
/// back.
@MainActor
@Suite("GridStore — absorbing a loose photograph (IMGMGR-347)")
struct GridStoreAbsorbTests {

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

  private func page(_ items: [Components.Schemas.StackBrowsePage.ItemsPayloadPayload])
    -> Components.Schemas.StackBrowsePage
  {
    Components.Schemas.StackBrowsePage(items: items, limit: 100, nextCursor: nil)
  }

  private func members(_ ids: [Int], stackID: Int) -> Components.Schemas.StackMemberPage {
    Components.Schemas.StackMemberPage(
      items: ids.map { makeImage(id: $0) }, limit: 100, nextCursor: nil, stackId: stackID)
  }

  private func editResult(stacks: [Int]) -> Components.Schemas.StackEditResult {
    Components.Schemas.StackEditResult(
      dissolvedStackIds: [], loosenedImageIds: [], stackIds: stacks)
  }

  private let anchorT0 = Date(timeIntervalSince1970: 1_700_000_000)
  private let anchorT1 = Date(timeIntervalSince1970: 1_700_003_600)

  /// The absorb fixture: two scenes of folder 1, one LOOSE photograph of folder 1 (20), and one
  /// loose photograph of ANOTHER folder (40) — so "the same folder" is a difference rather than a
  /// coincidence. Scene 6 is anchored later than 5, so the offered order is a fact too.
  private func loadedAbsorbStore() async -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let store = GridStore(service: GridService(client: client))
    await transport.setBrowseStacksPage(
      page([
        stackItem(
          makeStackRow(id: 5, memberCount: 3, anchor: anchorT0, representative: makeImage(id: 1))),
        stackItem(
          makeStackRow(id: 6, memberCount: 2, anchor: anchorT1, representative: makeImage(id: 7))),
        imageItem(makeImage(id: 20)),
        imageItem(makeImage(id: 40, folderID: 2)),
      ]))
    await transport.setStackMemberPage(members([1, 2, 3], stackID: 5), forStack: 5)
    await transport.setStackMemberPage(members([7, 8], stackID: 6), forStack: 6)
    await store.selectShoot(folderID: 1)
    await store.setDisplayMode(.scene)
    store.focusedImageID = 20
    return (store, transport)
  }

  private func decoded(_ record: GridStubTransport.RecordedStackEdit) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: record.body)) as? [String: Any] ?? [:]
  }

  private func waitForEdits(_ transport: GridStubTransport, count: Int) async {
    for _ in 0..<200 {
      if await transport.recordedStackEdits.count >= count { return }
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  // MARK: - The subject: a photograph the STREAM says is loose

  @Test("The subject is the focused LOOSE photograph — and it is exactly where the others are not")
  func theSubjectIsTheFocusedLoosePhotograph() async {
    let (store, _) = await loadedAbsorbStore()

    #expect(store.sceneAbsorbSubject == SceneAbsorbSubject(imageID: 20, folderID: 1))
    // The mirror image, in the same breath: the three WP14 rows have no subject here, which is
    // the state the owner's device pass hit.
    #expect(store.sceneEditSubject == nil)

    // A member of an OPEN scene is not loose — and now the other subject exists instead.
    await store.toggleSceneExpanded(5)
    store.focusedImageID = 2
    #expect(store.sceneAbsorbSubject == nil)
    #expect(store.sceneEditSubject == SceneEditSubject(stackID: 5, focusedImageID: 2))

    // Nothing focused at all.
    store.focusedImageID = nil
    #expect(store.sceneAbsorbSubject == nil)

    // Flat mode is not this lane's window: scenes are not being served there.
    store.focusedImageID = 20
    await store.setDisplayMode(.flat)
    #expect(store.sceneAbsorbSubject == nil)

    // Positive control for the four nils above.
    await store.setDisplayMode(.scene)
    store.focusedImageID = 20
    #expect(store.sceneAbsorbSubject == SceneAbsorbSubject(imageID: 20, folderID: 1))
  }

  @Test("The targets are the loose photograph's OWN folder's scenes, in capture order")
  func theTargetsAreTheSameFoldersScenesInCaptureOrder() async {
    let (store, _) = await loadedAbsorbStore()

    #expect(store.sceneAbsorbTargets.map(\.stackID) == [5, 6])
    #expect(store.sceneAbsorbTargets.map(\.memberCount) == [3, 2])
    #expect(store.canAbsorbFocusedPhoto)
    #expect(store.sceneAbsorbUnavailability == nil)

    // A loose photograph of another folder: the scenes on screen are not its scenes, so it has
    // nowhere to go and the row says so rather than offering a guaranteed 409.
    store.focusedImageID = 40
    #expect(store.sceneAbsorbSubject == SceneAbsorbSubject(imageID: 40, folderID: 2))
    #expect(store.sceneAbsorbTargets.isEmpty)
    #expect(store.canAbsorbFocusedPhoto == false)
    #expect(store.sceneAbsorbUnavailability == .noSceneInTheSameFolderLoaded)
  }

  // MARK: - AC2: the row is never an inert control

  @Test("Every unavailable state names ITS OWN reason, and the words follow the reason")
  func everyUnavailableStateNamesItsOwnReason() async {
    let (store, transport) = await loadedAbsorbStore()

    store.focusedImageID = nil
    #expect(store.sceneAbsorbUnavailability == .noLoosePhotographFocused)
    #expect(
      SceneAbsorbCopy.title(for: store.sceneAbsorbUnavailability)
        == "Add to scene — focus a loose photograph")

    store.focusedImageID = 40
    #expect(store.sceneAbsorbUnavailability == .noSceneInTheSameFolderLoaded)
    #expect(
      SceneAbsorbCopy.title(for: store.sceneAbsorbUnavailability)
        == "Add to scene — no scene in view yet")

    // One edit at a time: with an absorb genuinely on the wire, the row says that instead.
    store.focusedImageID = 20
    await transport.holdStackEditRequests(true)
    await transport.setStackEditOutcome(.success(editResult(stacks: [6])))
    let running = Task { await store.absorbFocusedPhoto(into: 6) }
    await transport.waitUntilStackEditStarted()
    #expect(store.sceneAbsorbUnavailability == .anotherEditIsRunning)
    #expect(
      SceneAbsorbCopy.title(for: store.sceneAbsorbUnavailability)
        == "Add to scene — an edit is running")
    await transport.holdStackEditRequests(false)
    await transport.releaseStackEdit()
    await running.value

    // Positive control: offered, the row is the plain invitation and nothing else.
    #expect(SceneAbsorbCopy.title(for: nil) == "Add to scene…")
  }

  @Test("While the absorb is unavailable nothing is raised and nothing is sent")
  func whileUnavailableNothingIsRaisedAndNothingIsSent() async {
    let (store, transport) = await loadedAbsorbStore()
    store.focusedImageID = 40  // a loose photograph with no scene of its own folder in view

    store.presentSceneAbsorbPicker()
    #expect(store.isSceneAbsorbPickerPresented == false)
    await store.absorbFocusedPhoto(into: 5)
    #expect(await transport.recordedStackEdits.isEmpty)

    // Positive control: with the folder's own loose photograph focused, the sheet DOES rise and
    // the request DOES go out.
    store.focusedImageID = 20
    store.presentSceneAbsorbPicker()
    #expect(store.isSceneAbsorbPickerPresented)
    await transport.setStackEditOutcome(.success(editResult(stacks: [6])))
    await store.absorbFocusedPhoto(into: 6)
    #expect(await transport.recordedStackEdits.count == 1)
    #expect(store.isSceneAbsorbPickerPresented == false)
  }

  // MARK: - The request

  @Test("The absorb names the PICKED scene in the path and the focused photograph in the body")
  func theAbsorbNamesThePickedSceneAndTheFocusedPhotograph() async throws {
    let (store, transport) = await loadedAbsorbStore()
    await transport.setStackEditOutcome(.success(editResult(stacks: [6])))

    await store.absorbFocusedPhoto(into: 6)

    let records = await transport.recordedStackEdits
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.operationID == Operations.AbsorbIntoStackApiStacksStackIdAbsorbPost.id)
    #expect(record.path.hasSuffix("/api/stacks/6/absorb"))
    // EXACTLY the focused photograph: the row's enablement is derived from the focus alone, so
    // the request's subject and the control's subject are the same thing.
    #expect(decoded(record)["image_ids"] as? [Int] == [20])
  }

  @Test("A target that left the window while the sheet stood open is a no-op, not a request")
  func aTargetThatLeftTheWindowIsANoOp() async {
    let (store, transport) = await loadedAbsorbStore()
    // The sheet is built from THIS list, scene 6 included, and it stands while the window moves.
    #expect(store.sceneAbsorbTargets.map(\.stackID) == [5, 6])
    store.presentSceneAbsorbPicker()

    // The window is re-read and scene 6 is no longer in it — dissolved by another client, or
    // simply no longer on the page the reader is holding.
    await transport.setBrowseStacksPage(
      page([
        stackItem(
          makeStackRow(id: 5, memberCount: 3, anchor: anchorT0, representative: makeImage(id: 1))),
        imageItem(makeImage(id: 20)),
      ]))
    await store.selectShoot(folderID: 1)
    store.focusedImageID = 20
    // Doubles as the control that the reload really happened in the Scene window: a lost scene
    // mode would leave NO targets at all, not this one.
    #expect(store.sceneAbsorbTargets.map(\.stackID) == [5])

    // The reader taps the row their sheet is still showing.
    await store.absorbFocusedPhoto(into: 6)
    #expect(await transport.recordedStackEdits.isEmpty)

    // Positive control on the same store: the target that IS still in the window goes out.
    await transport.setStackEditOutcome(.success(editResult(stacks: [5])))
    await store.absorbFocusedPhoto(into: 5)
    #expect(await transport.recordedStackEdits.count == 1)
  }

  // MARK: - After the edit (ADR-0008's reload/reopen/focus semantics)

  /// The same four steps every other topology edit gets, proven on the absorb: the window is
  /// re-read, the RESULT scene is reopened, its membership is completed past page one, and the
  /// reader is put back on the photograph they were on — which is now inside the scene.
  @Test("The absorbed photograph ends focused inside the reopened, completed scene")
  func theAbsorbedPhotographEndsFocusedInsideTheReopenedScene() async {
    let (store, transport) = await loadedAbsorbStore()
    #expect(store.sceneExpanded.isEmpty)

    // What the server serves AFTER the absorb: 20 is a member of scene 6 and is no longer a row
    // of the stream.
    await transport.setBrowseStacksPage(
      page([
        stackItem(
          makeStackRow(id: 5, memberCount: 3, anchor: anchorT0, representative: makeImage(id: 1))),
        stackItem(
          makeStackRow(id: 6, memberCount: 3, anchor: anchorT1, representative: makeImage(id: 7))),
        imageItem(makeImage(id: 40, folderID: 2)),
      ]))
    await transport.setStackMemberPage(members([7, 8, 20], stackID: 6), forStack: 6)
    await transport.setStackEditOutcome(.success(editResult(stacks: [6])))

    await store.absorbFocusedPhoto(into: 6)

    #expect(store.sceneEditError == nil)
    #expect(store.sceneExpanded == [6], "the scene the photograph joined was not reopened")
    #expect(store.sceneMembers[6]?.map(\.id) == [7, 8, 20])
    #expect(store.focusedImageID == 20, "the reader was not put back on their own photograph")
    // …and the photograph is no longer offered as a loose subject, because the stream stopped
    // serving it as one.
    #expect(store.sceneAbsorbSubject == nil)
  }

  /// The result scene can be perfectly real and simply not on the reloaded FIRST page — the
  /// reader had scrolled. The coordinator's unconditional ensure (`GET /api/stacks/{id}`) is what
  /// keeps the reopen, the completion and the focus from being lost with it.
  @Test("A result scene missing from page one is fetched back rather than dropped")
  func aResultSceneMissingFromPageOneIsFetchedBack() async {
    let (store, transport) = await loadedAbsorbStore()

    await transport.setBrowseStacksPage(
      page([
        stackItem(
          makeStackRow(id: 5, memberCount: 3, anchor: anchorT0, representative: makeImage(id: 1)))
      ]))
    await transport.setStackRow(
      makeStackRow(id: 6, memberCount: 3, anchor: anchorT1, representative: makeImage(id: 7)),
      forStack: 6)
    await transport.setStackMemberPage(members([7, 8, 20], stackID: 6), forStack: 6)
    await transport.setStackEditOutcome(.success(editResult(stacks: [6])))

    await store.absorbFocusedPhoto(into: 6)

    #expect(store.sceneRows.contains { $0.displayID == .stack(6) })
    #expect(store.sceneExpanded == [6])
    #expect(store.focusedImageID == 20)
  }

  // MARK: - The refusals, typed

  @Test("A 404 says the thing is gone — a distinct answer from a refused edit, with no Retry")
  func aVanishedSubjectIsItsOwnAnswer() async {
    let (store, transport) = await loadedAbsorbStore()
    let reloadsBefore = await transport.callCount(Operations.BrowseStacksApiBrowseStacksGet.id)
    await transport.setStackEditOutcome(.vanished(code: "unknown_image"))

    await store.absorbFocusedPhoto(into: 6)

    #expect(store.sceneEditError == .vanished)
    #expect(store.pendingSceneEdit == nil, "a vanished subject must not be replayable")
    #expect(SceneEditCopy.offersRetry(.vanished) == false)
    #expect(SceneEditCopy.message(for: .vanished).contains("no longer in the library"))
    #expect(SceneEditCopy.message(for: .vanished) != SceneEditCopy.message(for: .refused))
    // Nothing was changed server-side, so nothing is re-read.
    #expect(
      await transport.callCount(Operations.BrowseStacksApiBrowseStacksGet.id) == reloadsBefore)
  }

  /// The contract gives `membership_changed` TWO causes (openapi.json, `StackExtractConflict`):
  /// for merge, split and extract the SCENE moved under the request; for an absorb the target
  /// scene may be untouched and it is the PHOTOGRAPH that "stopped being loose between the check
  /// and the write". The extraction's sentence sends the reader to look at the wrong thing, so
  /// the absorb has its own — keyed on the edit, pinned here.
  @Test("The absorb's membership conflict names the photograph, never the target scene")
  func theAbsorbsMembershipConflictNamesThePhotographNotTheScene() async {
    let (store, transport) = await loadedAbsorbStore()
    await transport.setStackEditOutcome(.conflict(.membershipChanged))

    await store.absorbFocusedPhoto(into: 6)

    #expect(store.sceneEditError == .conflict(.membershipChanged))
    #expect(store.sceneEditErrorKind == .absorb, "the refusal lost the edit it belongs to")

    let absorbed = SceneEditCopy.message(for: .conflict(.membershipChanged), of: .absorb)
    let extracted = SceneEditCopy.message(for: .conflict(.membershipChanged), of: .extract)
    #expect(absorbed != extracted, "the absorb repeats the extraction's sentence")
    #expect(absorbed.hasPrefix("That photograph"), "the absorb's message: '\(absorbed)'")
    #expect(absorbed.contains("stopped being loose"))
    #expect(absorbed.contains("This scene changed") == false)
    // The specialisation does not rewrite the family: the three membership edits keep their
    // sentence, and a caller with no edit in hand still gets it.
    #expect(
      extracted == "This scene changed while the edit was being prepared. Nothing was changed.")
    #expect(SceneEditCopy.message(for: .conflict(.membershipChanged)) == extracted)
    #expect(SceneEditCopy.message(for: .conflict(.membershipChanged), of: .merge) == extracted)
    // The retry rule is untouched: a conflict asks a DIFFERENT question, whichever edit got it.
    #expect(SceneEditCopy.offersRetry(.conflict(.membershipChanged)) == false)
    #expect(store.pendingSceneEdit == nil)

    store.dismissSceneEditError()
    #expect(store.sceneEditErrorKind == nil, "the kind outlived the refusal it described")
  }

  @Test("A 409 on the absorb surfaces the typed reason and reloads nothing")
  func aConflictIsSurfacedAndNothingIsReloaded() async {
    let (store, transport) = await loadedAbsorbStore()
    let reloadsBefore = await transport.callCount(Operations.BrowseStacksApiBrowseStacksGet.id)
    await transport.setStackEditOutcome(.conflict(.foreignFolderMember))

    await store.absorbFocusedPhoto(into: 6)

    #expect(store.sceneEditError == .conflict(.foreignFolderMember))
    #expect(store.pendingSceneEdit == nil)
    #expect(
      await transport.callCount(Operations.BrowseStacksApiBrowseStacksGet.id) == reloadsBefore)
    store.dismissSceneEditError()
    #expect(store.sceneEditError == nil)
  }

  /// The busy answer is the one refusal that means "ask again, unchanged" — so it is the one that
  /// keeps the payload, and the replay must ask the SAME question even though the reader moved
  /// their focus while they waited.
  @Test("A 503 freezes the absorb, and the retry replays it byte-identically")
  func theBusyRetryReplaysTheFrozenAbsorb() async throws {
    let (store, transport) = await loadedAbsorbStore()
    await transport.enqueueStackEditOutcomes([
      .busy(retryAfterSeconds: 9),
      .success(editResult(stacks: [6])),
    ])

    await store.absorbFocusedPhoto(into: 6)
    #expect(store.sceneEditError == .busy(retryAfterSeconds: 9))
    #expect(SceneEditCopy.offersRetry(.busy(retryAfterSeconds: 9)))

    // The reader moves on while the folder is busy — a recomputed retry would absorb a different
    // photograph into the same scene.
    store.focusedImageID = 40
    #expect(store.sceneAbsorbSubject == SceneAbsorbSubject(imageID: 40, folderID: 2))

    let frozen = try #require(store.pendingSceneEdit)
    #expect(frozen == .absorb(stackID: 6, imageIDs: [20], focusedImageID: 20))
    await store.replaySceneEdit(frozen)
    await waitForEdits(transport, count: 2)

    let records = await transport.recordedStackEdits
    #expect(records.count == 2)
    let first = try #require(records.first)
    let second = try #require(records.last)
    #expect(first.body == second.body)
    #expect(first.path == second.path)
    #expect(decoded(second)["image_ids"] as? [Int] == [20])
    #expect(store.sceneEditError == nil)
  }
}
