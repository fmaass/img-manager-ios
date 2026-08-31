import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-256 (folded into WP13 P11, owner feedback 2026-08-31): the Scene-view banner line and
/// its Exit button are GONE. What says "you are in an arrangement" is the Group control itself,
/// rendered highlighted whenever a grouping is in force — Scene or one of the six dimensions.
///
/// The behaviour the banner described is unchanged: a collapsed scene is still not selectable
/// (ADR-0005), which `GridStoreSceneTests`' boundary suite continues to prove. Only the caption
/// row is removed.
///
/// `GridView.chromeRows` renders exactly `GridChromeRows.rows(...)` and holds no second list, so
/// these are value tests on the rendered set rather than readings of a `@ViewBuilder`.
@MainActor
@Suite("Grid chrome rows — Scene adds no banner of its own (IMGMGR-256)")
struct GridChromeRowsTests {

  private func makeImage(id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeSceneStore() async -> GridStore {
    let transport = GridStubTransport()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    // Cover id 900 appears nowhere else, the same convention `GridStoreSceneTests` uses.
    let stackRow = Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: nil, hasPick: false, kind: .stack, matchedCount: 3, memberCount: 3,
      representative: makeImage(id: 900), stackId: 5)
    let item = Components.Schemas.StackBrowsePage.ItemsPayloadPayload(
      value1: nil, value2: stackRow)
    await transport.setBrowseStacksPage(
      Components.Schemas.StackBrowsePage(items: [item], limit: 100, nextCursor: nil))
    let client = ImgManagerAPIClient.make(transport: transport)
    let store = GridStore(service: GridService(client: client))
    await store.selectShoot(folderID: 1)
    await store.selectGrouping(.scene)
    return store
  }

  @Test("Scene mode renders NO chrome row of its own, on either idiom")
  func sceneModeRendersNoBannerRow() async {
    let store = await makeSceneStore()
    #expect(store.displayMode == .scene, "the fixture is not in Scene mode")

    #expect(
      GridChromeRows.rows(layoutMode: .regular2, store: store) == [],
      "Scene mode still adds a chrome row on Regular")
    #expect(
      GridChromeRows.rows(layoutMode: .regular3, store: store) == [],
      "Scene mode still adds a chrome row on Regular-3")
    // Compact's persistent options row is not Scene's — it is there in every mode, which is what
    // makes it the positive control for the two 0-row assertions above.
    #expect(
      GridChromeRows.rows(layoutMode: .compact, store: store) == [.options],
      "Compact's rows in Scene mode are not exactly its persistent options row")
  }

  @Test("The mode rows that DO exist still render — Select and the locks, in their pinned order")
  func theSurvivingModeRowsStillRender() async {
    let store = await makeSceneStore()

    store.enterSelectExplicitly()
    #expect(GridChromeRows.rows(layoutMode: .regular2, store: store) == [.select])
    #expect(GridChromeRows.rows(layoutMode: .compact, store: store) == [.options, .select])

    // `lockFromMenu` REFUSES while Select is active (GridStore.swift:1414), so the way from one
    // mode row to the other is through the way out — which is also the rule this row set exists
    // to render: at most one of them, ever.
    store.done()
    store.lockFromMenu(.dislike)
    #expect(GridChromeRows.rows(layoutMode: .regular2, store: store) == [.pickLock(.dislike)])
    // At most ONE mode row, whichever way the screen got here: one latched verb, one list.
    #expect(GridChromeRows.rows(layoutMode: .regular2, store: store).count == 1)
  }
}

/// The other half of IMGMGR-256: the Group control carries the state the banner used to.
@MainActor
@Suite("Group control — highlighted exactly while an arrangement is in force (IMGMGR-256)")
struct GridGroupControlHighlightTests {

  @Test("The highlight is on for Scene and for every dimension, and off for None")
  func theHighlightTracksTheGroupingChoice() {
    #expect(GridGroupControl.isHighlighted(for: .none) == false)
    #expect(GridGroupControl.isHighlighted(for: .scene), "Scene does not highlight the control")
    for key in SortGroupOptions.groupKeys {
      #expect(
        GridGroupControl.isHighlighted(for: .key(key)),
        "grouping by \(key.rawValue) does not highlight the control")
    }
    // Every offered choice is covered by the two rules above — asserted, not assumed, so a
    // seventh choice cannot slip in unhighlighted.
    for choice in SortGroupOptions.groupingChoices {
      #expect(GridGroupControl.isHighlighted(for: choice) == (choice != .none))
    }
  }
}
