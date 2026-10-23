import Foundation
import ImgManagerAPI
import SwiftUI
import Testing

@testable import ImgManager

/// IMGMGR-542 (R3-22): the peek band — a scene's members under its card's row, opened by the
/// chevron, closed by the chevron, Esc or Collapse all, never a route.
@MainActor
@Suite("IMGMGR-542 — peek bands open scene members in place")
struct PeekBandTests {
  private typealias MarkPayload = Components.Schemas.MarkView.StatePayload
  private typealias Item = Components.Schemas.StackBrowsePage.ItemsPayloadPayload

  private let t0: TimeInterval = 1_700_000_000
  private let t1: TimeInterval = 1_700_003_600

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

  private var streamItems: [Item] {
    [
      loose(10), scene(5, count: 3, anchor: t0, cover: 900),
      scene(6, count: 2, anchor: t1, cover: 901), loose(11),
    ]
  }

  private func sceneStore() async -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let store = GridStore(service: GridService(client: client))
    await transport.setBrowseStacksPage(page(streamItems))
    await transport.setStackMemberPage(members([1, 2, 3], of: 5), forStack: 5)
    await transport.setStackMemberPage(members([7, 8], of: 6), forStack: 6)
    await store.selectShoot(folderID: 1)
    await store.setDisplayMode(.scene)
    return (store, transport)
  }

  private func shown(_ store: GridStore) -> [GridDisplayID] {
    store.displayRows(for: .stream).map(\.id)
  }

  @Test("U1: the chevron puts every member after its card, and only its members")
  func bandRowsFollowTheCardRowAndHoldOnlyItsMembers() async {
    let (store, _) = await sceneStore()
    await store.togglePeekBand(5)
    #expect(
      shown(store) == [
        .image(10), .stack(5), .image(1), .image(2), .image(3), .stack(6), .image(11),
      ])
    #expect(store.peekBandRows.map(\.stackID) == [5])
  }

  @Test("U6: Esc closes the most recently opened band; with none open it does nothing")
  func escClosesTheMostRecentlyOpenedBand() async {
    let (store, _) = await sceneStore()
    store.closeMostRecentBand()
    #expect(store.openBandIDs.isEmpty)
    await store.togglePeekBand(6)
    await store.togglePeekBand(5)
    #expect(store.canCloseBand)
    store.closeMostRecentBand()
    #expect(store.openBandIDs == [6])
    #expect(shown(store) == [.image(10), .stack(5), .stack(6), .image(7), .image(8), .image(11)])
  }

  @Test("U7: Collapse all closes every band and is enabled only with one open")
  func collapseAllClosesEveryBand() async {
    let (store, _) = await sceneStore()
    #expect(GridMoreMenu.collapseAllBands.isEnabled(store) == false)
    await store.togglePeekBand(5)
    await store.togglePeekBand(6)
    #expect(GridMoreMenu.collapseAllBands.isEnabled(store))
    store.collapseAllBands()
    #expect(store.openBandIDs.isEmpty)
    #expect(shown(store) == [.image(10), .stack(5), .stack(6), .image(11)])
  }

  @Test("U10: band members are actionable; the card never is")
  func bandMembersAreActionableAndTheCardIsNot() async {
    let (store, _) = await sceneStore()
    await store.togglePeekBand(5)
    #expect(store.actionableImages.map(\.id) == [10, 1, 2, 3, 11])
    #expect(!store.actionableImages.contains { $0.id == 900 })
  }

  @Test("U12: the filmstrip of a band member is the band; a closed band's cache is no strip")
  func theFilmstripOfABandMemberIsTheBand() async {
    let (store, _) = await sceneStore()
    await store.togglePeekBand(5)
    #expect(store.openSceneMembers(containing: 2)?.map(\.id) == [1, 2, 3])
    await store.togglePeekBand(5)
    #expect(store.sceneMembers[5] != nil)
    #expect(store.openSceneMembers(containing: 2) == nil)
  }

  @Test("U16: the chevron never enters the scene")
  func theChevronNeverEntersTheScene() async {
    let (store, _) = await sceneStore()
    await store.togglePeekBand(5)
    #expect(store.activeScope == .stream)
    #expect(store.enteredSceneID == nil)
  }

  @Test("Esc is dead in Flat, inside a scene, with the loupe open and under a sheet")
  func escIsDeadOutsideTheBareSceneStream() async {
    let (store, _) = await sceneStore()
    await store.togglePeekBand(5)
    #expect(store.canCloseBand)
    store.isStatusPresented = true
    #expect(!store.canCloseBand)
    store.isStatusPresented = false
    store.notePopover("gridFilterControl", isPresented: true)
    #expect(!store.canCloseBand)
    store.notePopover("gridFilterControl", isPresented: false)
    await store.enterScene(6)
    #expect(!store.canCloseBand)
    store.leaveScene()
    #expect(store.canCloseBand)
    #expect(store.openBandIDs == [5])
  }

  @Test("U18: a failed membership read offers retry instead of an empty band")
  func aFailedMembershipOffersRetry() async {
    let (store, transport) = await sceneStore()
    await transport.failStackMembers(5)
    await store.togglePeekBand(5)
    #expect(store.bandLoadFailed.contains(5))
    #expect(store.peekBandRows.isEmpty)
    await transport.failStackMembers(5, false)
    await store.togglePeekBand(5)
    await store.togglePeekBand(5)
    #expect(!store.bandLoadFailed.contains(5))
    #expect(store.peekBandRows.map(\.stackID) == [5])
  }

  @Test("U15: a membership page landing after the band closed opens nothing")
  func aMembershipPageLandingAfterTheBandClosedOpensNothing() async {
    let (store, transport) = await sceneStore()
    await transport.holdStackMembersRequests(true)
    let opening = Task { await store.togglePeekBand(5) }
    await transport.waitUntilStackMembersStarted()
    store.closeMostRecentBand()
    await transport.releaseStackMembers()
    await opening.value
    #expect(store.openBandIDs.isEmpty)
    #expect(store.sceneMembers[5] == nil)
    #expect(shown(store) == [.image(10), .stack(5), .stack(6), .image(11)])
  }
}
