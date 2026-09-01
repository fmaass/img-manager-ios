import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP16 P3 (IMGMGR-295), design record [/link/3332] decision 1: the live-count filter popover.
///
/// Every assertion here is about the PURE model, so "which value is active", "what a second tap
/// does", "what a row's number means" and "which named rows exist at all" are decided once, in a
/// value type, and the view only renders what this decides.
///
/// RED at `9a370a1`: `FilterPopoverModel`, `FilterPopoverSection` and `FilterPopoverRow` are
/// absent from that tree, so this file does not COMPILE against it — the strongest RED there
/// is for a type that is the phase's whole deliverable. It also names `MarkRole`, which WP16
/// P1 ships on `feature/wp16-p1-mark-palette`; the orchestrator merges P1 before P3.
@Suite("Filter popover model (WP16 P3, decision 1: named rows, live counts, always clearable)")
struct FilterPopoverModelTests {

  private func facetCounts(_ pairs: [(String, Int)]) -> [Components.Schemas.FacetCount] {
    pairs.map { .init(count: $0.1, value: $0.0) }
  }

  /// The plan's own live probe shape (2026-09-01, `GET /api/facets`, HTTP 200): EXACT-value
  /// rating buckets, all three mark states including zeros, `has_master` both ways.
  private func liveShapedFacets() -> Components.Schemas.ImageFacets {
    Components.Schemas.ImageFacets(
      ext: facetCounts([("jpg", 9), ("arw", 3)]),
      hasMaster: facetCounts([("true", 5), ("false", 7)]),
      mark: facetCounts([("pick", 4), ("dislike", 0), ("none", 8)]),
      rating: facetCounts([("unset", 4), ("2", 1), ("3", 2), ("4", 3), ("5", 2)]),
      total: 12)
  }

  private func row(
    _ sections: [FilterPopoverSection], _ field: InspectorFacetField, _ value: String
  ) -> FilterPopoverRow? {
    sections.first(where: { $0.field == field })?.rows.first(where: { $0.value == value })
  }

  // MARK: - Decision 3: the >=N rows state the number the `rating_min` filter actually delivers

  /// The acceptance criterion's own vector. The server groups by EXACT `SidecarMeta.rating` while
  /// the filter the row applies (`rating_min`) is a `>=`, so an exact-value count under that row
  /// is by construction not "the live result count before applying" the decision asks for. A build
  /// that showed the exact bucket returns 2 / 5 / 1 here and fails every one of these.
  @Test("ratingAtLeast is a suffix sum over the server's exact-value buckets")
  func ratingAtLeastSumsTheSuffix() {
    let facets = Components.Schemas.ImageFacets(
      rating: facetCounts([("unset", 9), ("2", 1), ("3", 2), ("4", 5), ("5", 1)]), total: 18)
    #expect(FilterPopoverModel.ratingAtLeast(3, in: facets) == 8)
    #expect(FilterPopoverModel.ratingAtLeast(4, in: facets) == 6)
    #expect(FilterPopoverModel.ratingAtLeast(5, in: facets) == 1)
  }

  /// `unset` is not a rating of zero — it is "this photograph has no rating at all", and the
  /// `rating_min` filter these rows apply would never return it. Folding it into `>= 3` would
  /// overstate every row by the size of the unrated majority (29 of 33 on the live probe).
  @Test("ratingAtLeast never counts the `unset` bucket, and tolerates a nil/absent dimension")
  func ratingAtLeastIgnoresUnsetAndAbsence() {
    let facets = Components.Schemas.ImageFacets(
      rating: facetCounts([("unset", 29), ("5", 1)]), total: 30)
    #expect(FilterPopoverModel.ratingAtLeast(0, in: facets) == 1)
    #expect(FilterPopoverModel.ratingAtLeast(3, in: facets) == 1)
    #expect(FilterPopoverModel.ratingAtLeast(3, in: nil) == 0)
    #expect(FilterPopoverModel.ratingAtLeast(3, in: Components.Schemas.ImageFacets(total: 0)) == 0)
  }

  @Test("The rating rows carry the suffix sum, not the exact bucket the server sent")
  func ratingRowsCarryTheSuffixSum() {
    let sections = FilterPopoverModel.rows(liveShapedFacets(), GridImagesQuery())
    #expect(row(sections, .rating, "3")?.count == 7)
    #expect(row(sections, .rating, "4")?.count == 5)
    #expect(row(sections, .rating, "5")?.count == 2)
    #expect(row(sections, .rating, "4")?.title == "≥ 4")
  }

  // MARK: - B2: the row set is FIXED and an absent dimension renders a live zero

  /// Never a spinner in place of the rows, and never an empty list: the popover NAMES its rows, so
  /// a named row that vanishes is the opposite of a live count.
  @Test("Never-fetched facets render the FULL declaration at zero, disabled, never an empty list")
  func nilFacetsRenderTheWholeDeclarationAtZero() {
    let sections = FilterPopoverModel.rows(nil, GridImagesQuery())
    #expect(!sections.isEmpty)
    #expect(sections.map(\.field) == FilterPopoverModel.sections.map(\.field))
    let rows = sections.flatMap(\.rows)
    #expect(!rows.isEmpty)
    #expect(rows.allSatisfy({ $0.count == 0 }))
    #expect(rows.allSatisfy({ !$0.isEnabled }))
    #expect(rows.allSatisfy({ !$0.isActive }))
  }

  /// The acceptance criterion's own scenario: a response that omits `ext` and `has_master`. The
  /// Stats tab is right to render an absent dimension as absence (its sections are discovered from
  /// the response); the popover is not, because these rows are named by the owner's decision.
  @Test("A dimension the response omits still renders its named rows, at 0 and disabled")
  func absentDimensionsStillRenderTheirNamedRows() {
    let facets = Components.Schemas.ImageFacets(
      mark: facetCounts([("pick", 4), ("dislike", 0), ("none", 8)]),
      rating: facetCounts([("4", 3)]), total: 12)
    let sections = FilterPopoverModel.rows(facets, GridImagesQuery())

    let edited = row(sections, .hasMaster, "true")
    #expect(edited != nil)
    #expect(edited?.count == 0)
    #expect(edited?.isEnabled == false)

    let type = sections.first(where: { $0.field == .ext })
    #expect(type != nil)
    #expect(type?.rows.count == 1)
    #expect(type?.rows.first?.count == 0)
    #expect(type?.rows.first?.isEnabled == false)
  }

  /// A 0-count row is disabled UNLESS it is the value currently in force — otherwise applying a
  /// filter that empties the grid would make that same filter unclearable from the surface that
  /// applied it.
  @Test("A zero-count row that IS the active value stays enabled, so a filter is always clearable")
  func aZeroCountActiveRowStaysEnabled() {
    var query = GridImagesQuery()
    query.mark = "dislike"
    let sections = FilterPopoverModel.rows(liveShapedFacets(), query)
    let dislike = row(sections, .mark, "dislike")
    #expect(dislike?.count == 0)
    #expect(dislike?.isActive == true)
    #expect(dislike?.isEnabled == true)

    // ...and the same row without the filter in force is disabled, so the rule above is doing the
    // work rather than "mark rows are always enabled".
    let clean = FilterPopoverModel.rows(liveShapedFacets(), GridImagesQuery())
    let unfiltered = row(clean, .mark, "dislike")
    #expect(unfiltered?.count == 0)
    #expect(unfiltered?.isEnabled == false)
  }

  /// An active value the CURRENT response no longer carries at all (the dimension came back empty
  /// under some other filter) must still be offered, or the reader is stuck with a filter and no
  /// control that clears it.
  @Test("An active value the response no longer carries is still offered, enabled, at 0")
  func anActiveValueMissingFromTheResponseStaysClearable() {
    var query = GridImagesQuery()
    query.ext = "arw"
    let facets = Components.Schemas.ImageFacets(total: 0)
    let sections = FilterPopoverModel.rows(facets, query)
    let type = sections.first(where: { $0.field == .ext })
    #expect(type?.rows.contains(where: { $0.value == "arw" }) == true)
    let arw = row(sections, .ext, "arw")
    #expect(arw?.count == 0)
    #expect(arw?.isActive == true)
    #expect(arw?.isEnabled == true)
  }

  // MARK: - Decision 1: the tri-state mark row, and the row set the owner named

  /// "Unmarked" is `mark=none` — a real filter value the server counts, not an absence. The live
  /// probe returns all three states including zeros, which is what makes three rows renderable.
  @Test("The mark section is exactly three rows including Unmarked, and survives all-zero counts")
  func markSectionIsAlwaysThreeRowsIncludingUnmarked() {
    let allZero = Components.Schemas.ImageFacets(
      mark: facetCounts([("pick", 0), ("dislike", 0), ("none", 0)]), total: 0)
    let sections = FilterPopoverModel.rows(allZero, GridImagesQuery())
    let mark = sections.first(where: { $0.field == .mark })
    #expect(mark?.rows.map(\.value) == ["pick", "none", "dislike"])
    #expect(mark?.rows.map(\.title) == ["Pick", "Unmarked", "Dislike"])
  }

  /// B7, the single default: no `camera` filter parameter and no `camera` facet exist on
  /// `/api/images`, `/api/facets` or `/api/image-groups`, and `camera_preview_only` answers a
  /// different question ("is this image's best source the camera's own preview"). Shipping the
  /// wrong dimension under the owner's word is worse than shipping the rows that are real.
  @Test("No Camera row exists, and no camera_preview_only stand-in was substituted for one")
  func noCameraRowAndNoStandIn() {
    #expect(
      !FilterPopoverModel.sections.contains(where: {
        $0.title.localizedCaseInsensitiveContains("camera")
      }))
    let fields = FilterPopoverModel.sections.map(\.field)
    #expect(!fields.contains(.cameraPreviewOnly))
    let live = FilterPopoverModel.rows(liveShapedFacets(), GridImagesQuery())
    #expect(!live.flatMap(\.rows).contains(where: { $0.field == .cameraPreviewOnly }))
  }

  @Test("The declared sections are Rating, Mark, Edited and Type, in the owner's own order")
  func theDeclaredSectionSet() {
    #expect(FilterPopoverModel.sections.map(\.field) == [.rating, .mark, .hasMaster, .ext])
    #expect(FilterPopoverModel.sections.map(\.title) == ["Rating", "Mark", "Edited", "Type"])
    let live = FilterPopoverModel.rows(liveShapedFacets(), GridImagesQuery())
    #expect(row(live, .hasMaster, "true")?.title == "Edited in Lightroom")
  }

  // MARK: - B3 (decision 5): the popover is the palette's fifth surface

  /// The model names a ROLE, never a colour — the view resolves the colour through
  /// `MarkPalette`, so the popover cannot tint a Pick differently from the tile badge beside it.
  @Test("Pick/Dislike/Edited carry the three palette roles; Unmarked and the rest carry none")
  func markRolesResolveThroughThePalette() {
    let sections = FilterPopoverModel.rows(liveShapedFacets(), GridImagesQuery())
    #expect(row(sections, .mark, "pick")?.markRole == .pick)
    #expect(row(sections, .mark, "dislike")?.markRole == .dislike)
    #expect(row(sections, .hasMaster, "true")?.markRole == .edited)
    #expect(row(sections, .mark, "none")?.markRole == nil)
    #expect(row(sections, .rating, "4")?.markRole == nil)
    #expect(row(sections, .ext, "jpg")?.markRole == nil)
    // Every role the palette declares is reachable from this surface — the fifth-surface claim.
    let roles = Set(sections.flatMap(\.rows).compactMap(\.markRole))
    #expect(roles == Set(MarkRole.allCases))
  }

  // MARK: - The shipped filter lane: one implementation of active/toggle/clear

  @Test("A row reports itself active, and its tap clears the dimension it is already set to")
  func anActiveRowsTapClearsItsDimension() {
    var query = GridImagesQuery()
    query.ratingMin = 4
    let sections = FilterPopoverModel.rows(liveShapedFacets(), query)
    #expect(row(sections, .rating, "4")?.isActive == true)
    #expect(row(sections, .rating, "3")?.isActive == false)

    // The tap the view dispatches is `field.toggle(value:)` — the SAME transform the Stats tab
    // routes through, so the two surfaces cannot disagree about what a second tap does.
    var toggled = query
    InspectorFacetField.rating.toggle("4", in: &toggled)
    #expect(toggled.ratingMin == nil)
  }

  @Test("The Type section takes its values from the response, never from a declared vocabulary")
  func theTypeSectionIsResponseDiscovered() {
    let sections = FilterPopoverModel.rows(liveShapedFacets(), GridImagesQuery())
    let type = sections.first(where: { $0.field == .ext })
    #expect(type?.rows.map(\.value) == ["jpg", "arw"])
    #expect(type?.rows.map(\.count) == [9, 3])
    #expect(type?.rows.allSatisfy({ $0.isEnabled }) == true)
  }

  // MARK: - B9: the DEBUG fixture really does exercise both paths

  #if DEBUG
    /// The fixture expansion is a named work item precisely because the UI legs are only as good
    /// as the response they run against: at `9a370a1` `DebugStubTransport` answers with ONE mark
    /// row (`pick`, 3) and no `rating`, `ext` or `has_master` at all, so the iPad assertions could
    /// not be written. This asserts the MODEL over the shipped fixture — not the fixture against
    /// itself — so a later fixture edit that quietly drops the zero-count row (and with it the
    /// zero-disabled UI coverage) fails here rather than silently making a UI leg vacuous.
    @Test("The DEBUG fixture's facets exercise BOTH the non-zero and the zero-disabled path")
    func theDebugFixtureExercisesBothPaths() {
      let sections = FilterPopoverModel.rows(
        DebugStubTransport.fixtureFacets(), GridImagesQuery())
      let rows = sections.flatMap(\.rows)
      #expect(rows.contains(where: { $0.count > 0 && $0.isEnabled }))
      #expect(rows.contains(where: { $0.count == 0 && !$0.isEnabled }))
      // Every declared dimension carries a real answer, so no UI assertion is reading a zero that
      // only means "the fixture forgot this dimension".
      #expect((row(sections, .rating, "4")?.count ?? 0) > 0)
      #expect((row(sections, .hasMaster, "true")?.count ?? 0) > 0)
      #expect((sections.first(where: { $0.field == .ext })?.rows.count ?? 0) >= 2)
      #expect(DebugStubTransport.fixtureFacets().total == 12)
    }
  #endif
}
