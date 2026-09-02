import CoreGraphics
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP16 P2 (IMGMGR-298), Codex delta round. The collapse that reclaims the inspector's width also
/// rebuilds `GridView` in a different split-view slot, so the `ScrollView` starts at offset zero
/// and the reader loses their place. The anchor that survives that is the subject here.
///
/// The load-bearing case is `theAnchorSurvivesARepack`, and it is the one a naive fix fails:
/// remembering the row id `ScrollView` reports looks correct and passes every same-width test,
/// because a row's identity is its LEADING CELL — and the collapse changes the pane width from
/// ~209 pt to the full window, which repacks every justified row and leaves that id naming
/// nothing. Removing the translation (storing and returning the row id directly) turns that test
/// RED while the round-trip test below stays green.
@Suite("Grid scroll anchor — a place in the sheet, not a place in one packing")
struct GridScrollAnchorTests {

  private func plan() -> TileRenderPlan {
    TileRenderPlan.display(tier: .grid, size: CGSize(width: 120, height: 80))
  }

  private func tileRow(_ ids: [Int]) -> GridRenderRow {
    let cells = ids.map { PackedTilePlan(id: .image($0), plan: plan()) }
    return .tiles(PackedRow(id: .image(ids[0]), cells: cells))
  }

  private func headerRow(_ key: String) -> GridRenderRow {
    .header(GroupHeaderRow(key: .known(key), label: key, count: 9, timezone: nil))
  }

  @Test("A scroll position reduces to the photograph its row leads with")
  func aScrollPositionReducesToItsLeadingPhotograph() {
    #expect(GridScrollAnchor.displayID(of: .tiles(.image(7))) == .image(7))
    #expect(GridScrollAnchor.displayID(of: .tiles(.stack(3))) == .stack(3))
    #expect(GridScrollAnchor.displayID(of: nil) == nil)
  }

  @Test("A header anchors nothing — it carries no photograph to re-find after a repack")
  func aHeaderAnchorsNothing() {
    #expect(GridScrollAnchor.displayID(of: .header(.known("SONY ILCE-7RM5"))) == nil)
  }

  @Test("At an unchanged width the anchor resolves to the row it came from")
  func theAnchorRoundTripsAtAnUnchangedWidth() {
    let rows = [tileRow([1, 2, 3]), tileRow([4, 5, 6]), tileRow([7, 8, 9])]
    let reported: GridRenderRowID = .tiles(.image(4))
    let stored = GridScrollAnchor.displayID(of: reported)
    #expect(GridScrollAnchor.row(containing: stored, in: rows) == reported)
  }

  /// THE case the collapse actually produces. Narrow: three per row, so the reader's top row is
  /// led by photograph 4. Wide: six per row, and 4 is now the FOURTH cell of the first row — the
  /// row id `.tiles(.image(4))` does not exist in the wide packing at all. The anchor must still
  /// resolve, to the row that holds photograph 4 now.
  @Test("The anchor survives a repack: the photograph moves rows, the position follows it")
  func theAnchorSurvivesARepack() {
    let narrow = [tileRow([1, 2, 3]), tileRow([4, 5, 6]), tileRow([7, 8, 9])]
    let wide = [tileRow([1, 2, 3, 4, 5, 6]), tileRow([7, 8, 9])]

    let stored = GridScrollAnchor.displayID(of: .tiles(.image(4)))
    #expect(stored == .image(4))
    // The proof that the naive implementation is wrong: that row id is gone from the wide packing.
    #expect(wide.contains { $0.id == .tiles(.image(4)) } == false)
    // ...and the anchor resolves anyway, to the row photograph 4 is now part of.
    #expect(GridScrollAnchor.row(containing: stored, in: wide) == .tiles(.image(1)))
    // Still correct in the other direction, so this is not a one-way accident.
    #expect(GridScrollAnchor.row(containing: stored, in: narrow) == .tiles(.image(4)))
  }

  @Test("An anchor whose photograph is no longer rendered leaves the position alone")
  func anAnchorOntoAVanishedPhotographResolvesToNothing() {
    let rows = [headerRow("Camera A"), tileRow([1, 2, 3])]
    // 99 was filtered out of the current page; a fallback to "some row" would be a jump the
    // reader did not ask for, so the answer is nil and `scrollPosition` is left untouched.
    #expect(GridScrollAnchor.row(containing: .image(99), in: rows) == nil)
    #expect(GridScrollAnchor.row(containing: nil, in: rows) == nil)
    // Positive control in the same test: a photograph that IS rendered still resolves, so the
    // nil answers above are about the anchor and not about the search being broken.
    #expect(GridScrollAnchor.row(containing: .image(2), in: rows) == .tiles(.image(1)))
  }
}
