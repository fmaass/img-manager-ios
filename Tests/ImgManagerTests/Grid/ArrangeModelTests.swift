import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP29 P2 (IMGMGR-453) acceptance, unit half: the Arrange popover is 24 rows in five sections,
/// none of which nests, and every row round-trips through the store's own setters and getters —
/// there is no second state and no new persisted key (plan Decision 7).
@MainActor
@Suite("Arrange popover — rows, depth and store round-trip (WP29 P2)")
struct ArrangeModelTests {

  private func makeImage(id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  /// A store on a shoot, with a stacks page so Scene can be entered (the `GridChromeRowsTests`
  /// fixture shape).
  private func makeStore() async -> GridStore {
    let transport = GridStubTransport()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    let stackRow = Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: nil, editedCount: 0, hasPick: false, kind: .stack, matchedCount: 3,
      memberCount: 3, pickedCount: 0, representative: makeImage(id: 900), stackId: 5)
    await transport.setBrowseStacksPage(
      Components.Schemas.StackBrowsePage(
        items: [.init(value1: nil, value2: stackRow)], limit: 100, nextCursor: nil))
    let client = ImgManagerAPIClient.make(transport: transport)
    let store = GridStore(service: GridService(client: client))
    await store.selectShoot(folderID: 1)
    return store
  }

  /// IMGMGR-551 (R3-7) added the Layout section (two rows) before Thumbnail size.
  @Test("24 rows in five sections: sort keys, directions, groupings, layouts, sizes")
  func twentyFourRowsInFiveSections() {
    let sections = ArrangeModel.sections
    #expect(
      sections.map(\.id) == [
        "arrange.section.sort", "arrange.section.direction", "arrange.section.group",
        "arrange.section.layout", "arrange.section.size",
      ])
    #expect(sections.map(\.rows.count) == [6, 2, 8, 2, 6])
    #expect(ArrangeModel.rows.count == 24)
    #expect(Set(ArrangeModel.rows.map(\.id)).count == 24, "two rows share an identifier")
    #expect(sections.allSatisfy { !$0.title.isEmpty })

    #expect(
      ArrangeModel.rows.map(\.id) == [
        "arrange.sort.date_taken", "arrange.sort.filename", "arrange.sort.rating",
        "arrange.sort.iso", "arrange.sort.camera", "arrange.sort.lens",
        "arrange.direction.asc", "arrange.direction.desc",
        "arrange.group.none", "arrange.group.scene", "arrange.group.day", "arrange.group.month",
        "arrange.group.camera", "arrange.group.lens", "arrange.group.iso",
        "arrange.group.location",
        "arrange.layout.justified", "arrange.layout.square",
        "arrange.size.120", "arrange.size.160", "arrange.size.200", "arrange.size.260",
        "arrange.size.320", "arrange.size.400",
      ])
    // The words a reader sees, from the shipped titles.
    let sortTitles = sections[0].rows.map(\.title)
    #expect(sortTitles == ["Date", "Filename", "Rating", "ISO", "Camera", "Lens"])
    #expect(sections[1].rows.map(\.title) == ["Ascending", "Descending"])
    #expect(sections[2].rows.prefix(2).map(\.title) == ["None", "Scene"])
    #expect(sections[3].title == "Layout")
    #expect(sections[3].rows.map(\.title) == ["Justified", "Square"])
    #expect(sections[3].rows.map(\.choice) == [.layout(.justified), .layout(.square)])
    #expect(sections[4].rows.first?.title == "120 pt")
  }

  /// Depth: the popover is depth 1 and every choice one tap inside it. A row has no field that
  /// could hold another row, so nesting is not something the type can express.
  @Test("No row carries a child row — every choice is depth 2")
  func noRowHasChildren() {
    for row in ArrangeModel.rows {
      let fields = Mirror(reflecting: row).children
      // Positive control: the reflection really read the row's fields.
      #expect(fields.contains { $0.label == "choice" })
      #expect(
        fields.allSatisfy { !($0.value is ArrangeRow) && !($0.value is [ArrangeRow]) },
        "\(row.id) carries a nested row")
    }
  }

  /// The round-trip, for EVERY row: `apply` through the store's own setter, then `isChecked` is
  /// true for that row and false for every sibling in its section, and the store's own getter
  /// holds the row's value.
  @Test("Every row round-trips through the store's shipped setters and getters")
  func everyRowRoundTrips() async {
    for section in ArrangeModel.sections {
      for row in section.rows {
        let store = await makeStore()
        let model = ArrangeModel(store: store)

        await model.apply(row)

        #expect(model.isChecked(row), "\(row.id) is not checked after it was applied")
        for sibling in section.rows where sibling.id != row.id {
          #expect(!model.isChecked(sibling), "\(sibling.id) is checked beside \(row.id)")
        }
        switch row.choice {
        case .sortKey(let key): #expect(store.activeSortKey == key)
        case .direction(let direction): #expect(store.activeDirection == direction)
        case .grouping(let choice): #expect(store.activeGrouping == choice)
        case .size(let step): #expect(store.rowHeight == step)
        case .layout(let style): #expect(store.layoutStyle == style)
        }
      }
    }
  }

  /// The shipped rule, kept: a sort key chosen in Scene leaves Scene (`applyFlatPresentation`).
  @Test("Choosing a sort key while in Scene leaves Scene")
  func sortInSceneLeavesScene() async throws {
    let store = await makeStore()
    let model = ArrangeModel(store: store)
    let scene = try #require(ArrangeModel.rows.first { $0.id == "arrange.group.scene" })
    await model.apply(scene)
    #expect(store.displayMode == .scene, "the fixture did not enter Scene")
    #expect(model.isChecked(scene))

    let rating = try #require(ArrangeModel.rows.first { $0.id == "arrange.sort.rating" })
    await model.apply(rating)

    #expect(store.displayMode == .flat, "a sort key chosen in Scene left the grid in Scene")
    #expect(store.activeSortKey == .rating)
    #expect(!model.isChecked(scene))
    #expect(store.activeGrouping == .none)
  }

  /// A choice made elsewhere (the menu-bar commands) reads back here: one state, not two.
  @Test("A change made through the store's other entry points reads back as checked")
  func externalChangesReadBack() async throws {
    let store = await makeStore()
    let model = ArrangeModel(store: store)
    store.keyboardActions.setRowHeight(.step400)
    let size400 = try #require(ArrangeModel.rows.first { $0.id == "arrange.size.400" })
    let size200 = try #require(ArrangeModel.rows.first { $0.id == "arrange.size.200" })
    #expect(model.isChecked(size400))
    #expect(!model.isChecked(size200))
  }

  @Test("No arrangement is persisted: GridPreferences owns exactly its eight keys")
  func noNewPersistedKey() {
    // IMGMGR-539 (R3-5) added the four Tile overlays keys; none of them is an arrangement.
    #expect(
      GridPreferences.persistedKeys == [
        GridPreferences.filenamePlatesKey, GridPreferences.autoAdvanceOnMarkKey,
        GridPreferences.picksInGroupsKey, GridPreferences.pruneMirroredArchiveKey,
        GridPreferences.overlayMarksKey, GridPreferences.overlayEditedKey,
        GridPreferences.overlayLightroomRatingKey, GridPreferences.overlaySourceKindKey,
      ])
    let words = [
      "sort", "direction", "groupby", "grouping", "rowheight", "thumbnail", "zoom", "layout",
    ]
    let arrangementKeys = GridPreferences.persistedKeys.filter { key in
      words.contains { key.lowercased().contains($0) }
    }
    #expect(arrangementKeys.isEmpty, "an arrangement key is persisted: \(arrangementKeys)")
  }

  /// IMGMGR-256, carried from the Group control to Arrange: highlighted while any grouping is in
  /// force, plain under None.
  @Test("The Arrange highlight is on for Scene and every dimension, and off for None")
  func theHighlightTracksTheGroupingChoice() {
    #expect(ArrangeModel.isHighlighted(for: .none) == false)
    #expect(ArrangeModel.isHighlighted(for: .scene))
    for choice in SortGroupOptions.groupingChoices {
      #expect(ArrangeModel.isHighlighted(for: choice) == (choice != .none))
    }
  }
}
