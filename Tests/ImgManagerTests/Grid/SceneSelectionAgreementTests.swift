import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP29 P4 (IMGMGR-455, plan Decision 5): Scene ▸ runs the SHIPPED focus-derived scene edits,
/// enabled only when the selection AGREES with the focused subject.
///
/// Every negative case keeps the shipped predicate TRUE, so the agreement term is what decides —
/// a disabled row against a store where the shipped predicate is already false would prove
/// nothing about this phase. Fixture: one folder, scenes 5 {1, 2, 3} and 6 {7, 8}, loose 20 and
/// 21; scene 5 open, the focus on its SECOND member (2), so Split is legal.
@MainActor
@Suite("Select bar — Scene ▸ selection agreement (WP29 P4)")
struct SceneSelectionAgreementTests {

  // MARK: - Fixtures

  private func makeImage(id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "raf", filename: "DSCF\(id).raf", folderId: 1, hasEdit: false,
      id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []), missing: false,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func scene(_ id: Int, count: Int, anchor: TimeInterval, cover: Int)
    -> Components.Schemas.StackBrowsePage.ItemsPayloadPayload
  {
    .init(
      value1: nil,
      value2: Components.Schemas.StackBrowseStackRow(
        anchorTakenAt: Date(timeIntervalSince1970: anchor), editedCount: 0, hasPick: false,
        kind: .stack, matchedCount: count, memberCount: count, pickedCount: 0,
        representative: makeImage(id: cover), stackId: id))
  }

  private func loose(_ id: Int) -> Components.Schemas.StackBrowsePage.ItemsPayloadPayload {
    .init(value1: .init(image: makeImage(id: id), kind: .image), value2: nil)
  }

  private func members(_ ids: [Int], of stackID: Int) -> Components.Schemas.StackMemberPage {
    Components.Schemas.StackMemberPage(
      items: ids.map { makeImage(id: $0) }, limit: 100, nextCursor: nil, stackId: stackID)
  }

  private func editResult(stacks: [Int], dissolved: [Int] = [])
    -> Components.Schemas.StackEditResult
  {
    Components.Schemas.StackEditResult(
      dissolvedStackIds: dissolved, loosenedImageIds: [], stackIds: stacks)
  }

  private func loadedStore(
    extraScene: Bool = false
  ) async -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let store = GridStore(
      service: GridService(client: ImgManagerAPIClient.make(transport: transport)))
    var items = [
      scene(5, count: 3, anchor: 1_700_000_000, cover: 1),
      scene(6, count: 2, anchor: 1_700_003_600, cover: 7),
    ]
    if extraScene { items.append(scene(10, count: 2, anchor: 1_700_007_200, cover: 11)) }
    items += [loose(20), loose(21)]
    await transport.setBrowseStacksPage(
      Components.Schemas.StackBrowsePage(items: items, limit: 100, nextCursor: nil))
    await transport.setStackMemberPage(members([1, 2, 3], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([7, 8], of: 6), forStack: 6)
    await transport.setStackMemberPage(members([11, 12], of: 10), forStack: 10)
    await store.selectShoot(folderID: 1)
    await store.setDisplayMode(.scene)
    await store.toggleSceneExpanded(5)
    store.focusedImageID = 2
    return (store, transport)
  }

  /// Select mode with exactly `ids` selected, the focus untouched.
  private func select(_ ids: [Int], in store: GridStore) {
    store.selection.enterSelectExplicitly()
    for id in ids { store.selection.toggle(id) }
  }

  private func enabled(_ entry: GridMoreMenuEntry, _ store: GridStore) -> Bool {
    entry.isEnabled(store)
  }

  private func run(_ entry: GridMoreMenuEntry, _ store: GridStore) {
    guard case .action(let action) = entry.surface else {
      Issue.record("\(entry.id) is not an action entry")
      return
    }
    action(store)
  }

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

  // MARK: - Per row: one positive, one negative, the shipped predicate TRUE throughout

  @Test("Merge: enabled on S = {f, m} ⊆ X; disabled when S holds a photo outside X")
  func mergeAgreement() async {
    let (store, _) = await loadedStore()
    await store.toggleSceneExpanded(6)
    select([2, 3], in: store)
    #expect(store.canMergeFocusedScene)
    #expect(enabled(SelectBarSceneMenu.merge, store))

    select([2, 7], in: store)
    #expect(store.canMergeFocusedScene, "the shipped predicate must hold for the negative")
    #expect(!enabled(SelectBarSceneMenu.merge, store))
  }

  @Test("Split: enabled on S = {f}; disabled on S = {f, m} and on S = {m}")
  func splitAgreement() async {
    let (store, _) = await loadedStore()
    select([2], in: store)
    #expect(store.canSplitFocusedScene)
    #expect(enabled(SelectBarSceneMenu.split, store))

    select([2, 3], in: store)
    #expect(store.canSplitFocusedScene)
    #expect(!enabled(SelectBarSceneMenu.split, store))

    select([3], in: store)
    #expect(store.canSplitFocusedScene)
    #expect(!enabled(SelectBarSceneMenu.split, store))
  }

  @Test("Extract: enabled on S = {f, m} ⊆ X; disabled when f ∉ S")
  func extractAgreement() async {
    let (store, _) = await loadedStore()
    select([2, 3], in: store)
    #expect(store.canExtractSelectionFromScene)
    #expect(enabled(SelectBarSceneMenu.extract, store))

    select([3], in: store)
    #expect(store.canExtractSelectionFromScene)
    #expect(!enabled(SelectBarSceneMenu.extract, store))
  }

  @Test("Absorb: enabled on S = {f}, f the focused loose photo; disabled on S = {g}, g ≠ f")
  func absorbAgreement() async {
    let (store, _) = await loadedStore()
    store.focusedImageID = 20
    select([20], in: store)
    #expect(store.canAbsorbFocusedPhoto)
    #expect(enabled(SelectBarSceneMenu.absorb, store))
    #expect(SelectBarSceneMenu.absorb.title(store) == SceneAbsorbCopy.offered)

    select([21], in: store)
    #expect(store.canAbsorbFocusedPhoto)
    #expect(!enabled(SelectBarSceneMenu.absorb, store))
    // Disabled by the selection, the row keeps the shipped title.
    #expect(SelectBarSceneMenu.absorb.title(store) == SceneAbsorbCopy.offered)
  }

  // MARK: - Empty selection, disagreement, the shipped predicate still gates

  @Test("An empty selection disables all four, even where the shipped predicates hold")
  func anEmptySelectionDisablesAllFour() async {
    let (store, _) = await loadedStore()
    select([], in: store)
    #expect(store.canMergeFocusedScene && store.canSplitFocusedScene)
    #expect(SelectBarSceneMenu.entries.allSatisfy { !$0.isEnabled(store) })
    // The two predicates that CAN hold without a selection are asserted above; extraction's own
    // predicate needs a chosen member, so the pure function carries its empty case.
    let subject = SceneEditSubject(stackID: 5, focusedImageID: 2)
    #expect(!SceneSelectionAgreement.merge(selection: [], subject: subject, members: [1, 2, 3]))
    #expect(!SceneSelectionAgreement.split(selection: [], subject: subject))
    #expect(!SceneSelectionAgreement.extract(selection: [], subject: subject, members: [1, 2, 3]))
    #expect(
      !SceneSelectionAgreement.absorb(
        selection: [], subject: SceneAbsorbSubject(imageID: 20, folderID: 1)))
    // Outside Select there is no selection at all, whatever the membership says.
    store.done()
    #expect(!SceneSelectionAgreement.agrees(.split, in: store))
  }

  @Test("Focus on f, selection a different member m: all four disabled; S = {f} enables Split")
  func focusAndSelectionDisagreementDisablesAllFour() async {
    let (store, _) = await loadedStore()
    select([3], in: store)
    #expect(store.focusedImageID == 2)
    #expect(store.canSplitFocusedScene && store.canExtractSelectionFromScene)
    #expect(SelectBarSceneMenu.entries.allSatisfy { !$0.isEnabled(store) })

    select([2], in: store)
    #expect(enabled(SelectBarSceneMenu.split, store), "positive control: agreement enables Split")
  }

  @Test("The shipped predicate still gates: S = {f} with f the FIRST member keeps Split disabled")
  func theShippedPredicateStillGates() async {
    let (store, _) = await loadedStore()
    store.focusedImageID = 1
    select([1], in: store)
    #expect(SceneSelectionAgreement.agrees(.split, in: store))
    #expect(!store.canSplitFocusedScene)
    #expect(!enabled(SelectBarSceneMenu.split, store))
  }

  // MARK: - What each row submits — exactly what the shipped action sent before P4

  @Test("Split here submits split(stackID: X, atImageID: f) and the focus follows f")
  func splitSubmitsTheShippedRequest() async throws {
    let (store, transport) = await loadedStore()
    select([2], in: store)
    await transport.setStackEditOutcome(.success(editResult(stacks: [5, 9])))
    await transport.setBrowseStacksPage(
      Components.Schemas.StackBrowsePage(
        items: [
          scene(5, count: 1, anchor: 1_700_000_000, cover: 1),
          scene(9, count: 2, anchor: 1_700_000_000, cover: 2),
        ], limit: 100, nextCursor: nil))
    await transport.setStackMemberPage(members([1], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([2, 3], of: 9), forStack: 9)

    run(SelectBarSceneMenu.split, store)
    await waitForEdits(transport, count: 1)

    let records = await transport.recordedStackEdits
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.path.hasSuffix("/api/stacks/5/split"))
    #expect(decoded(record)["at_image_id"] as? Int == 2)
    #expect(decoded(record).count == 1)
    // `focusedImageID` is coordinator metadata, never on the wire (GridStore performSceneEdit):
    // it is observed as the focus the coordinator restores.
    for _ in 0..<200 where store.focusedImageID != 2 || store.isSceneEditInFlight {
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(store.focusedImageID == 2)
  }

  @Test("Extract selected submits extract(stackID: X, imageIDs: S in member order)")
  func extractSubmitsTheShippedRequest() async throws {
    let (store, transport) = await loadedStore()
    select([3, 2], in: store)
    await transport.setStackEditOutcome(.success(editResult(stacks: [5, 9])))
    await transport.setBrowseStacksPage(
      Components.Schemas.StackBrowsePage(
        items: [
          scene(5, count: 1, anchor: 1_700_000_000, cover: 1),
          scene(9, count: 2, anchor: 1_700_000_000, cover: 2),
        ], limit: 100, nextCursor: nil))
    await transport.setStackMemberPage(members([1], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([2, 3], of: 9), forStack: 9)

    run(SelectBarSceneMenu.extract, store)
    await waitForEdits(transport, count: 1)

    let records = await transport.recordedStackEdits
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.path.hasSuffix("/api/stacks/5/extract"))
    #expect(decoded(record)["image_ids"] as? [Int] == [2, 3])
    #expect(decoded(record).count == 1)
    for _ in 0..<200 where store.focusedImageID != 2 || store.isSceneEditInFlight {
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(store.focusedImageID == 2)
  }

  @Test("Merge into… submits merge(stackIDs: [X, target]) through the guarded picker")
  func mergeSubmitsTheShippedRequest() async throws {
    let (store, transport) = await loadedStore()
    select([2, 3], in: store)
    run(SelectBarSceneMenu.merge, store)
    #expect(store.isSceneMergePickerPresented)
    await transport.setStackEditOutcome(.success(editResult(stacks: [5], dissolved: [6])))

    await SceneMergePicker.submit(
      kind: .mergeFocusedScene, targetStackID: 6, store: store,
      submissionGuard: SceneSelectionAgreement.pickerGuard(for: .mergeFocusedScene))

    let records = await transport.recordedStackEdits
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.path.hasSuffix("/api/stacks/merge"))
    #expect(decoded(record)["stack_ids"] as? [Int] == [5, 6])
    #expect(decoded(record).count == 1)
  }

  @Test("Add to scene… submits absorb(stackID: target, imageIDs: [f]) through the guarded picker")
  func absorbSubmitsTheShippedRequest() async throws {
    let (store, transport) = await loadedStore()
    store.focusedImageID = 20
    select([20], in: store)
    run(SelectBarSceneMenu.absorb, store)
    #expect(store.isSceneAbsorbPickerPresented)
    await transport.setStackEditOutcome(.success(editResult(stacks: [5])))

    await SceneMergePicker.submit(
      kind: .absorbLoosePhotograph, targetStackID: 5, store: store,
      submissionGuard: SceneSelectionAgreement.pickerGuard(for: .absorbLoosePhotograph))

    let records = await transport.recordedStackEdits
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.path.hasSuffix("/api/stacks/5/absorb"))
    #expect(decoded(record)["image_ids"] as? [Int] == [20])
  }

  // MARK: - R4-B1: agreement re-checked at submission

  /// Open scenes X = 5 and Y = 6, S = {2, 3} ⊆ X, focus 2, the Merge picker open. A refresh moves
  /// 2 into Y while keeping both scenes open, S and the focus — so the shipped re-derivation now
  /// names Y. The guarded submit records NOTHING; the unguarded (shipped-default) submit shows
  /// what it would have sent, which is why the guard exists.
  @Test("R4-B1: a refresh that moves f into another scene makes the Merge picker submit nothing")
  func mergePickerSubmitsNothingAfterARefreshMovesTheFocus() async throws {
    let (store, transport) = await loadedStore(extraScene: true)
    await store.toggleSceneExpanded(6)
    select([2, 3], in: store)
    store.focusedImageID = 2
    run(SelectBarSceneMenu.merge, store)
    #expect(store.isSceneMergePickerPresented)

    await transport.setStackMemberPage(members([1, 3], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([7, 2, 8], of: 6), forStack: 6)
    #expect(await store.authoritativeRefresh())
    #expect(store.sceneExpanded.isSuperset(of: [5, 6]))
    #expect(store.focusedImageID == 2)
    #expect(store.selection.members == [2, 3])
    #expect(store.sceneEditSubject == SceneEditSubject(stackID: 6, focusedImageID: 2))

    await transport.setStackEditOutcome(.success(editResult(stacks: [6], dissolved: [10])))
    await SceneMergePicker.submit(
      kind: .mergeFocusedScene, targetStackID: 10, store: store,
      submissionGuard: SceneSelectionAgreement.pickerGuard(for: .mergeFocusedScene))
    #expect(await transport.recordedStackEdits.isEmpty)

    // The named mutant: the shipped default guard would have merged the NEW focused scene.
    await SceneMergePicker.submit(
      kind: .mergeFocusedScene, targetStackID: 10, store: store, submissionGuard: { _ in true })
    let mutant = await transport.recordedStackEdits
    #expect(mutant.count == 1)
    #expect(mutant.first.flatMap { decoded($0)["stack_ids"] as? [Int] } == [6, 10])
  }

  @Test("R4-B1 control: without the refresh the guarded Merge picker sends merge([X, Z])")
  func mergePickerControlWithoutARefresh() async throws {
    let (store, transport) = await loadedStore(extraScene: true)
    await store.toggleSceneExpanded(6)
    select([2, 3], in: store)
    run(SelectBarSceneMenu.merge, store)
    await transport.setStackEditOutcome(.success(editResult(stacks: [5], dissolved: [10])))

    await SceneMergePicker.submit(
      kind: .mergeFocusedScene, targetStackID: 10, store: store,
      submissionGuard: SceneSelectionAgreement.pickerGuard(for: .mergeFocusedScene))

    let records = await transport.recordedStackEdits
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(decoded(record)["stack_ids"] as? [Int] == [5, 10])
  }

  /// Absorb: no refresh can make S disagree while the shipped call would still fire (a refresh
  /// only prunes the selection and nils a vanished focus, and both already stop the shipped
  /// absorb), so the interleaving is a selection change while the sheet stands open.
  @Test("R4-B1: the Absorb picker submits nothing once the selection disagrees; control sends one")
  func absorbPickerSubmitsNothingOnceTheSelectionDisagrees() async throws {
    let (store, transport) = await loadedStore()
    store.focusedImageID = 20
    select([20], in: store)
    run(SelectBarSceneMenu.absorb, store)
    #expect(store.isSceneAbsorbPickerPresented)
    await transport.setStackEditOutcome(.success(editResult(stacks: [5])))

    store.selection.toggle(21)
    #expect(store.canAbsorbFocusedPhoto, "the shipped predicate still holds")
    await SceneMergePicker.submit(
      kind: .absorbLoosePhotograph, targetStackID: 5, store: store,
      submissionGuard: SceneSelectionAgreement.pickerGuard(for: .absorbLoosePhotograph))
    #expect(await transport.recordedStackEdits.isEmpty)

    store.selection.toggle(21)
    await SceneMergePicker.submit(
      kind: .absorbLoosePhotograph, targetStackID: 5, store: store,
      submissionGuard: SceneSelectionAgreement.pickerGuard(for: .absorbLoosePhotograph))
    let records = await transport.recordedStackEdits
    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.path.hasSuffix("/api/stacks/5/absorb"))
    #expect(decoded(record)["image_ids"] as? [Int] == [20])
  }
}
