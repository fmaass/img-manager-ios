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
      anchorTakenAt: anchor, editedCount: 0, hasPick: hasPick, kind: .stack,
      matchedCount: matchedCount,
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

  // MARK: - WP442 P12: a card PUSHES its scene; the stream never swaps the card out

  @Test("An entered scene's screen is exactly its members; the stream keeps the card")
  func enteredSceneShowsItsMembersAndTheStreamKeepsTheCard() async {
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

    await store.enterScene(5)

    // The claim: the scene screen is N members, zero cards; the stream behind it is unchanged.
    #expect(store.displayRows(for: .stream).map(\.id) == [.image(10), .stack(5)])
    let rows = store.displayRows(for: .scene(5))
    #expect(rows.map(\.id) == [.image(501), .image(502), .image(503)])
    #expect(rows.contains { if case .stack = $0 { return true } else { return false } } == false)
    // No image id twice — the cover used to be drawn as the card AND again as the member it is.
    let ids = rows.compactMap(\.id.imageID)
    #expect(Set(ids).count == ids.count)
    // The served rows are untouched: the scene keeps its place in capture order (the stored
    // anchor) and its cursor.
    #expect(store.sceneRows.count == 2)
    #expect(
      currentStackRow(store, at: 1)?.anchorTakenAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(currentStackRow(store, at: 1)?.representative.id == 900)
    #expect(store.sceneNextCursor == "scene-cursor")
    // Write-safety, both directions: entered members ARE actionable, and the cover never is.
    #expect(store.actionableImages.map(\.id) == [501, 502, 503])
    #expect(store.actionableImages.contains { $0.id == 900 } == false)
  }

  @Test("A scene entered but not yet loaded shows Loading; the stream keeps its card")
  func expandedButUnloadedSceneKeepsItsCard() async {
    let (store, transport) = await loadedSceneStore()
    await transport.holdStackMembersRequests(true)
    await transport.setStackMemberPage(
      .init(items: [makeImage(id: 501)], limit: 100, nextCursor: nil, stackId: 5), forStack: 5)

    let opening = Task { await store.enterScene(5) }
    await transport.waitUntilStackMembersStarted()

    // The entry is committed before the membership settles: the screen says Loading, and the
    // stream behind it still holds the card.
    #expect(store.enteredSceneID == 5)
    #expect(store.sceneScreenState(for: 5) == .loading)
    #expect(store.displayRows(for: .stream).map(\.id) == [.image(10), .stack(5)])
    // Nothing is a write target while it waits: not the card, not the stream behind it.
    #expect(store.actionableImages.isEmpty)

    await transport.releaseStackMembers()
    await opening.value
    await transport.holdStackMembersRequests(false)

    #expect(store.displayRows(for: .scene(5)).map(\.id) == [.image(501)])
    #expect(store.sceneScreenState(for: 5) == .loaded)
  }

  // MARK: - IMGMGR-241: ✓N is a count, and it moves when a member is marked

  @Test("The touched scene's pick count comes back from the server row and merges in place")
  func pickCountMergesFromTheServerRow() async {
    let (store, transport) = await loadedSceneStore(pickedCount: 1)
    await transport.setStackMemberPage(
      .init(
        items: [makeImage(id: 501, revision: "m-rev-1")], limit: 100, nextCursor: nil, stackId: 5),
      forStack: 5)
    await store.enterScene(5)

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
    await store.enterScene(5)
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

  /// IMGMGR-542 (R3-22): the handle opens and closes the scene's peek band; a card tap pushes.
  @Test("The handle names what it does to the peek band, in both states")
  func theHandleNamesItsAction() {
    #expect(SceneHandleAccessibility.label(isOpen: false) == "Show this scene's photos")
    #expect(SceneHandleAccessibility.label(isOpen: true) == "Hide this scene's photos")
  }

  /// WP21 P2 (IMGMGR-339): the pencil states `edited_count`, and states nothing at zero — the
  /// same rule ✓N follows, for the same reason. Pure, so the badge's whole decision is readable
  /// without a render host; `FilterPopoverUITests.testTheSceneCardsPencilCarriesTheEditedCount`
  /// asserts the sentence these functions produce on the real surface.
  @Test("The pencil carries the edited COUNT, and the cluster is silent when nothing was said")
  func thePencilCarriesTheEditedCount() {
    #expect(SceneVerdictBadges.editsText(count: 0) == nil)
    #expect(SceneVerdictBadges.editsText(count: 1) == "1")
    #expect(SceneVerdictBadges.editsText(count: 2) == "2")
    #expect(SceneVerdictBadges.editsText(count: 14) == "14")
    #expect(SceneVerdictBadges.pickText(0) == nil)
    #expect(SceneVerdictBadges.pickText(3) == "3")

    // The capsule follows the digits: drawn when either is said, absent when neither is.
    #expect(SceneVerdictBadges.isSilent(pickedCount: 0, editedCount: 0))
    #expect(!SceneVerdictBadges.isSilent(pickedCount: 0, editedCount: 1))
    #expect(!SceneVerdictBadges.isSilent(pickedCount: 1, editedCount: 0))
    #expect(!SceneVerdictBadges.isSilent(pickedCount: 2, editedCount: 2))
  }

  /// **The sentence and the pencil are ONE value** (diff-gate B2). `SceneCardView` combines its
  /// children into one accessibility element, so the only thing a UI test can read is the card's
  /// LABEL — which is a proof about the badge only if the digit in that label IS the digit the
  /// pencil renders. Asserted structurally here rather than by two matching literals: the clause
  /// must equal `", " + editsText + " edited"` for the very `editsText` the `Label` is built from
  /// (`SceneCardView.swift:172-178`), so an implementation that recomputed the sentence from
  /// `editedCount` independently of the badge fails this test even while both happen to agree.
  @Test("The spoken clause embeds EXACTLY the editsText the pencil renders")
  func theSpokenClauseEmbedsExactlyTheRenderedDigit() {
    for count in [1, 2, 7, 14] {
      guard let rendered = SceneVerdictBadges.editsText(count: count) else {
        Issue.record("editsText(count: \(count)) is nil — the pencil would draw nothing")
        continue
      }
      #expect(SceneVerdictBadges.spokenEditsClause(count: count) == ", \(rendered) edited")
      let spoken = SceneVerdictBadges.spokenLabel(
        memberCount: 9, pickedCount: 1, editedCount: count)
      #expect(spoken.hasSuffix(", \(rendered) edited"))
      // ...and the base sentence is untouched in front of it.
      #expect(
        spoken
          == SceneCardAccessibility.label(memberCount: 9, pickedCount: 1)
          + SceneVerdictBadges.spokenEditsClause(count: count))
    }
    // Nothing rendered, nothing said — the two agree at zero as well as above it.
    #expect(SceneVerdictBadges.editsText(count: 0) == nil)
    #expect(SceneVerdictBadges.spokenEditsClause(count: 0) == "")
  }

  /// The card's spoken sentence gains the edited clause and keeps everything it already said —
  /// this is the surface a UI test can read, because `SceneCardView` combines its children into
  /// ONE accessibility element and the badge identifiers are merged away with them.
  @Test("The card's sentence adds the edited clause without disturbing the shipped half")
  func theCardsSentenceCarriesTheEditedClause() {
    #expect(
      SceneVerdictBadges.spokenLabel(
        memberCount: 5, pickedCount: 2, editedCount: 2)
        == "Scene of 5 photos, 2 picked, 2 edited")
    #expect(
      SceneVerdictBadges.spokenLabel(
        memberCount: 5, pickedCount: 0, editedCount: 3)
        == "Scene of 5 photos, 3 edited")
    // Nothing at zero: the sentence is exactly what the shipped function returns.
    #expect(
      SceneVerdictBadges.spokenLabel(
        memberCount: 3, pickedCount: 2, editedCount: 0)
        == SceneCardAccessibility.label(memberCount: 3, pickedCount: 2))
    #expect(
      SceneVerdictBadges.spokenLabel(
        memberCount: 1, pickedCount: 0, editedCount: 0)
        == "Scene of 1 photo")
  }

  @Test("The card announces its size and its pick COUNT — nothing at zero")
  func theCardAnnouncesTheCountNotAFlag() {
    #expect(
      SceneCardAccessibility.label(memberCount: 3, pickedCount: 0)
        == "Scene of 3 photos")
    #expect(
      SceneCardAccessibility.label(memberCount: 3, pickedCount: 2)
        == "Scene of 3 photos, 2 picked")
    #expect(
      SceneCardAccessibility.label(memberCount: 1, pickedCount: 1)
        == "Scene of 1 photo, 1 picked")
  }
}
