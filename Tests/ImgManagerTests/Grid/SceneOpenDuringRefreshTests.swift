import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-481: `refreshScenePage` reads the entered scene BEFORE it awaits the page and the
/// membership, and must not assign that snapshot back afterwards — an enter or a Back the reader
/// made while the refresh was on the wire wins. WP442 P12: one entered scene; the old "absent
/// from page one ⇒ dropped" rule is retired (B5) — `ScenePushTests` U14/U15 own its replacement
/// (a stack-row 200 keeps the scene, a 404 leaves it).
@MainActor
@Suite("GridStore — scene opens and closes made during a refresh survive it (IMGMGR-481)")
struct SceneOpenDuringRefreshTests {
  private typealias MarkPayload = Components.Schemas.MarkView.StatePayload

  private func makeImage(id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: MarkPayload.none, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func sceneItem(stackID: Int, representative: Components.Schemas.ImageSummary)
    -> Components.Schemas.StackBrowsePage.ItemsPayloadPayload
  {
    let row = Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: nil, editedCount: 0, hasPick: false, kind: .stack, matchedCount: 2,
      memberCount: 2, pickedCount: 0, representative: representative, stackId: stackID)
    return .init(value1: nil, value2: row)
  }

  /// Scene mode on two scenes, 5 (members 1, 2) and 6 (members 3, 4), with scene 6 entered.
  private func storeWithSceneSixOpen() async throws -> (GridStore, GridStubTransport) {
    let (store, transport) = makeCompareTestStore()
    var items: [Components.Schemas.StackBrowsePage.ItemsPayloadPayload] = []
    for (stackID, ids) in [(5, [1, 2]), (6, [3, 4])] {
      let members = ids.map { makeImage(id: $0) }
      items.append(sceneItem(stackID: stackID, representative: members[0]))
      let page = Components.Schemas.StackMemberPage(
        items: members, limit: 100, nextCursor: nil, stackId: stackID)
      await transport.setStackMemberPage(page, forStack: stackID)
    }
    await transport.setBrowseStacksPage(.init(items: items, limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    await store.setDisplayMode(.scene)
    await store.enterScene(6)
    try #require(store.enteredSceneID == 6)
    try #require(store.sceneMembers[6]?.map { $0.id } == [3, 4])
    return (store, transport)
  }

  @Test("A scene entered while the refresh re-reads its membership stays entered, with members")
  func anEnterMadeMidRefreshSurvivesIt() async throws {
    let (store, transport) = try await storeWithSceneSixOpen()
    await transport.holdStackMembersRequests(true)
    async let refreshed = store.authoritativeRefresh()
    // The refresh is now on the wire: it re-reads scene 6's membership, held here.
    await transport.waitUntilStackMembersStarted()
    await transport.holdStackMembersRequests(false)
    store.leaveScene()
    await store.enterScene(5)
    #expect(store.enteredSceneID == 5)
    #expect(store.sceneMembers[5]?.map { $0.id } == [1, 2])
    await transport.releaseStackMembers()
    #expect(await refreshed)
    // Assigning the snapshot back (6) would have undone the reader's enter here.
    #expect(store.enteredSceneID == 5)
    #expect(store.sceneMembers[5]?.map { $0.id } == [1, 2])
    #expect(store.displayRows(for: .scene(5)).map(\.id) == [.image(1), .image(2)])
  }

  @Test("A Back made while the refresh is on the wire stays Back")
  func aBackMadeMidRefreshSurvivesIt() async throws {
    let (store, transport) = try await storeWithSceneSixOpen()
    await transport.holdStackMembersRequests(true)
    async let refreshed = store.authoritativeRefresh()
    await transport.waitUntilStackMembersStarted()
    store.leaveScene()
    #expect(store.enteredSceneID == nil)
    await transport.holdStackMembersRequests(false)
    await transport.releaseStackMembers()
    #expect(await refreshed)
    // Assigning the snapshot back (6) would have re-entered scene 6 here.
    #expect(store.enteredSceneID == nil)
  }
}
