import CoreGraphics
import Testing

@testable import ImgManager

/// Diff-gate round 2, blocker 2: the row is the unit of reflow/cap, never an individual tile —
/// and tier selection uses the tile's ACTUAL packed (justified) size, never a nominal row-height
/// guess. `packWithTierPlan` is what `GridView` actually renders from.
@Suite("Justified row layout — row-level tier/reflow (diff-gate round 2, blocker 2)")
struct JustifiedRowLayoutTests {

  @Test(
    "A single-tile row: tier chosen from its real packed size, no cap needed when pixels suffice")
  func singleTileNoCappingNeeded() {
    let tiles = [JustifiedTile(id: .image(1), aspectRatio: 1.0)]
    let rows = JustifiedRowLayout.packWithTierPlan(
      tiles: tiles, paneWidth: 400, targetRowHeight: 400, displayScale: 1.0
    ) { _, tier in
      #expect(tier == .grid)  // 400x400pt @1x -> 400 required pixels -> grid, exactly the ceiling
      return .ok(width: 400, height: 400)
    }
    #expect(rows.count == 1)
    #expect(rows[0].count == 1)
    guard case .display(let tier, let size) = rows[0][0].plan else {
      Issue.record("expected .display, got \(rows[0][0].plan)")
      return
    }
    #expect(tier == .grid)
    #expect(size == CGSize(width: 400, height: 400))
  }

  @Test(
    "Row-wide cap: a pixel-starved tile shrinks its WHOLE ROW, including a sibling that would otherwise fit"
  )
  func rowWideCapAffectsEveryTileInTheRow() {
    // Two square tiles, pane exactly fits them side by side at the 400pt target row height
    // (2 * 400 + spacing == paneWidth), scale 1. Tile A's preview proxy only actually has
    // 200x200 pixels (half of the 400 required) -> the row must cap to 0.5. Tile B's own proxy
    // has AMPLE pixels (would need no cap on its own) but must still shrink to the SAME 0.5,
    // proving the cap is row-wide, not per-tile.
    let tiles = [
      JustifiedTile(id: .image(1), aspectRatio: 1.0),
      JustifiedTile(id: .image(2), aspectRatio: 1.0),
    ]
    let paneWidth: CGFloat = 802  // 400 + 400 + 2pt spacing
    let rows = JustifiedRowLayout.packWithTierPlan(
      tiles: tiles, paneWidth: paneWidth, targetRowHeight: 400, displayScale: 1.0
    ) { displayID, _ in
      displayID == .image(1) ? .ok(width: 200, height: 200) : .ok(width: 4000, height: 4000)
    }
    #expect(rows.count == 1)
    #expect(rows[0].count == 2)

    guard case .display(_, let sizeA) = rows[0][0].plan,
      case .display(_, let sizeB) = rows[0][1].plan
    else {
      Issue.record("expected both tiles to display, got \(rows[0])")
      return
    }
    // Row packed each tile at ~400pt naturally (both square, pane splits evenly); tile A's
    // 200px ceiling caps the row to scale 0.5 -> both tiles render at ~200pt, not just A.
    #expect(abs(sizeA.height - 200) < 1)
    #expect(abs(sizeB.height - 200) < 1)
    #expect(abs(sizeA.height - sizeB.height) < 0.01)  // uniform row height preserved
  }

  @Test(
    "A tile whose chosen tier is unavailable renders a placeholder and never drags the row down")
  func unavailableTileIsPlaceholderAndDoesNotCapSiblings() {
    let tiles = [
      JustifiedTile(id: .image(1), aspectRatio: 1.0),
      JustifiedTile(id: .image(2), aspectRatio: 1.0),
    ]
    let paneWidth: CGFloat = 802
    let rows = JustifiedRowLayout.packWithTierPlan(
      tiles: tiles, paneWidth: paneWidth, targetRowHeight: 400, displayScale: 1.0
    ) { displayID, _ in
      displayID == .image(1) ? .pending : .ok(width: 4000, height: 4000)
    }
    #expect(rows[0][0].plan == .placeholder(reason: .pending))
    guard case .display(_, let sizeB) = rows[0][1].plan else {
      Issue.record("expected tile 2 to display uncapped, got \(rows[0][1].plan)")
      return
    }
    // Tile 2 has ample pixels and tile 1's placeholder does not participate in the cap
    // computation, so tile 2 renders at its full natural (uncapped) size.
    #expect(abs(sizeB.height - 400) < 1)
  }

  @Test("Panorama: an extreme aspect ratio still never upscales beyond the tier's real pixels")
  func panoramaNeverUpscales() {
    // A 4:1 panorama alone in its row at the 400pt target, scale 2 -> natural width 1600pt,
    // requiredPixels = max(1600,400)*2 = 3200. Preview only actually has 1600x400 (long edge
    // 1600) -> capScale = 1600/3200 = 0.5 -> rendered width 800pt, height 200pt.
    let tiles = [JustifiedTile(id: .image(1), aspectRatio: 4.0)]
    // R3-15: pass 1 reads the grid entry first for the served edge (400 here, so the 3200px
    // requirement is preview either way), then asks for the chosen tier.
    let rows = JustifiedRowLayout.packWithTierPlan(
      tiles: tiles, paneWidth: 4000, targetRowHeight: 400, displayScale: 2.0
    ) { _, tier in
      tier == .grid ? .ok(width: 400, height: 100) : .ok(width: 1600, height: 400)
    }
    guard case .display(let tier, let size) = rows[0][0].plan else {
      Issue.record("expected .display, got \(rows[0][0].plan)")
      return
    }
    #expect(tier == .preview)
    #expect(abs(size.width - 800) < 1)
    #expect(abs(size.height - 200) < 1)
    // Never upscale: rendered pixels never exceed what the tier actually reported.
    #expect(Double(size.width) * 2.0 <= 1600.0 + 0.001)
  }

  @Test("Empty tile list produces no rows")
  func emptyProducesNoRows() {
    let rows = JustifiedRowLayout.packWithTierPlan(
      tiles: [], paneWidth: 400, targetRowHeight: 200, displayScale: 1.0
    ) { _, _ in .missing }
    #expect(rows.isEmpty)
  }

  @Test(
    "R3-15: one row mixing a served-800 and a served-400 grid proxy picks grid and preview per tile"
  )
  func mixedServedEdgesInOneRow() {
    // Two square tiles at 300pt, scale 2 -> 600px required: within tile 1's served 800 edge
    // (grid), beyond tile 2's served 400 edge (preview) — the mix P3c adoption produces.
    let tiles = [
      JustifiedTile(id: .image(1), aspectRatio: 1.0),
      JustifiedTile(id: .image(2), aspectRatio: 1.0),
    ]
    let paneWidth: CGFloat = 602  // 300 + 300 + 2pt spacing
    var asked: [GridDisplayID: [ProxyTier]] = [:]
    let rows = JustifiedRowLayout.packWithTierPlan(
      tiles: tiles, paneWidth: paneWidth, targetRowHeight: 300, displayScale: 2.0
    ) { displayID, tier in
      asked[displayID, default: []].append(tier)
      switch (displayID, tier) {
      case (.image(1), .grid): return .ok(width: 800, height: 800)
      case (.image(2), .grid): return .ok(width: 400, height: 400)
      default: return .ok(width: 1600, height: 1600)
      }
    }
    #expect(rows.count == 1)
    guard case .display(let tierA, let sizeA) = rows[0][0].plan,
      case .display(let tierB, let sizeB) = rows[0][1].plan
    else {
      Issue.record("expected both tiles to display, got \(rows)")
      return
    }
    #expect(tierA == .grid)
    #expect(tierB == .preview)
    // The row cap is unchanged: 800px grid and 1600px preview both cover 600px -> no cap.
    #expect(abs(sizeA.height - 300) < 1)
    #expect(abs(sizeB.height - 300) < 1)
    // The grid answer is reused for a grid tile; only the preview tile asks twice.
    #expect(asked[.image(1)] == [.grid])
    #expect(asked[.image(2)] == [.grid, .preview])
  }
}
