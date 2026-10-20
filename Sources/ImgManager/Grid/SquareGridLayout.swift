import CoreGraphics

/// IMGMGR-551 (R3-7): how the grid lays its cells out — Arrange › Layout.
///
/// Presentation only, and NOT persisted, like the thumbnail size and the grouping
/// (`ArrangeModel`'s "nothing new is persisted"): `GridPreferences.persistedKeys` is unchanged. A
/// change fetches nothing and keeps the selection and the query.
enum GridLayoutStyle: String, CaseIterable, Sendable {
  /// The full-bleed justified rows (`JustifiedRowLayout`), the default.
  case justified
  /// Uniform square cells, each photograph centre-cropped (`SquareGridLayout`).
  case square

  /// The Arrange row's own words.
  var title: String {
    switch self {
    case .justified: "Justified"
    case .square: "Square"
    }
  }
}

/// The column count and cell edge one square pass packs with.
struct SquareGridGeometry: Equatable, Sendable {
  let columns: Int
  let edge: CGFloat
}

/// IMGMGR-551 (R3-7): the Square layout's packer — a PARALLEL function to
/// `JustifiedRowLayout.packWithTierPlan`, deliberately not a second implementation behind a shared
/// protocol (the justified engine is untouched).
///
/// Every cell is an `edge × edge` square and every row the same height. The column count is the
/// number of cells of the target edge that fit best, and the edge is then chosen so a full row
/// fills the pane EXACTLY (Σ edges + gaps == pane width). A trailing partial row keeps the same
/// edge, left-aligned, never stretched.
///
/// Tier choice follows the CENTRE-CROP fill size: an image of aspect `a` drawn to cover an `e × e`
/// cell renders at `e·max(a, 1) × e·max(1/a, 1)`, so a 3:1 panorama in a 120-pt cell needs a
/// 360-pt long edge of pixels, not 120. The tier is chosen exactly as the justified packer does
/// it — this image's own `.grid` availability first, so its served grid edge sets the ceiling.
///
/// There is NO never-upscale cap here: a uniform grid IS the layout, and a cap that shrank one row
/// would break it. An available tier is displayed at `edge × edge`; an unavailable one becomes the
/// same placeholder plan the justified packer emits. Placeholder plans carry no size — the square
/// geometry travels on the row (`PackedRow.squareEdge`), independent of any proxy having loaded.
enum SquareGridLayout {

  /// The columns and edge for one pane, or nil when there is nothing to pack into.
  static func geometry(
    paneWidth: CGFloat, targetCellEdge: CGFloat, spacing: CGFloat
  ) -> SquareGridGeometry? {
    guard paneWidth > 0, targetCellEdge > 0 else { return nil }
    let gap = max(spacing, 0)
    let fit = ((paneWidth + gap) / (targetCellEdge + gap)).rounded()
    var columns = max(1, Int(fit))
    var edge = (paneWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)
    // A gutter wider than the pane can afford collapses to one column rather than a negative edge.
    if edge <= 0 {
      columns = 1
      edge = paneWidth
    }
    return SquareGridGeometry(columns: columns, edge: edge)
  }

  /// The size an image of `aspectRatio` renders at when it covers an `edge × edge` cell.
  static func fillSize(aspectRatio: Double, edge: CGFloat) -> CGSize {
    let aspect = aspectRatio > 0 ? CGFloat(aspectRatio) : 1
    return CGSize(width: edge * max(aspect, 1), height: edge * max(1 / aspect, 1))
  }

  static func packWithTierPlan(
    tiles: [JustifiedTile],
    paneWidth: CGFloat,
    targetCellEdge: CGFloat,
    displayScale: CGFloat,
    spacing: CGFloat = 2,
    availability: (GridDisplayID, ProxyTier) -> ProxyAvailability
  ) -> [[PackedTilePlan]] {
    guard !tiles.isEmpty,
      let square = Self.geometry(
        paneWidth: paneWidth, targetCellEdge: targetCellEdge, spacing: spacing)
    else { return [] }
    let cell = CGSize(width: square.edge, height: square.edge)

    let plans = tiles.map { tile -> PackedTilePlan in
      // R3-15, as in the justified packer: the grid ceiling follows THIS image's served grid
      // edge, so a row mixing 400- and 800-px grid proxies picks per image.
      let grid = availability(tile.id, .grid)
      let tier = GridTierResolver.chooseTier(
        for: fillSize(aspectRatio: tile.aspectRatio, edge: square.edge),
        displayScale: displayScale,
        servedGridEdge: GridTierResolver.servedGridEdge(grid))
      switch tier == .grid ? grid : availability(tile.id, tier) {
      case .pending:
        return PackedTilePlan(id: tile.id, plan: .placeholder(reason: .pending))
      case .permanentFail:
        return PackedTilePlan(id: tile.id, plan: .placeholder(reason: .permanentFail))
      case .missing:
        return PackedTilePlan(id: tile.id, plan: .placeholder(reason: .missing))
      case .ok:
        return PackedTilePlan(id: tile.id, plan: .display(tier: tier, size: cell))
      }
    }

    return stride(from: 0, to: plans.count, by: square.columns).map { start in
      Array(plans[start..<min(start + square.columns, plans.count)])
    }
  }
}
