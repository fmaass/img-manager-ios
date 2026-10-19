import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// R3-18 (IMGMGR-550), plan Decision 7: the Filter popover's Keyword row — the server's own
/// `ImageFacets.keyword` values in count order, at most thirty, no "More…", and only ever read
/// from a folder-scoped `/api/facets` (a bare one cancels at 30 s in production, IMGMGR-384).
@MainActor
@Suite("Filter Keyword row (R3-18: count order, thirty at most, always folder-scoped)")
struct FilterKeywordRowTests {

  private func facetCounts(_ pairs: [(String, Int)]) -> [Components.Schemas.FacetCount] {
    pairs.map { .init(count: $0.1, value: $0.0) }
  }

  private func section(
    _ field: InspectorFacetField, _ facets: Components.Schemas.ImageFacets?,
    _ query: GridImagesQuery = GridImagesQuery()
  ) -> FilterPopoverSection? {
    FilterPopoverModel.rows(facets, query).first(where: { $0.field == field })
  }

  /// `k01` … `k<n>`, counts `n` … 1 — already in the server's order.
  private func ranked(_ n: Int) -> [(String, Int)] {
    (1...n).map { ("k\(String(format: "%02d", $0))", n + 1 - $0) }
  }

  // MARK: - The model

  @Test("The Keyword row lists the facet's values in count order; a tie keeps the server's order")
  func keywordRowListsTheFacetValuesInCountOrder() {
    let pairs = [("c", 2), ("a", 9), ("d", 5), ("b", 5)]
    let facets = Components.Schemas.ImageFacets(keyword: facetCounts(pairs), total: 21)
    let keyword = section(.keyword, facets)
    #expect(keyword?.title == "Keyword")
    #expect(keyword?.rows.map(\.value) == ["a", "d", "b", "c"])
    #expect(keyword?.rows.map(\.title) == ["a", "d", "b", "c"])
    #expect(keyword?.rows.map(\.count) == [9, 5, 5, 2])
    #expect(keyword?.rows.allSatisfy { $0.isEnabled } == true)
    #expect(keyword?.rows.first?.accessibilityIdentifier == "filterPopoverRow-keyword-a")
  }

  @Test("Keyword is the last declared section, after Camera")
  func keywordIsTheLastSection() {
    #expect(FilterPopoverModel.sections.last?.field == .keyword)
    #expect(FilterPopoverModel.sections.last?.title == "Keyword")
    #expect(FilterPopoverModel.keywordValueLimit == 30)
  }

  @Test("Never more than thirty rows; an absent active keyword takes the last of the thirty")
  func keywordRowNeverExceedsThirtyAndReservesTheActiveSlot() {
    let limit = FilterPopoverModel.keywordValueLimit
    let facets = Components.Schemas.ImageFacets(keyword: facetCounts(ranked(limit)), total: 900)
    let expected = ranked(limit).map(\.0)

    // (i) Thirty values, nothing active: all thirty, and no synthetic overflow notice.
    let plain = section(.keyword, facets)?.rows ?? []
    #expect(plain.map(\.value) == expected)
    #expect(!plain.contains(where: { !$0.isEnabled }))

    // (ii) The active keyword is not in the thirty: 29 highest + the active one, still thirty.
    var absent = GridImagesQuery(folderID: 7)
    absent.keyword = "zz"
    let reserved = section(.keyword, facets, absent)?.rows ?? []
    #expect(reserved.count == limit)
    #expect(reserved.map(\.value) == Array(expected.prefix(limit - 1)) + ["zz"])
    #expect(reserved.last?.isActive == true)
    #expect(reserved.last?.isEnabled == true)
    #expect(reserved.last?.count == 0)
    #expect(!reserved.contains(where: { !$0.isEnabled }))

    // (iii) The active keyword ranks thirtieth: the thirty are unchanged.
    var last = GridImagesQuery(folderID: 7)
    last.keyword = expected[limit - 1]
    let kept = section(.keyword, facets, last)?.rows ?? []
    #expect(kept.map(\.value) == expected)
    #expect(kept.last?.isActive == true)
  }

  @Test("A response wider than the server cap is cut to thirty, with no notice")
  func aWiderResponseIsCutToThirty() {
    let limit = FilterPopoverModel.keywordValueLimit
    let facets = Components.Schemas.ImageFacets(
      keyword: facetCounts(ranked(limit + 1)), total: 900)
    let rows = section(.keyword, facets)?.rows ?? []
    #expect(rows.map(\.value) == ranked(limit).map(\.0))
    #expect(!rows.contains(where: { !$0.isEnabled }))
  }

  @Test("No keywords at all: one named placeholder row at 0, disabled")
  func keywordEmptyDimensionIsOnePlaceholder() {
    let rows = section(.keyword, Components.Schemas.ImageFacets(keyword: [], total: 3))?.rows
    #expect(rows?.count == 1)
    #expect(rows?.first?.title == "Keyword")
    #expect(rows?.first?.count == 0)
    #expect(rows?.first?.isEnabled == false)
  }

  /// A keyword spelled like the Camera overflow value or the NULL bucket is an ordinary keyword:
  /// it gets the identifier its value spells, enabled, with its count.
  @Test("Keywords literally named `more` or `unset` are ordinary, enabled rows")
  func keywordNamedMoreOrUnsetIsAnOrdinaryRow() {
    let pairs = [("more", 4), ("unset", 3)]
    let facets = Components.Schemas.ImageFacets(keyword: facetCounts(pairs), total: 7)
    let rows = section(.keyword, facets)?.rows ?? []
    #expect(rows.map(\.value) == ["more", "unset"])
    #expect(rows.allSatisfy { $0.isEnabled })
    #expect(rows.first?.accessibilityIdentifier == "filterPopoverRow-keyword-more")
    #expect(rows.first?.count == 4)
  }

  /// Camera keeps its shipped rule beside Keyword's: fourteen bodies and an active one that is
  /// NOT among them yields the head, the active body appended, and the stated notice.
  @Test("Camera's cap is unchanged: head, active appended, and the `+N more cameras` notice")
  func cameraKeepsItsAnnouncedCap() {
    let limit = FilterPopoverModel.cameraValueLimit
    let bodies = (0..<(limit + 2)).map { ("BODY-\(String(format: "%02d", $0))", 100 - $0) }
    var query = GridImagesQuery(folderID: 7)
    query.camera = "ABSENT-BODY"
    let facets = Components.Schemas.ImageFacets(camera: facetCounts(bodies), total: 500)
    let rows = section(.camera, facets, query)?.rows ?? []
    guard rows.count == limit + 2 else {
      Issue.record("Camera returned \(rows.count) rows, not \(limit + 2).")
      return
    }
    #expect(rows[limit].value == "ABSENT-BODY")
    #expect(rows[limit].isActive)
    #expect(rows.last?.value == FilterPopoverModel.overflowValue)
    #expect(rows.last?.title == "+2 more cameras")
    #expect(rows.last?.isEnabled == false)
  }

  // MARK: - The wire: always a folder scope

  private func makeStore() async -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let store = GridStore(service: GridService(client: client))
    await transport.setFacetsResult(
      .init(keyword: facetCounts([("landscape", 7), ("street", 5)]), total: 12))
    await transport.setListImagesPage(.init(items: [], limit: 100, nextCursor: nil))
    return (store, transport)
  }

  @Test("The Keyword row's facets request always carries the folder, and none goes without one")
  func keywordRowAlwaysSendsAFolderScope() async {
    let (store, transport) = await makeStore()

    // (a) No shoot yet — the workspace's launch-time refresh: no request at all.
    await store.refreshFacets()
    let unscoped = await transport.recordedFacetsQueries
    #expect(unscoped.isEmpty)
    #expect(store.facets == nil)

    // (b) Scoped: the refresh and a Keyword tap both carry folder 7.
    await store.selectShoot(folderID: 7)
    await store.refreshFacets()
    #expect(section(.keyword, store.facets)?.rows.first?.value == "landscape")
    await store.applyFacetFilter(.keyword, value: "landscape")
    let facetsQueries = await transport.recordedFacetsQueries
    #expect(facetsQueries.count >= 2)
    #expect(facetsQueries.allSatisfy { $0["folder_id"] == "7" })
    #expect(facetsQueries.last?["keyword"] == "landscape")
    let images = await transport.lastListImagesQuery
    #expect(images?["folder_id"] == "7")
    #expect(images?["keyword"] == "landscape")
  }

  @Test("Going unscoped clears the counts, and a late scoped response cannot refill them")
  func goingUnscopedClearsTheCountsAndALateResponseCannotRefill() async {
    let (store, transport) = await makeStore()
    await store.selectShoot(folderID: 7)
    await store.refreshFacets()
    #expect(store.facets != nil)
    #expect(store.facetsIdentity != nil)

    // A new scoped query whose refresh is held in flight.
    await store.applyFilterChange { $0.keyword = "street" }
    await transport.holdFacetsRequests(true)
    let late = Task { await store.refreshFacets() }
    await transport.waitUntilFacetsStarted()

    // Unscoped while it is held: the counts go, and no request is sent for the bare query.
    await transport.holdFacetsRequests(false)
    await store.applyFilterChange { $0.folderID = nil }
    await store.refreshFacets()
    #expect(store.facets == nil)
    #expect(store.facetsIdentity == nil)

    // The held scoped response lands late and is discarded.
    await transport.releaseFacets()
    await late.value
    #expect(store.facets == nil)
    #expect(store.facetsIdentity == nil)
    let facetsQueries = await transport.recordedFacetsQueries
    #expect(facetsQueries.count == 2)
    #expect(facetsQueries.allSatisfy { $0["folder_id"] == "7" })
  }
}
