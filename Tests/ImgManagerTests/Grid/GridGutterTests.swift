import CoreGraphics
import Testing

@testable import ImgManager

/// R3-12 (IMGMGR-539): 1-pt gutters at the 120 and 160 steps, 2 pt above — and the packer, fed
/// the same value the grid renders, fills the pane exactly (Σ widths + gaps == pane width).
@Suite("Grid gutter (R3-12)")
struct GridGutterTests {

  @Test("1 pt at 120/160, 2 pt at 200/260/320/400")
  func gutterPerStep() {
    let gutters = GridRowHeight.allCases.map { GridGutter.spacing(for: $0) }
    #expect(GridRowHeight.allCases.map(\.rawValue) == [120, 160, 200, 260, 320, 400])
    #expect(gutters == [1, 1, 2, 2, 2, 2])
  }

  @Test("A full row packed at 120pt with a 1-pt gutter fills the pane width exactly")
  func fullRowFillsPaneWithOnePointGutter() {
    let spacing = GridGutter.spacing(for: .step120)
    // Landscape with every third tile portrait, so rows hold differing tile counts.
    let tiles = (1...12).map { id in
      JustifiedTile(id: .image(id), aspectRatio: id.isMultiple(of: 3) ? 0.67 : 1.5)
    }
    let paneWidth: CGFloat = 390
    let rows = JustifiedRowLayout.packWithTierPlan(
      tiles: tiles, paneWidth: paneWidth, targetRowHeight: 120, displayScale: 2.0,
      spacing: spacing
    ) { _, _ in .ok(width: 1600, height: 1600) }
    #expect(rows.count > 1)
    // Every row but the trailing partial one is justified to the pane width.
    for row in rows.dropLast() {
      let widths = row.compactMap { tile -> CGFloat? in
        guard case .display(_, let size) = tile.plan else { return nil }
        return size.width
      }
      #expect(widths.count == row.count)
      let filled = widths.reduce(0, +) + spacing * CGFloat(row.count - 1)
      #expect(abs(filled - paneWidth) <= 0.5)
    }
  }

  /// IMGMGR-539 fold: the grid packs into the pane less its content inset on both sides. The
  /// iPhone fixture's first row at 200 (tiles 1.5 and 1.0 on a 402-pt pane) was packed against
  /// the bare pane, overflowed its padded container by 4 pt and rendered its tiles abutting.
  @Test("Rows pack inside the content inset: the iPhone fixture's first row fits with its gap")
  func rowsPackInsideTheContentInset() {
    #expect(GridGutter.contentInset == 2)
    #expect(GridGutter.packingWidth(forPane: 402) == 398)
    #expect(GridGutter.packingWidth(forPane: 3) == 0)
    let pane: CGFloat = 402
    let spacing = GridGutter.spacing(for: .step200)
    let tiles = [1.5, 1.0, 0.75].enumerated().map { index, aspect in
      JustifiedTile(id: .image(index + 1), aspectRatio: aspect)
    }
    let rows = JustifiedRowLayout.packWithTierPlan(
      tiles: tiles, paneWidth: GridGutter.packingWidth(forPane: pane), targetRowHeight: 200,
      displayScale: 3.0, spacing: spacing
    ) { _, _ in .ok(width: 1600, height: 1600) }
    let widths = (rows.first ?? []).compactMap { tile -> CGFloat? in
      guard case .display(_, let size) = tile.plan else { return nil }
      return size.width
    }
    #expect(widths.count == 2)
    let occupied = widths.reduce(0, +) + spacing + 2 * GridGutter.contentInset
    #expect(abs(occupied - pane) <= 0.5)
  }
}
