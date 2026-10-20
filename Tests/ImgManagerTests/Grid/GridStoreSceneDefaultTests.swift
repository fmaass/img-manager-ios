import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-557: a folder opens in Scene when its first `GET /api/browse/stacks` page holds at least
/// one scene, and Flat otherwise — including when that probe cannot be answered. One case per
/// input category: scenes only, no scenes, mixed, empty, probe failing; plus the owner's ruling
/// on open decision 1 (a manual switch lasts for that folder visit only) and the restore that
/// leaving the default Scene must keep.
///
/// "Group shows Scene/None" is read through `ArrangeModel`, the model the Arrange popover renders
/// its checkmarks from, so the assertion is about the control the reader sees.
@MainActor
@Suite("GridStore — folders open in Scene when they have scenes (IMGMGR-557)")
struct GridStoreSceneDefaultTests {

  // MARK: - Fixtures

  private func makeImage(id: Int, folderID: Int = 1) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "raf", filename: "DSCF\(id).raf", folderId: folderID,
      hasEdit: false, id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []), missing: false,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func stackItem(id: Int, cover: Int)
    -> Components.Schemas.StackBrowsePage.ItemsPayloadPayload
  {
    .init(
      value1: nil,
      value2: Components.Schemas.StackBrowseStackRow(
        anchorTakenAt: Date(timeIntervalSince1970: 1_700_000_000), editedCount: 0,
        hasPick: false, kind: .stack, matchedCount: 3, memberCount: 3, pickedCount: 0,
        representative: makeImage(id: cover), stackId: id))
  }

  private func imageItem(_ id: Int) -> Components.Schemas.StackBrowsePage.ItemsPayloadPayload {
    .init(value1: .init(image: makeImage(id: id), kind: .image), value2: nil)
  }

  private func stacksPage(_ items: [Components.Schemas.StackBrowsePage.ItemsPayloadPayload])
    -> Components.Schemas.StackBrowsePage
  {
    Components.Schemas.StackBrowsePage(items: items, limit: 100, nextCursor: nil)
  }

  private func makeStore() -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    return (GridStore(service: GridService(client: client)), transport)
  }

  private let stacksOp = Operations.BrowseStacksApiBrowseStacksGet.id
  private let imagesOp = Operations.ListImagesApiImagesGet.id

  private func groupRow(_ id: String) throws -> ArrangeRow {
    try #require(ArrangeModel.rows.first { $0.id == id })
  }

  /// Group's two rows this feature decides between, as the Arrange popover reads them.
  private func groupChecks(_ store: GridStore) throws -> (scene: Bool, none: Bool) {
    let model = ArrangeModel(store: store)
    let scene = try groupRow("arrange.group.scene")
    let none = try groupRow("arrange.group.none")
    return (model.isChecked(scene), model.isChecked(none))
  }

  // MARK: - One case per input category

  @Test("A folder whose first page holds only scenes opens in Scene, Group showing Scene")
  func scenesOnlyOpensInScene() async throws {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await transport.setBrowseStacksPage(stacksPage([stackItem(id: 5, cover: 900)]))

    await store.selectShoot(folderID: 1)

    #expect(store.displayMode == .scene)
    #expect(store.activeGrouping == .scene)
    let checks = try groupChecks(store)
    #expect(checks.scene && !checks.none, "Arrange › Group does not show Scene as current")
    #expect(store.sceneRows.map(\.displayID) == [.stack(5)])
    #expect(store.images.isEmpty, "Scene mode's flat pool must stay empty")
    // The probe IS Scene's first page: one stacks request, and the flat endpoint is never asked.
    #expect(await transport.callCount(stacksOp) == 1)
    #expect(await transport.callCount(imagesOp) == 0)
  }

  @Test("A folder of loose photographs only opens Flat, Group showing None")
  func noScenesOpensFlat() async throws {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 10), makeImage(id: 11)], limit: 100, nextCursor: nil))
    await transport.setBrowseStacksPage(stacksPage([imageItem(10), imageItem(11)]))

    await store.selectShoot(folderID: 1)

    #expect(store.displayMode == .flat)
    #expect(store.activeGrouping == .none)
    let checks = try groupChecks(store)
    #expect(checks.none && !checks.scene, "Arrange › Group does not show None as current")
    // No Scene-mode singleton stream: the flat page is what is shown.
    #expect(store.images.map(\.id) == [10, 11])
    #expect(store.sceneRows.isEmpty)
    // Positive control: the probe really ran, so Flat is its answer and not a skipped question.
    #expect(await transport.callCount(stacksOp) == 1)
    #expect(await transport.callCount(imagesOp) == 1)
  }

  @Test("A folder mixing scenes and loose photographs opens in Scene")
  func mixedOpensInScene() async throws {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 10)], limit: 100, nextCursor: nil))
    await transport.setBrowseStacksPage(
      stacksPage([imageItem(10), stackItem(id: 5, cover: 900), imageItem(11)]))

    await store.selectShoot(folderID: 1)

    #expect(store.displayMode == .scene)
    let checks = try groupChecks(store)
    #expect(checks.scene && !checks.none)
    #expect(store.sceneRows.map(\.displayID) == [.image(10), .stack(5), .image(11)])
  }

  @Test("An empty folder opens Flat")
  func emptyFolderOpensFlat() async throws {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [], limit: 100, nextCursor: nil))
    await transport.setBrowseStacksPage(stacksPage([]))

    await store.selectShoot(folderID: 1)

    #expect(store.displayMode == .flat)
    let checks = try groupChecks(store)
    #expect(checks.none && !checks.scene)
    #expect(await transport.callCount(stacksOp) == 1)
    #expect(await transport.callCount(imagesOp) == 1)
  }

  @Test("A failing scene probe opens Flat with no error of its own")
  func failingProbeOpensFlatWithoutABanner() async throws {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await transport.setBrowseStacksPage(stacksPage([stackItem(id: 5, cover: 900)]))
    await transport.setBrowseStacksShouldFail(true)

    await store.selectShoot(folderID: 1)

    #expect(store.displayMode == .flat)
    let checks = try groupChecks(store)
    #expect(checks.none && !checks.scene)
    #expect(store.images.map(\.id) == [1])
    #expect(store.lastPageLoadError == nil, "the probe's failure surfaced as a load error")
    // Positive control: the probe was asked and failed, it was not skipped.
    #expect(await transport.callCount(stacksOp) == 1)
  }

  @Test("A failing probe AND a failing flat page show today's load error, in Flat")
  func failingProbeAndFlatPageShowTodaysError() async {
    let (store, transport) = makeStore()
    await transport.setBrowseStacksShouldFail(true)
    await transport.setListImagesShouldFail(true)

    await store.selectShoot(folderID: 1)

    #expect(store.displayMode == .flat)
    #expect(store.lastPageLoadError != nil)
  }

  // MARK: - Open decision 1: default only, nothing remembered

  @Test("A switch to Flat lasts for that folder visit only")
  func aManualFlatLastsForThatVisitOnly() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await transport.setBrowseStacksPage(stacksPage([stackItem(id: 5, cover: 900)]))
    await store.selectShoot(folderID: 1)
    #expect(store.displayMode == .scene, "precondition: the folder opened in Scene")

    await store.selectGrouping(.none)
    #expect(store.displayMode == .flat)
    // Re-selecting the SAME folder is a refresh within the visit, not a new open.
    await store.selectShoot(folderID: 1)
    #expect(store.displayMode == .flat, "a refresh of the open folder re-applied the default")

    await store.selectShoot(folderID: 2)
    #expect(store.displayMode == .scene, "the next folder did not open on its own default")
  }

  @Test("Leaving Scene for a folder without scenes opens it Flat")
  func sceneThenAFolderWithoutScenesOpensFlat() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await transport.setBrowseStacksPage(stacksPage([stackItem(id: 5, cover: 900)]))
    await store.selectShoot(folderID: 1)
    #expect(store.displayMode == .scene, "precondition: the folder opened in Scene")

    await transport.setBrowseStacksPage(stacksPage([imageItem(20)]))
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 20, folderID: 2)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)

    #expect(store.displayMode == .flat)
    #expect(store.images.map(\.id) == [20])
    #expect(store.sceneRows.isEmpty)
  }

  /// Scope: only a folder OPEN chooses the default. A filter change inside the visit reloads the
  /// same folder and must keep the mode the reader switched to.
  @Test("A filter change within the visit keeps a manual Flat")
  func aFilterChangeKeepsTheVisitsMode() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await transport.setBrowseStacksPage(stacksPage([stackItem(id: 5, cover: 900)]))
    await store.selectShoot(folderID: 1)
    #expect(store.displayMode == .scene, "precondition: the folder opened in Scene")
    await store.setDisplayMode(.flat)
    let stacksAsked = await transport.callCount(stacksOp)

    await store.applyFilterChange { $0.ratingMin = 3 }

    #expect(store.currentQuery.ratingMin == 3, "positive control: the filter change landed")
    #expect(store.displayMode == .flat, "a filter change re-applied the folder default")
    #expect(await transport.callCount(stacksOp) == stacksAsked)
  }

  // MARK: - The restore leaving the default Scene keeps

  @Test("Leaving the default Scene restores the sort and grouping the reader had")
  func leavingTheDefaultSceneRestoresThePresentation() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    #expect(store.displayMode == .flat, "precondition: a folder without scenes opened Flat")
    await store.setSortKey(.rating)
    await store.selectGrouping(.key(.camera))
    let before = SortGroupPresentation(of: store.currentQuery)

    await transport.setBrowseStacksPage(stacksPage([stackItem(id: 5, cover: 900)]))
    await store.selectShoot(folderID: 2)
    #expect(store.displayMode == .scene)
    // Suspended exactly as `setDisplayMode(.scene)` suspends it: off the query while Scene is on.
    #expect(store.currentQuery.sort == nil)
    #expect(store.currentQuery.groupBy == nil)
    #expect(store.activeSortKey == .rating, "the Sort control lost the suspended key")

    await store.setDisplayMode(.flat)
    #expect(SortGroupPresentation(of: store.currentQuery) == before)
    #expect(store.activeGrouping == .key(.camera))
  }

  // MARK: - Concurrency

  /// Time-limited: against a store that never probes, `waitUntilBrowseStacksStarted` would wait
  /// forever, and a hung suite reads as nothing at all.
  @Test("A probe answered after a newer folder open is discarded", .timeLimit(.minutes(1)))
  func aStaleProbeIsDiscarded() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await transport.setBrowseStacksPage(stacksPage([stackItem(id: 5, cover: 900)]))
    await transport.holdNextBrowseStacksRequest()

    let first = Task { await store.selectShoot(folderID: 1) }
    await transport.waitUntilBrowseStacksStarted()

    // The newer open lands while folder 1's probe (which would answer "has scenes") is held.
    await transport.setBrowseStacksPage(stacksPage([imageItem(20)]))
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 20, folderID: 2)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 2)
    #expect(store.displayMode == .flat, "precondition: folder 2 has no scenes")

    await transport.releaseBrowseStacks()
    await first.value

    #expect(store.currentQuery.folderID == 2)
    #expect(store.displayMode == .flat, "folder 1's stale probe switched folder 2 into Scene")
    #expect(store.images.map(\.id) == [20])
    #expect(store.sceneRows.isEmpty)
  }
}
