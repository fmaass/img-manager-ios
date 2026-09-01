import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP16 P3 (IMGMGR-295), the declared scope item (gate round 1, B1): the inspector's Stats tab
/// keeps EVERY rating row the server sends, and each NUMERIC row starts stating the number the
/// filter it already applies actually delivers.
///
/// The defect this closes shipped long before this phase: `InspectorFacetField.rating.toggle`
/// applies `rating_min` — a `>=` — while `InspectorView.facetRows` renders the server's EXACT
/// bucket, so a row labelled "4" states the count of exactly-4 and delivers 4-and-5.
///
/// The half that is NOT allowed is a capability drop. The draft would have replaced the rating
/// section with `>=3/>=4/>=5`, deleting the shipped `rating_min` = 0/1/2 controls and the `unset`
/// row. Every assertion below is written so that a build which removed a row fails it.
///
/// RED at `9a370a1`: `FilterPopoverModel` does not exist there, so this file does not compile.
@Suite("Stats-tab rating alignment (WP16 P3, B1: relabelled and recounted, never narrowed)")
struct InspectorStatsRatingAlignmentTests {

  private func facets() -> Components.Schemas.ImageFacets {
    Components.Schemas.ImageFacets(
      hasMaster: [.init(count: 5, value: "true")],
      mark: [.init(count: 4, value: "pick")],
      rating: [
        .init(count: 9, value: "unset"), .init(count: 2, value: "0"),
        .init(count: 1, value: "1"), .init(count: 1, value: "2"),
        .init(count: 2, value: "3"), .init(count: 5, value: "4"), .init(count: 1, value: "5"),
      ],
      total: 21)
  }

  @Test("A numeric rating row is relabelled with the `>=` it applies, and recounted to match")
  func numericRatingRowsAreRelabelledAndRecounted() {
    let f = facets()
    #expect(FilterPopoverModel.statsRowTitle(.rating, "4") == "≥ 4")
    #expect(
      FilterPopoverModel.statsRowCount(.rating, "4", serverCount: 5, in: f) == 6)
    #expect(FilterPopoverModel.statsRowTitle(.rating, "3") == "≥ 3")
    #expect(
      FilterPopoverModel.statsRowCount(.rating, "3", serverCount: 2, in: f) == 8)
  }

  /// The rows the draft would have deleted. `0`, `1` and `2` are shipped `rating_min` controls and
  /// they survive — relabelled and recounted like every other numeric row, never removed.
  @Test("Every numeric row the server sends survives, including 0, 1 and 2")
  func theLowNumericRowsSurvive() {
    let f = facets()
    #expect(FilterPopoverModel.statsRowTitle(.rating, "0") == "≥ 0")
    #expect(FilterPopoverModel.statsRowTitle(.rating, "1") == "≥ 1")
    #expect(FilterPopoverModel.statsRowTitle(.rating, "2") == "≥ 2")
    // `>= 0` is every RATED photograph — never the `unset` majority, which `rating_min` would not
    // return at all.
    #expect(FilterPopoverModel.statsRowCount(.rating, "0", serverCount: 2, in: f) == 12)
    #expect(FilterPopoverModel.statsRowCount(.rating, "2", serverCount: 1, in: f) == 9)
  }

  /// `unset` clears the dimension rather than filtering by it, so it is the one rating row whose
  /// number is NOT a `>=` count. Relabelling or recounting it would state a filter it never runs.
  @Test("The `unset` row keeps its own label and its own count, untouched")
  func theUnsetRowIsUntouched() {
    let f = facets()
    #expect(FilterPopoverModel.statsRowTitle(.rating, "unset") == "unset")
    #expect(FilterPopoverModel.statsRowCount(.rating, "unset", serverCount: 9, in: f) == 9)
  }

  /// Only the rating dimension is realigned: every other row still shows the server's own count
  /// under the server's own value, because every other dimension's filter is an equality.
  @Test("No other dimension is relabelled or recounted")
  func otherDimensionsAreUnchanged() {
    let f = facets()
    #expect(FilterPopoverModel.statsRowTitle(.mark, "pick") == "pick")
    #expect(FilterPopoverModel.statsRowCount(.mark, "pick", serverCount: 4, in: f) == 4)
    #expect(FilterPopoverModel.statsRowTitle(.hasMaster, "true") == "Yes")
    #expect(FilterPopoverModel.statsRowCount(.hasMaster, "true", serverCount: 5, in: f) == 5)
    #expect(FilterPopoverModel.statsRowTitle(.ext, "jpg") == "jpg")
    #expect(FilterPopoverModel.statsRowCount(.ext, "jpg", serverCount: 7, in: f) == 7)
  }

  // MARK: - The rendered ROW SEQUENCE (diff-gate round 1, B1)

  /// The assertion the per-value helpers could not make. `InspectorView` renders
  /// `FilterPopoverModel.statsRows` verbatim, so this IS the row list on screen: one row per value
  /// the server sent, in the server's own order. An implementation that narrowed the section to
  /// `>= 3 / >= 4 / >= 5` — the draft this phase rejected — fails on the very first line here
  /// while every `statsRowTitle`/`statsRowCount` assertion above stays green.
  @Test("The rendered rating rows are one per server value, in order, with none dropped")
  func theRenderedRatingRowSequenceIsComplete() {
    let rows = FilterPopoverModel.statsRows(.rating, facets(), GridImagesQuery())
    #expect(rows.map(\.value) == ["unset", "0", "1", "2", "3", "4", "5"])
    #expect(rows.map(\.title) == ["unset", "≥ 0", "≥ 1", "≥ 2", "≥ 3", "≥ 4", "≥ 5"])
    // unset keeps its own count; every numeric row is the suffix sum from that value up.
    #expect(rows.map(\.count) == [9, 12, 10, 9, 8, 6, 1])
  }

  /// The same sequence against the wire shape the 2026-09-01 probe actually returned (`unset:29,
  /// 2:1, 3:1, 4:1, 5:1`), where the server sent no `0` or `1` bucket at all: the tab renders what
  /// arrived and invents nothing.
  @Test("Against the live probe's own shape the rendered rows are [unset, ≥2, ≥3, ≥4, ≥5]")
  func theRenderedSequenceFollowsTheLiveProbeShape() {
    let probe = Components.Schemas.ImageFacets(
      rating: [
        .init(count: 29, value: "unset"), .init(count: 1, value: "2"),
        .init(count: 1, value: "3"), .init(count: 1, value: "4"), .init(count: 1, value: "5"),
      ], total: 33)
    let rows = FilterPopoverModel.statsRows(.rating, probe, GridImagesQuery())
    #expect(rows.map(\.title) == ["unset", "≥ 2", "≥ 3", "≥ 4", "≥ 5"])
    #expect(rows.map(\.count) == [29, 4, 3, 2, 1])
  }

  /// Only the rating dimension is realigned, and no dimension loses a row: every other section
  /// still renders one row per server value carrying the server's own number.
  @Test("Every other dimension renders one row per server value, numbers untouched")
  func otherDimensionsRenderEveryServerRowUnchanged() {
    let f = facets()
    let mark = FilterPopoverModel.statsRows(.mark, f, GridImagesQuery())
    #expect(mark.map(\.value) == ["pick"])
    #expect(mark.map(\.title) == ["pick"])
    #expect(mark.map(\.count) == [4])
    let master = FilterPopoverModel.statsRows(.hasMaster, f, GridImagesQuery())
    #expect(master.map(\.title) == ["Yes"])
    #expect(master.map(\.count) == [5])
  }

  /// A dimension the server sent nothing for still renders nothing HERE — the Stats tab's sections
  /// are response-discovered, and only the popover departs from that (B2). Guarding it so the two
  /// surfaces' opposite rules stay deliberate rather than drifting into each other.
  @Test("A dimension the server omitted renders no Stats row at all, unlike the popover")
  func anOmittedDimensionRendersNoStatsRow() {
    let rows = FilterPopoverModel.statsRows(.ext, facets(), GridImagesQuery())
    #expect(rows.isEmpty)
    // Positive control: the same call on a dimension the response DOES carry returns rows, so the
    // emptiness above is the omission and not a broken accessor.
    #expect(!FilterPopoverModel.statsRows(.rating, facets(), GridImagesQuery()).isEmpty)
  }

  /// The rendered row carries its own active state, so the checkmark and the filter cannot drift.
  @Test("The rendered row reports the active value, and only that one")
  func theRenderedRowCarriesActiveState() {
    var query = GridImagesQuery()
    query.ratingMin = 4
    let rows = FilterPopoverModel.statsRows(.rating, facets(), query)
    #expect(rows.filter(\.isActive).map(\.value) == ["4"])
  }

  /// The Stats tab and the popover state the SAME number for the same threshold — they are one
  /// function under two presentations, which is what stops the two surfaces from disagreeing.
  @Test("The Stats row and the popover row agree on the count for the same threshold")
  func theTwoSurfacesAgree() {
    let f = facets()
    let popover = FilterPopoverModel.rows(f, GridImagesQuery())
      .first(where: { $0.field == .rating })?.rows.first(where: { $0.value == "4" })
    let statsCount = FilterPopoverModel.statsRowCount(.rating, "4", serverCount: 5, in: f)
    #expect(popover?.count == statsCount)
    #expect(popover?.title == FilterPopoverModel.statsRowTitle(.rating, "4"))
  }
}
