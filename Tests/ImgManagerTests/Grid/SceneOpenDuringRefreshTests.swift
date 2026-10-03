import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-481: `refreshScenePage` snapshots the open scenes BEFORE it awaits the page and the
/// memberships, and used to assign that snapshot back afterwards — so a scene the reader opened
/// while the refresh was on the wire closed again (the iPad gate's lost first tap on a closed
/// scene handle), and one they closed meanwhile reopened. The reader's own later decision wins.
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

  /// Scene mode on two scenes, 5 (members 1, 2) and 6 (members 3, 4), with scene 6 open.
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
    await store.toggleSceneExpanded(6)
    try #require(store.sceneExpanded == [6])
    try #require(store.sceneMembers[6]?.map { $0.id } == [3, 4])
    return (store, transport)
  }

  @Test("A scene opened while the refresh re-reads the open memberships stays open, with members")
  func anOpenMadeMidRefreshSurvivesIt() async throws {
    let (store, transport) = try await storeWithSceneSixOpen()
    await transport.holdStackMembersRequests(true)
    async let refreshed = store.authoritativeRefresh()
    // The refresh is now on the wire: it re-reads scene 6's membership, held here.
    await transport.waitUntilStackMembersStarted()
    await transport.holdStackMembersRequests(false)
    await store.toggleSceneExpanded(5)
    #expect(store.sceneExpanded == [5, 6])
    #expect(store.sceneMembers[5]?.map { $0.id } == [1, 2])
    await transport.releaseStackMembers()
    #expect(await refreshed)
    // The pre-fix assignment of the snapshot ({6}) closed scene 5 here.
    #expect(store.sceneExpanded == [5, 6])
    #expect(store.sceneMembers[5]?.map { $0.id } == [1, 2])
    #expect(store.sceneMembers[6]?.map { $0.id } == [3, 4])
  }

  @Test("A scene closed while the refresh is on the wire stays closed")
  func aCloseMadeMidRefreshSurvivesIt() async throws {
    let (store, transport) = try await storeWithSceneSixOpen()
    await transport.holdStackMembersRequests(true)
    async let refreshed = store.authoritativeRefresh()
    await transport.waitUntilStackMembersStarted()
    await store.toggleSceneExpanded(6)
    #expect(store.sceneExpanded.isEmpty)
    await transport.holdStackMembersRequests(false)
    await transport.releaseStackMembers()
    #expect(await refreshed)
    // The pre-fix assignment of the snapshot ({6}) reopened scene 6 here.
    #expect(store.sceneExpanded.isEmpty)
  }

  @Test("A scene opened during the refresh that the refreshed page no longer holds is not kept")
  func anOpenOfASceneTheRefreshDroppedIsNotResurrected() async throws {
    let (store, transport) = try await storeWithSceneSixOpen()
    // The refreshed stream no longer contains scene 5 (a filter or a split removed it).
    let six = sceneItem(stackID: 6, representative: makeImage(id: 3))
    await transport.setBrowseStacksPage(.init(items: [six], limit: 100, nextCursor: nil))
    await transport.holdStackMembersRequests(true)
    async let refreshed = store.authoritativeRefresh()
    await transport.waitUntilStackMembersStarted()
    await transport.holdStackMembersRequests(false)
    await store.toggleSceneExpanded(5)
    #expect(store.sceneExpanded == [5, 6])
    await transport.releaseStackMembers()
    #expect(await refreshed)
    // Without the page intersection scene 5 would stay open with no card to sit under.
    #expect(store.sceneExpanded == [6])
    #expect(store.sceneMembers[5] == nil)
  }
}
