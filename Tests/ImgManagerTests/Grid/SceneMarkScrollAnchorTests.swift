import CoreGraphics
import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-473: marking a member of an OPEN scene must leave the grid where it was.
///
/// One mark rebuilds the scene state twice — the optimistic half (`sceneMembers` and the ✓N count
/// on `sceneRows`, before the network await) and the post-commit half (`refreshScenesFor` merges
/// the server's re-read row, representative included). The scroll position is a PHOTOGRAPH that
/// `GridScrollAnchor` re-resolves to a row on every body pass, so the question is whether either
/// rebuild can move the rendered rows under it: a row that changed its id, or a row whose cells
/// changed size, is exactly a jump.
///
/// The fixture is built to make a jump possible if the band ever depended on the card: the
/// members have mixed aspect ratios, and the re-read re-elects the cover to a member whose ratio
/// (0.5) differs from the old cover's (1.0). An open band that still drew its card, or packed by
/// the card's representative, would repack here and fail the equality below.
@MainActor
@Suite("Scene mark — the open band's rows do not move under the scroll anchor (IMGMGR-473)")
struct SceneMarkScrollAnchorTests {

  private func makeImage(
    id: Int, aspect: Double = 1.0, mark: Components.Schemas.MarkView.StatePayload = .none,
    revision: String = "r0"
  ) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: aspect, capturedAt: nil, ext: "raf", filename: "DSCF\(id).raf", folderId: 1,
      hasEdit: false, id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(revision: revision, state: mark, tags: []), missing: false,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func stackRow(
    pickedCount: Int, representative: Components.Schemas.ImageSummary
  ) -> Components.Schemas.StackBrowseStackRow {
    Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: Date(timeIntervalSince1970: 1_700_000_000), editedCount: 0,
      hasPick: pickedCount > 0, kind: .stack, matchedCount: 12, memberCount: 12,
      pickedCount: pickedCount, representative: representative, stackId: 5)
  }

  /// Twelve members, ratios cycling 1.5 / 0.66 / 1.0 so the justified rows are uneven.
  private func members() -> [Components.Schemas.ImageSummary] {
    let ratios = [1.5, 0.66, 1.0]
    return (0..<12).map { makeImage(id: 501 + $0, aspect: ratios[$0 % 3], revision: "m\($0)") }
  }

  /// The same packing `GridView.renderRows` runs, at a fixed pane — the rows the anchor
  /// resolves against. A phone-width pane (300 pt, ~2.4 tiles per row): at 600 pt the fifteen
  /// tiles packed into only three rows (gate on ea18cf7), too few to anchor inside the band.
  private func rendered(_ store: GridStore) -> [GridRenderRow] {
    GridSectionLayout.renderRows(
      rows: store.displayRows(for: store.activeScope),
      groupBy: store.activeGrouping.groupByKey,
      headers: store.groupHeaders, timezone: store.groupTimezone,
      paneWidth: 300, targetRowHeight: 120, displayScale: 2,
      availability: { _, _ in .ok(width: 4000, height: 4000) })
  }

  private func pickedCount(of store: GridStore) -> Int? {
    for row in store.sceneRows {
      if case .stack(let stack) = row, stack.stackId == 5 { return stack.pickedCount }
    }
    return nil
  }

  private func representativeID(of store: GridStore) -> Int? {
    for row in store.sceneRows {
      if case .stack(let stack) = row, stack.stackId == 5 { return stack.representative.id }
    }
    return nil
  }

  @Test(
    "A pick inside an open scene leaves every rendered row and the anchor's row identical, optimistic and re-read"
  )
  func aMarkInsideAnOpenSceneMovesNoRow() async {
    let transport = GridStubTransport()
    let store = GridStore(
      service: GridService(client: ImgManagerAPIClient.make(transport: transport)))
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)

    let oldCover = makeImage(id: 900, aspect: 1.0, mark: .pick)
    await transport.setBrowseStacksPage(
      .init(
        items: [
          .init(value1: .init(image: makeImage(id: 10, aspect: 1.5), kind: .image), value2: nil),
          .init(value1: .init(image: makeImage(id: 11, aspect: 0.66), kind: .image), value2: nil),
          .init(value1: nil, value2: stackRow(pickedCount: 1, representative: oldCover)),
          .init(value1: .init(image: makeImage(id: 12, aspect: 1.0), kind: .image), value2: nil),
        ], limit: 100, nextCursor: nil))
    await store.setDisplayMode(.scene)
    await transport.setStackMemberPage(
      .init(items: members(), limit: 100, nextCursor: nil, stackId: 5), forStack: 5)
    await store.enterScene(5)

    let before = rendered(store)
    let keyBefore = GridPackingKey(store: store, paneWidth: 300, displayScale: 2)
    // The reader is scrolled INTO the band: the anchor is the leading photograph of a row made
    // only of members, two rows down.
    #expect(before.count >= 4, "the fixture must pack into enough rows to anchor inside the band")
    guard before.count >= 4 else { return }
    let anchoredRowID = before[2].id
    let anchor = GridScrollAnchor.displayID(of: anchoredRowID)
    #expect(anchor?.imageID.map { (501...512).contains($0) } == true, "anchor is not a member")

    // The server's re-read after the pick: the cover moves to the picked member (ratio 0.5,
    // unlike the old cover's 1.0) and the count moves — every field `refreshScenesFor` merges.
    let newCover = makeImage(id: 507, aspect: 0.5, mark: .pick, revision: "m6-after")
    await transport.setStackRow(stackRow(pickedCount: 2, representative: newCover), forStack: 5)
    await transport.setMarkStateOutcome(
      .success(
        .init(applied: 1, requested: 1, revisions: [.init(imageId: 507, revision: "m6-after")])))
    await transport.holdMarkStateRequests(true)

    async let marked: Bool = store.applyMark(.pick, to: [507])
    await transport.waitUntilMarkStateStarted()

    // OPTIMISTIC half: the state and the ✓N count really moved (so this is not a vacuous
    // comparison of two identical stores)...
    #expect(store.actionableImages.first { $0.id == 507 }?.mark.state == .pick)
    #expect(pickedCount(of: store) == 2)
    let optimistic = rendered(store)
    let keyOptimistic = GridPackingKey(store: store, paneWidth: 300, displayScale: 2)

    await transport.releaseMarkState()
    let committed = await marked
    #expect(committed)

    // RE-READ half: the cover really was re-elected...
    #expect(representativeID(of: store) == 507)
    let after = rendered(store)
    let keyAfter = GridPackingKey(store: store, paneWidth: 300, displayScale: 2)

    // ...and neither rebuild moved a single rendered row: same ids, same cells, same sizes.
    #expect(optimistic == before, "the optimistic rebuild repacked the open band")
    #expect(after == before, "the post-commit re-read (cover re-election) repacked the open band")
    #expect(GridScrollAnchor.row(containing: anchor, in: optimistic) == anchoredRowID)
    #expect(GridScrollAnchor.row(containing: anchor, in: after) == anchoredRowID)
    // Round 3: the repack restore is keyed on `GridPackingKey`, so a mark must not move it —
    // a moved key is exactly the scroll-to-top snap this ticket removed.
    #expect(keyOptimistic == keyBefore, "the optimistic half changed the packing key")
    #expect(keyAfter == keyBefore, "the post-commit re-read changed the packing key")
  }
}
