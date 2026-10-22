import CoreGraphics
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-551 (R3-7): the Square layout — uniform square cells, 1-pt gutters at 120/160 and 2 pt
/// above, full rows filling the pane exactly, tier chosen from the centre-crop fill size, and the
/// square geometry carried on the row independent of whether any proxy is available.
@MainActor
@Suite("Square grid layout (R3-7)")
struct SquareGridLayoutTests {

  private let alwaysAvailable: (GridDisplayID, ProxyTier) -> ProxyAvailability = {
    _, _ in
    .ok(width: 4000, height: 4000)
  }

  /// Landscape, square, portrait and a 3.5:1 panorama — the fixture's own mix.
  private let aspects: [Double] = [1.5, 1.0, 0.75, 3.5, 1.5, 1.5, 1.0, 1.5, 2.0, 1.0, 0.75]

  private var tiles: [JustifiedTile] {
    aspects.enumerated().map { JustifiedTile(id: .image($0.offset + 1), aspectRatio: $0.element) }
  }

  private func image(id: Int, groupKey: String? = nil, aspect: Double = 1.0)
    -> Components.Schemas.ImageSummary
  {
    Components.Schemas.ImageSummary(
      aspectRatio: aspect, ext: "jpg", filename: "img\(id).jpg", folderId: 1, groupKey: groupKey,
      hasEdit: false, id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []), missing: false,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func displaySize(_ plan: TileRenderPlan) -> CGSize? {
    guard case .display(_, let size) = plan else { return nil }
    return size
  }

  private func tier(_ plan: TileRenderPlan) -> ProxyTier? {
    guard case .display(let tier, _) = plan else { return nil }
    return tier
  }

  @Test("At 120 and 160: square cells, 1-pt gutters, full rows fill the pane, one row height")
  func squareCellsFillThePaneAtTheSmallSteps() throws {
    let pane = GridGutter.packingWidth(forPane: 402)
    for step in [GridRowHeight.step120, .step160] {
      let spacing = GridGutter.spacing(for: step)
      #expect(spacing == 1)
      let geometry = try #require(
        SquareGridLayout.geometry(paneWidth: pane, targetCellEdge: step.rawValue, spacing: spacing))
      let rows = SquareGridLayout.packWithTierPlan(
        tiles: tiles, paneWidth: pane, targetCellEdge: step.rawValue, displayScale: 3,
        spacing: spacing, availability: alwaysAvailable)

      #expect(rows.count > 1, "\(step): one row proves nothing about row heights")
      #expect(rows.flatMap { $0 }.map(\.id) == tiles.map(\.id), "\(step): order or count changed")
      for (index, row) in rows.enumerated() {
        let sizes = row.compactMap { displaySize($0.plan) }
        #expect(sizes.count == row.count)
        // Every cell square at the one edge, so every row has the same height.
        #expect(sizes.allSatisfy { $0.width == geometry.edge && $0.height == geometry.edge })
        if index < rows.count - 1 {
          #expect(row.count == geometry.columns)
          let filled = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(row.count - 1)
          #expect(abs(filled - pane) <= 0.5, "\(step): a full row fills \(filled) of \(pane)")
        } else {
          // Trailing partial row: same edge, never stretched to fill.
          #expect(row.count <= geometry.columns)
        }
      }
      // 11 tiles never divide evenly into these column counts: the trailing row IS partial.
      #expect(rows.last.map { $0.count < geometry.columns } == true, "\(step): no partial row")
    }
  }

  @Test("Boundaries: nothing to pack, a pane narrower than one cell, one tile")
  func geometryBoundaries() {
    #expect(SquareGridLayout.geometry(paneWidth: 0, targetCellEdge: 120, spacing: 1) == nil)
    #expect(SquareGridLayout.geometry(paneWidth: 398, targetCellEdge: 0, spacing: 1) == nil)
    // Narrower than one target cell: one column, as wide as the pane.
    #expect(
      SquareGridLayout.geometry(paneWidth: 50, targetCellEdge: 120, spacing: 1)
        == SquareGridGeometry(columns: 1, edge: 50))
    let none = SquareGridLayout.packWithTierPlan(
      tiles: [], paneWidth: 398, targetCellEdge: 120, displayScale: 2, spacing: 1,
      availability: alwaysAvailable)
    #expect(none.isEmpty)
    let one = SquareGridLayout.packWithTierPlan(
      tiles: [JustifiedTile(id: .image(1), aspectRatio: 1.5)], paneWidth: 362,
      targetCellEdge: 120, displayScale: 2, spacing: 1, availability: alwaysAvailable)
    #expect(one.map(\.count) == [1])
    #expect(one.first?.first?.plan == .display(tier: .grid, size: CGSize(width: 120, height: 120)))
  }

  @Test("At 200 the gutter is 2 pt and full rows still fill the pane")
  func twoPointGutterAtTwoHundred() throws {
    let pane: CGFloat = 1020
    let spacing = GridGutter.spacing(for: .step200)
    #expect(spacing == 2)
    let geometry = try #require(
      SquareGridLayout.geometry(paneWidth: pane, targetCellEdge: 200, spacing: spacing))
    #expect(geometry.columns == 5)
    let rows = SquareGridLayout.packWithTierPlan(
      tiles: tiles, paneWidth: pane, targetCellEdge: 200, displayScale: 2, spacing: spacing,
      availability: alwaysAvailable)
    let full = try #require(rows.first)
    let filled = CGFloat(full.count) * geometry.edge + spacing * CGFloat(full.count - 1)
    #expect(abs(filled - pane) <= 0.5)
  }

  @Test("The tier follows the centre-crop fill size and each image's own served grid edge")
  func tierFollowsTheFillSizePerImage() throws {
    // 3 columns of exactly 120 pt with a 1-pt gutter: 3 × 120 + 2 = 362.
    let geometry = try #require(
      SquareGridLayout.geometry(paneWidth: 362, targetCellEdge: 120, spacing: 1))
    #expect(geometry == SquareGridGeometry(columns: 3, edge: 120))
    // A 3:1 panorama covering a 120-pt cell renders 360 × 120 pt: ≥ 360·scale pixels long.
    #expect(SquareGridLayout.fillSize(aspectRatio: 3, edge: 120) == CGSize(width: 360, height: 120))
    #expect(
      SquareGridLayout.fillSize(aspectRatio: 0.5, edge: 120) == CGSize(width: 120, height: 240))

    // One row: a 400-px-grid panorama, a square, an 800-px-grid panorama. At scale 2 a panorama
    // needs 720 px — over a 400 grid (preview), within an 800 grid (grid). A square needs 240.
    let rowTiles = [
      JustifiedTile(id: .image(1), aspectRatio: 3),
      JustifiedTile(id: .image(2), aspectRatio: 1),
      JustifiedTile(id: .image(3), aspectRatio: 3),
    ]
    let rows = SquareGridLayout.packWithTierPlan(
      tiles: rowTiles, paneWidth: 362, targetCellEdge: 120, displayScale: 2, spacing: 1
    ) { id, tier in
      switch (id, tier) {
      case (.image(1), .grid): return .ok(width: 400, height: 133)
      case (.image(2), .grid): return .ok(width: 400, height: 400)
      case (.image(3), .grid): return .ok(width: 800, height: 267)
      default: return .ok(width: 1600, height: 533)
      }
    }
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.map { tier($0.plan) } == [.preview, .grid, .grid])
    // Whatever the tier, the cell is the square edge — no never-upscale cap shrinks the grid.
    #expect(row.allSatisfy { displaySize($0.plan) == CGSize(width: 120, height: 120) })
  }

  @Test("Placeholders keep their reason and their row still carries the square edge")
  func placeholdersKeepTheirReasonAndTheRowItsEdge() throws {
    let stream = [image(id: 1), image(id: 2), image(id: 3), image(id: 4)]
      .map(SceneDisplayRow.image)
    let rendered = GridSectionLayout.renderRows(
      rows: stream, groupBy: nil, headers: [:], timezone: nil, paneWidth: 362,
      targetRowHeight: 120, displayScale: 2, spacing: 1, layout: .square
    ) { id, _ in
      switch id {
      case .image(1): return .pending
      case .image(2): return .permanentFail
      case .image(3): return .missing
      default: return .ok(width: 4000, height: 4000)
      }
    }
    let rows = rendered.compactMap(\.packedRow)
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.squareEdge == 120 }, "a square row lost its edge")
    let plans = rows.flatMap(\.cells).map(\.plan)
    #expect(
      plans == [
        .placeholder(reason: .pending), .placeholder(reason: .permanentFail),
        .placeholder(reason: .missing),
        .display(tier: .grid, size: CGSize(width: 120, height: 120)),
      ])
  }

  @Test("Scene cards pack into square cells exactly like photographs")
  func sceneCardsPackLikeImages() throws {
    let mixed = [
      JustifiedTile(id: .image(1), aspectRatio: 1.5),
      JustifiedTile(id: .stack(5), aspectRatio: 0.75),
      JustifiedTile(id: .image(2), aspectRatio: 3.5),
    ]
    let rows = SquareGridLayout.packWithTierPlan(
      tiles: mixed, paneWidth: 362, targetCellEdge: 120, displayScale: 2, spacing: 1,
      availability: alwaysAvailable)
    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.map(\.id) == [.image(1), .stack(5), .image(2)])
    #expect(row.allSatisfy { displaySize($0.plan) == CGSize(width: 120, height: 120) })
  }

  @Test("Grouped, a square row never straddles a section header")
  func squareRowsNeverStraddleAHeader() throws {
    let stream = [
      image(id: 1, groupKey: "A"), image(id: 2, groupKey: "A"),
      image(id: 3, groupKey: "B"), image(id: 4, groupKey: "B"),
      image(id: 5, groupKey: nil), image(id: 6, groupKey: nil),
    ].map(SceneDisplayRow.image)
    let headers: [GroupKey: Components.Schemas.GroupHeader] = [
      .known("A"): .init(count: 2, key: "A", label: "A"),
      .known("B"): .init(count: 2, key: "B", label: "B"),
      .unknown: .init(count: 2, key: nil, label: "Unknown"),
    ]
    // 800 pt at 120 holds six columns, so ONE unsectioned pass would put all six in one row.
    let rendered = GridSectionLayout.renderRows(
      rows: stream, groupBy: .camera, headers: headers, timezone: nil, paneWidth: 800,
      targetRowHeight: 120, displayScale: 2, spacing: 1, layout: .square,
      availability: alwaysAvailable)

    var currentKey: GroupKey?
    var tileRows = 0
    for renderRow in rendered {
      switch renderRow {
      case .header(let header):
        currentKey = header.key
      case .tiles(let row):
        tileRows += 1
        #expect(row.squareEdge != nil)
        let keys = row.cells.compactMap(\.id.imageID).map { id in
          GridSectionLayout.groupKey(of: stream[id - 1])
        }
        #expect(keys.allSatisfy { $0 == currentKey }, "a square row straddles a header: \(keys)")
      case .remainder:
        Issue.record("camera grouping has no remainder row")
      }
    }
    #expect(tileRows == 3)
  }

  @Test("Justified rows carry no square edge, by default and when asked for by name")
  func justifiedRowsCarryNoSquareEdge() {
    let stream = (1...6).map { image(id: $0, aspect: 1.5) }.map(SceneDisplayRow.image)
    let byDefault = GridSectionLayout.renderRows(
      rows: stream, groupBy: nil, headers: [:], timezone: nil, paneWidth: 398,
      targetRowHeight: 120, displayScale: 2, spacing: 1, availability: alwaysAvailable)
    let byName = GridSectionLayout.renderRows(
      rows: stream, groupBy: nil, headers: [:], timezone: nil, paneWidth: 398,
      targetRowHeight: 120, displayScale: 2, spacing: 1, layout: .justified,
      availability: alwaysAvailable)
    #expect(byName == byDefault, "the default layout is not justified")
    for rendered in [byDefault, byName] {
      let rows = rendered.compactMap(\.packedRow)
      #expect(!rows.isEmpty)
      #expect(rows.allSatisfy { $0.squareEdge == nil })
    }
  }

  /// D1: a layout change is presentation only — the selection survives it, where a size step
  /// resets it (the positive control that the read below can see a reset at all).
  @Test("Changing the layout keeps the selection; a size step still resets it")
  func layoutChangeKeepsTheSelection() {
    let client = ImgManagerAPIClient.make(transport: GridStubTransport())
    let store = GridStore(service: GridService(client: client))
    #expect(store.layoutStyle == .justified)
    store.enterSelectExplicitly()
    #expect(store.selection.mode == .select)

    store.setLayoutStyle(.square)
    #expect(store.layoutStyle == .square)
    #expect(store.selection.mode == .select, "a layout change reset the selection")

    let other = GridRowHeight.allCases.first { $0 != store.rowHeight } ?? .step120
    store.setRowHeight(other)
    #expect(store.selection.mode == .browse)
    #expect(store.layoutStyle == .square, "a size step changed the layout")
  }
}
