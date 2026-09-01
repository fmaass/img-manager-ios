import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP14 lane B — the in-place member band (IMGMGR-240) and the ✓N pick count (IMGMGR-241).
///
/// Both stories change what a scene LOOKS like, and both are pinned here at the store/derivation
/// level rather than in a screenshot, because both are really claims about a sequence: which rows
/// the grid is asked to draw, and what the card's own numbers say. The fixtures are the ones
/// `GridStoreSceneTests` established — a loose photograph, one scene, and a cover id (900) that
/// appears nowhere else, so a row naming 900 can only have come from the card.
@MainActor
@Suite("Scene band and pick count — the card swaps out, the ✓N counts")
struct SceneBandTests {

  // MARK: - Fixtures

  private func makeImage(
    id: Int, mark: Components.Schemas.MarkView.StatePayload = .none, revision: String = "r0",
    hasEdit: Bool = false, captured: Date? = nil
  ) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, capturedAt: captured, ext: "raf", filename: "DSCF\(id).raf", folderId: 1,
      hasEdit: hasEdit, id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(revision: revision, state: mark, tags: []), missing: false,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStackRow(
    id: Int, memberCount: Int = 3, hasPick: Bool = false, matchedCount: Int = 3,
    pickedCount: Int = 0, anchor: Date? = nil,
    representative: Components.Schemas.ImageSummary
  ) -> Components.Schemas.StackBrowseStackRow {
    Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: anchor, hasPick: hasPick, kind: .stack, matchedCount: matchedCount,
      memberCount: memberCount, pickedCount: pickedCount, representative: representative,
      stackId: id)
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

  /// One flat shoot behind it, then a Scene page: a loose photograph (10) and one scene (5) whose
  /// cover is 900 and whose badge says one member is already picked.
  private func loadedSceneStore(pickedCount: Int = 1) async -> (GridStore, GridStubTransport) {
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
              id: 5, memberCount: 3, hasPick: pickedCount > 0, matchedCount: 2,
              pickedCount: pickedCount, anchor: Date(timeIntervalSince1970: 1_700_000_000),
              representative: cover)),
        ], nextCursor: "scene-cursor"))
    await store.setDisplayMode(.scene)
    return (store, transport)
  }

  private func currentStackRow(_ store: GridStore, at index: Int)
    -> Components.Schemas.StackBrowseStackRow?
  {
    guard store.sceneRows.indices.contains(index),
      case .stack(let row) = store.sceneRows[index]
    else { return nil }
    return row
  }

  // MARK: - IMGMGR-240: the card is the CLOSED representation, so opening swaps it out

  @Test("An expanded scene renders exactly its members — the card leaves the sequence")
  func expandedSceneReplacesItsCardWithItsMembers() async {
    let (store, transport) = await loadedSceneStore()
    await transport.setStackMemberPage(
      .init(
        items: [
          makeImage(id: 501, captured: Date(timeIntervalSince1970: 1_700_000_000)),
          makeImage(id: 502, captured: Date(timeIntervalSince1970: 1_700_000_060)),
          makeImage(id: 503, captured: Date(timeIntervalSince1970: 1_700_000_120)),
        ], limit: 100, nextCursor: nil, stackId: 5),
      forStack: 5)

    // Collapsed first — the control case, and the half that must NOT change.
    #expect(store.sceneDisplayRows.map(\.id) == [.image(10), .stack(5)])

    await store.toggleSceneExpanded(5)

    // The claim: N members, zero cards, in the scene's own position in the stream.
    let rows = store.sceneDisplayRows
    #expect(rows.map(\.id) == [.image(10), .image(501), .image(502), .image(503)])
    #expect(rows.contains { if case .stack = $0 { return true } else { return false } } == false)
    // No image id twice — the cover used to be drawn as the card AND again as the member it is.
    let ids = rows.compactMap(\.id.imageID)
    #expect(Set(ids).count == ids.count)
    // The served rows are untouched: the swap is a DISPLAY derivation, so the scene keeps its
    // place in capture order (the stored anchor) and its cursor.
    #expect(store.sceneRows.count == 2)
    #expect(
      currentStackRow(store, at: 1)?.anchorTakenAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(currentStackRow(store, at: 1)?.representative.id == 900)
    #expect(store.sceneNextCursor == "scene-cursor")
    // Write-safety, both directions: expanded members ARE actionable, and the cover never is.
    #expect(store.actionableImages.map(\.id) == [10, 501, 502, 503])
    #expect(store.actionableImages.contains { $0.id == 900 } == false)
  }

  @Test("A scene opened but not yet loaded keeps its card — never zero rows")
  func expandedButUnloadedSceneKeepsItsCard() async {
    let (store, transport) = await loadedSceneStore()
    await transport.holdStackMembersRequests(true)
    await transport.setStackMemberPage(
      .init(items: [makeImage(id: 501)], limit: 100, nextCursor: nil, stackId: 5), forStack: 5)

    let opening = Task { await store.toggleSceneExpanded(5) }
    await transport.waitUntilStackMembersStarted()

    // Expansion is committed before the membership settles. Without the card there would be
    // nothing on screen for this scene at all — and no way back out of the state.
    let rows = store.sceneDisplayRows
    #expect(rows.map(\.id) == [.image(10), .stack(5)])
    guard case .stack(_, let isExpanded) = rows[1] else {
      Issue.record("row 1 is not a stack row")
      await transport.releaseStackMembers()
      await opening.value
      await transport.holdStackMembersRequests(false)
      return
    }
    #expect(isExpanded)
    // And it is still not a write target while it waits.
    #expect(store.actionableImages.map(\.id) == [10])

    await transport.releaseStackMembers()
    await opening.value
    await transport.holdStackMembersRequests(false)

    #expect(store.sceneDisplayRows.map(\.id) == [.image(10), .image(501)])
  }

  // MARK: - IMGMGR-241: ✓N is a count, and it moves when a member is marked

  @Test("The touched scene's pick count comes back from the server row and merges in place")
  func pickCountMergesFromTheServerRow() async {
    let (store, transport) = await loadedSceneStore(pickedCount: 1)
    await transport.setStackMemberPage(
      .init(
        items: [makeImage(id: 501, revision: "m-rev-1")], limit: 100, nextCursor: nil, stackId: 5),
      forStack: 5)
    await store.toggleSceneExpanded(5)

    // The server's answer after the pick: two members picked now, and the cover moved to one.
    let newCover = makeImage(id: 501, mark: .pick, revision: "m-rev-9")
    await transport.setStackRow(
      makeStackRow(
        id: 5, memberCount: 3, hasPick: true, matchedCount: 2, pickedCount: 2,
        anchor: Date(timeIntervalSince1970: 1), representative: newCover),
      forStack: 5)
    await transport.setMarkStateOutcome(
      .success(
        .init(applied: 1, requested: 1, revisions: [.init(imageId: 501, revision: "m-rev-9")])))

    let committed = await store.applyMark(.pick, to: [501])
    #expect(committed)

    let merged = currentStackRow(store, at: 1)
    #expect(merged?.pickedCount == 2)
    #expect(merged?.hasPick == true)
    #expect(merged?.representative.id == 501)
    // The anchor still never moves for a mark — the merge is the five fields, not the row.
    #expect(merged?.anchorTakenAt == Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test("✓N moves the moment the reader marks, before any server row comes back")
  func pickCountMovesOptimistically() async {
    // No `setStackRow` here on purpose: the row re-read FAILS, so anything the badge shows can
    // only be the client's own optimistic arithmetic.
    let (store, transport) = await loadedSceneStore(pickedCount: 1)
    await transport.setStackMemberPage(
      .init(
        items: [
          makeImage(id: 501, revision: "m-rev-1"),
          makeImage(id: 502, mark: .pick, revision: "m-rev-2"),
        ], limit: 100, nextCursor: nil, stackId: 5),
      forStack: 5)
    await store.toggleSceneExpanded(5)
    #expect(currentStackRow(store, at: 1)?.pickedCount == 1)

    await transport.setMarkStateOutcome(
      .success(
        .init(applied: 1, requested: 1, revisions: [.init(imageId: 501, revision: "m-rev-9")])))
    #expect(await store.applyMark(.pick, to: [501]))

    // Positive control: the row re-read really did fail, so no server value could have landed.
    #expect(await transport.callCount(Operations.GetStackApiStacksStackIdGet.id) == 1)
    #expect(currentStackRow(store, at: 1)?.pickedCount == 2)
    #expect(currentStackRow(store, at: 1)?.hasPick == true)

    // Un-picking takes the photograph back out of the count, and a member that was ALREADY
    // picked contributes nothing when picked again.
    await transport.setMarkStateOutcome(
      .success(
        .init(applied: 1, requested: 1, revisions: [.init(imageId: 501, revision: "m-rev-10")])))
    // Spelled out: a bare `.none` in this position reads as `Optional.none` to a human even
    // where the compiler resolves it, and this file is about a tri-state mark.
    #expect(await store.applyMark(MarkStateValue.none, to: [501]))
    #expect(currentStackRow(store, at: 1)?.pickedCount == 1)

    await transport.setMarkStateOutcome(
      .success(
        .init(applied: 1, requested: 1, revisions: [.init(imageId: 502, revision: "m-rev-11")])))
    #expect(await store.applyMark(.pick, to: [502]))  // already a pick
    #expect(currentStackRow(store, at: 1)?.pickedCount == 1)
  }
}

/// The pure halves of both stories, without a store, a view or a network — the same place
/// `SceneRowBuilder`'s other derivations are tested, and for the same reason.
@Suite("Scene band derivations — the band's control anchor and the ✓N arithmetic")
struct SceneBandDerivationTests {

  private func image(_ id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      ext: "raf", filename: "DSCF\(id).raf", folderId: 1, id: id,
      lightroom: .init(sidecarPresent: false), mark: .init(revision: "r0"),
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  @Test("Each open band anchors its control on its FIRST member, and nothing else does")
  func bandLeadsAreTheFirstMemberOfEachOpenBand() {
    let leads = SceneRowBuilder.bandLeadMembers(
      expanded: [5, 7, 9],
      members: [5: [image(501), image(502)], 7: [image(701)], 9: []])

    // 5 and 7 have bands; 9 is open but empty (its card is still on screen and carries its own
    // handle), so it anchors nothing.
    #expect(leads == [501: 5, 701: 7])
    // A member that is not the lead gets no handle — one open scene, one control, however many
    // justified rows its members reflow across.
    #expect(leads[502] == nil)
  }

  @Test("A closed scene anchors nothing even when its members are still cached")
  func aClosedSceneAnchorsNothing() {
    // Closing does not discard the loaded membership (reopening is a display change, not a
    // reason to ask again), so "has members" cannot be the test — being OPEN is.
    let leads = SceneRowBuilder.bandLeadMembers(expanded: [], members: [5: [image(501)]])
    #expect(leads.isEmpty)
    // Positive control: the same membership DOES anchor once the scene is open.
    #expect(SceneRowBuilder.bandLeadMembers(expanded: [5], members: [5: [image(501)]]) == [501: 5])
  }

  @Test("✓N counts only members it holds, only real crossings, and never below zero")
  func pickCountDeltasCountEveryCaseOnce() {
    let members = [5: [image(501), image(502)], 7: [image(701)]]

    // Two members of the same scene becoming picks — one delta of +2, not two rows.
    #expect(
      SceneRowBuilder.pickCountDeltas(
        [
          .init(imageID: 501, wasPicked: false, isPicked: true),
          .init(imageID: 502, wasPicked: false, isPicked: true),
        ], members: members) == [5: 2])

    // A member that was ALREADY a pick contributes nothing; an un-pick takes one back out.
    #expect(
      SceneRowBuilder.pickCountDeltas(
        [
          .init(imageID: 501, wasPicked: true, isPicked: true),
          .init(imageID: 502, wasPicked: true, isPicked: false),
        ], members: members) == [5: -1])

    // A photograph in a scene nobody opened is not in `members`, so its badge is left to the
    // server's own re-read rather than guessed at.
    let unopened = SceneRowBuilder.pickCountDeltas(
      [.init(imageID: 999, wasPicked: false, isPicked: true)], members: members)
    #expect(unopened.isEmpty)

    // Two scenes touched at once are two independent deltas.
    #expect(
      SceneRowBuilder.pickCountDeltas(
        [
          .init(imageID: 501, wasPicked: false, isPicked: true),
          .init(imageID: 701, wasPicked: true, isPicked: false),
        ], members: members) == [5: 1, 7: -1])

    // The clamp: a racing write can only ever leave the badge at zero, never below it.
    #expect(SceneRowBuilder.clampedCount(1, delta: -1) == 0)
    #expect(SceneRowBuilder.clampedCount(0, delta: -3) == 0)
    #expect(SceneRowBuilder.clampedCount(2, delta: 1) == 3)
  }
}

/// What the two new surfaces SAY. Pure, so "the control names what it does and states which way
/// it goes" is a test that reads strings rather than a screenshot somebody has to look at.
@Suite("Scene chrome accessibility — the handle's name and state, the card's own summary")
struct SceneChromeAccessibilityTests {

  @Test("The expand handle names the action and carries the open/closed state")
  func theHandleNamesItsActionAndItsState() {
    #expect(SceneHandleAccessibility.label(isExpanded: false) == "Open scene")
    #expect(SceneHandleAccessibility.label(isExpanded: true) == "Close scene")
    // The state half — SwiftUI has no `aria-expanded`, so it travels as the element's VALUE.
    #expect(SceneHandleAccessibility.value(isExpanded: false) == "Closed")
    #expect(SceneHandleAccessibility.value(isExpanded: true) == "Open")
  }

  @Test("The card announces its size, its state and its pick COUNT — nothing at zero")
  func theCardAnnouncesTheCountNotAFlag() {
    #expect(
      SceneCardAccessibility.label(memberCount: 3, pickedCount: 0, isExpanded: false)
        == "Scene of 3 photos, closed")
    #expect(
      SceneCardAccessibility.label(memberCount: 3, pickedCount: 2, isExpanded: false)
        == "Scene of 3 photos, closed, 2 picked")
    #expect(
      SceneCardAccessibility.label(memberCount: 1, pickedCount: 1, isExpanded: true)
        == "Scene of 1 photo, open, 1 picked")
  }
}
