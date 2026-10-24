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
      camera: facetCounts([("SONY ILCE-7RM5", 4), ("FUJIFILM X-T2", 4), ("unset", 4)]),
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
  /// is by construction not "the live result count before applying" the decision asks for.
  ///
  /// The two vectors in play, spelled out so neither is quoted for the other (diff-gate round 1,
  /// B3 — commit a08eec4's message got this wrong):
  ///   - THIS vector, `{unset:9, 2:1, 3:2, 4:5, 5:1}` (the plan's acceptance criterion):
  ///     suffix sums `>= 3 / >= 4 / >= 5` are **8 / 6 / 1**, the exact buckets are **2 / 5 / 1**.
  ///     A build that showed the exact bucket returns 2 / 5 / 1 and fails all three below.
  ///   - The LIVE PROBE of 2026-09-01, `{unset:29, 2:1, 3:1, 4:1, 5:1}`: suffix sums are 3 / 2 / 1
  ///     and the exact buckets are 1 / 1 / 1.
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
    // IMGMGR-544: the uncounted Has-look row is the one row a missing count cannot disable.
    let counted = rows.filter { $0.isCounted }
    let uncounted = rows.filter { !$0.isCounted }
    #expect(counted.allSatisfy({ !$0.isEnabled }))
    #expect(uncounted.map(\.id) == ["hasLook-true"])
    #expect(uncounted.allSatisfy { $0.isEnabled })
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

  /// **The B7 default is spent** (WP21 P2, IMGMGR-376). It rested on a fact about the server —
  /// no `camera` filter parameter and no `camera` facet existed on `/api/images`, `/api/facets`
  /// or `/api/image-groups` — and img-manager v0.20.0 shipped both (IMGMGR-316), re-vendored by
  /// WP21 P1. What survives verbatim is the OTHER half: `camera_preview_only` answers a
  /// different question ("is this image's best source the camera's own preview") and is still not
  /// a stand-in and still not a row, now that a real Camera dimension sits beside it.
  @Test("The Camera row is the server's own values, and camera_preview_only is still not a row")
  func theCameraRowIsServerValuesAndNoStandInWasSubstituted() {
    let live = FilterPopoverModel.rows(liveShapedFacets(), GridImagesQuery())
    let camera = live.first(where: { $0.field == .camera })
    #expect(camera?.title == "Camera")
    // The response's own bodies, in the server's own order and with its own counts — never a
    // declared vocabulary and never derived from a page of images.
    #expect(camera?.rows.map(\.value) == ["SONY ILCE-7RM5", "FUJIFILM X-T2"])
    #expect(camera?.rows.map(\.count) == [4, 4])
    #expect(camera?.rows.allSatisfy({ $0.isEnabled }) == true)
    #expect(row(live, .camera, "SONY ILCE-7RM5")?.markRole == nil)

    // The half of B7 that still holds.
    let fields = FilterPopoverModel.sections.map(\.field)
    #expect(!fields.contains(.cameraPreviewOnly))
    #expect(!live.flatMap(\.rows).contains(where: { $0.field == .cameraPreviewOnly }))
  }

  /// `unset` is the server's name for a NULL column (`_count_by`: "A NULL is reported as 'unset'
  /// rather than dropped"), so it arrives in the `camera` facet for every photograph with no
  /// `exif_camera`. It is not a body one can ASK for — `camera=unset` would filter on a camera
  /// literally named that — so the popover does not offer it as a row, while the Stats tab (which
  /// renders every value the server sent) routes its tap through `toggle`, which clears.
  @Test("The `unset` camera bucket is not offered as a popover row, and its tap clears instead")
  func theUnsetCameraBucketIsNotAFilter() {
    let live = FilterPopoverModel.rows(liveShapedFacets(), GridImagesQuery())
    let camera = live.first(where: { $0.field == .camera })
    #expect(camera?.rows.contains(where: { $0.value == "unset" }) == false)
    // POSITIVE CONTROL, same response: the two real bodies ARE offered, so the absence above is
    // the rule doing its work rather than an empty section.
    #expect(camera?.rows.count == 2)

    var query = GridImagesQuery()
    query.camera = "SONY ILCE-7RM5"
    InspectorFacetField.camera.toggle("unset", in: &query)
    #expect(query.camera == nil)
  }

  /// The stated cap (WP21 P2's pivot, never a silent truncation): the server orders `_count_by`
  /// by count DESC and caps at its own `FACET_VALUE_LIMIT` of 30, so the head of that list is
  /// what a popover rendering an EAGER `VStack` can carry.
  ///
  /// **And the cap SAYS SO** (diff-gate B1). A head with nothing announcing it is a silent
  /// truncation whatever the doc comment claims, so the section ends in one disabled row stating
  /// exactly how many bodies did not fit. The number is derived from `cappedRows`' own output, so
  /// the two cannot drift: with 20 bodies and a limit of 12 it is 8, and 7 once a 21st-ranked
  /// body in force is appended beside the head (`20 - 12 - 1`).
  @Test("A wide Camera response is capped at the stated head, and the ACTIVE body survives it")
  func theCameraSectionIsCappedAtItsStatedHead() {
    let limit = FilterPopoverModel.cameraValueLimit
    let bodies = limit + 8
    let wide = (0..<bodies).map { ("BODY-\(String(format: "%02d", $0))", 100 - $0) }
    let facets = Components.Schemas.ImageFacets(camera: facetCounts(wide), total: 500)

    let head = FilterPopoverModel.rows(facets, GridImagesQuery())
      .first(where: { $0.field == .camera })
    let headValues = head?.rows.filter { $0.value != FilterPopoverModel.overflowValue }
    #expect(headValues?.count == limit)
    #expect(headValues?.first?.value == "BODY-00")
    #expect(headValues?.last?.value == "BODY-\(String(format: "%02d", limit - 1))")

    // The notice, LAST and disabled: it states the eight bodies that did not fit, it is not
    // selectable, and it is not a camera anyone can filter to.
    let notice = head?.rows.last
    #expect(notice?.value == FilterPopoverModel.overflowValue)
    #expect(notice?.accessibilityIdentifier == "filterPopoverRow-camera-more")
    #expect(notice?.title == "+\(bodies - limit) more cameras")
    #expect(notice?.count == bodies - limit)
    #expect(notice?.isEnabled == false)
    #expect(notice?.isActive == false)
    #expect(head?.rows.count == limit + 1)

    // A body OUTSIDE the head that is currently in force stays offered, or the reader could
    // apply a filter from the Stats tab and have no control here that clears it. It is APPENDED,
    // never swapped in over an evicted head row — so the notice's number drops by exactly one.
    var query = GridImagesQuery()
    query.camera = "BODY-\(String(format: "%02d", limit + 5))"
    let withActive = FilterPopoverModel.rows(facets, query)
      .first(where: { $0.field == .camera })
    #expect(withActive?.rows.count == limit + 2)  // head + the active body + the notice
    #expect(withActive?.rows.contains(where: { $0.isActive && $0.value == query.camera }) == true)
    // ...and it carries its REAL count, not a re-offered zero: it came from the response.
    #expect(withActive?.rows.first(where: { $0.isActive })?.count == 100 - (limit + 5))
    // Nothing was evicted to make room for it: the whole head is still there.
    let lastHeadBody = "BODY-\(String(format: "%02d", limit - 1))"
    #expect(withActive?.rows.contains(where: { $0.value == lastHeadBody }) == true)
    let activeNotice = withActive?.rows.last
    #expect(activeNotice?.value == FilterPopoverModel.overflowValue)
    #expect(activeNotice?.count == bodies - limit - 1)
    #expect(activeNotice?.title == "+\(bodies - limit - 1) more cameras")

    // A response inside the cap is untouched, and states NO overflow — the cap is a ceiling, not
    // a fixed size, and a notice that appeared when nothing was hidden would be a lie.
    let narrow = FilterPopoverModel.rows(liveShapedFacets(), GridImagesQuery())
      .first(where: { $0.field == .camera })
    #expect(narrow?.rows.count == 2)
    #expect(narrow?.rows.contains(where: { $0.value == FilterPopoverModel.overflowValue }) == false)

    // The boundary the arithmetic has to survive: head + the one active body covers EVERY body,
    // so there is nothing left to announce and no notice is drawn.
    let exact = (0..<(limit + 1)).map { ("BODY-\(String(format: "%02d", $0))", 100 - $0) }
    var exactQuery = GridImagesQuery()
    exactQuery.camera = "BODY-\(String(format: "%02d", limit))"
    let exactRows = FilterPopoverModel.rows(
      Components.Schemas.ImageFacets(camera: facetCounts(exact), total: 500), exactQuery
    ).first(where: { $0.field == .camera })
    #expect(exactRows?.rows.count == limit + 1)
    #expect(
      exactRows?.rows.contains(where: { $0.value == FilterPopoverModel.overflowValue }) == false)
  }

  @Test("The declared sections are Rating, Mark, Edited, Look, Type, Camera and Keyword, in order")
  func theDeclaredSectionSet() {
    #expect(
      FilterPopoverModel.sections.map(\.field) == [
        .rating, .mark, .hasMaster, .hasLook, .ext, .camera, .keyword,
      ])
    #expect(
      FilterPopoverModel.sections.map(\.title) == [
        "Rating", "Mark", "Edited", "Look", "Type", "Camera", "Keyword",
      ])
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
      // WP21 P2: the two camera bodies the UI leg addresses by identifier, with real counts —
      // and the `unset` bucket the fixture also carries left out of the offered rows.
      let camera = sections.first(where: { $0.field == .camera })
      #expect(camera?.rows.map(\.value) == ["SONY ILCE-7RM5", "FUJIFILM X-T2"])
      #expect(camera?.rows.allSatisfy({ $0.count > 0 && $0.isEnabled }) == true)
      // Two bodies is inside the cap, so the fixture the UI legs read carries NO overflow
      // notice — which is what makes the UI test's absence assertion meaningful.
      #expect(
        camera?.rows.contains(where: { $0.value == FilterPopoverModel.overflowValue }) == false)
      #expect(DebugStubTransport.fixtureFacets().total == 12)
    }
  #endif

  // MARK: - Has look (IMGMGR-544)

  private func hasLookRow(_ query: GridImagesQuery) -> FilterPopoverRow? {
    FilterPopoverModel.rows(nil, query).flatMap(\.rows).first { $0.field == .hasLook }
  }

  @Test("Has look is one uncounted row, reachable without a count, active when set")
  func hasLookRowUncounted() throws {
    let row = try #require(hasLookRow(GridImagesQuery()))
    #expect(row.accessibilityIdentifier == "filterPopoverRow-hasLook-true")
    #expect(row.title == "Has look")
    #expect(!row.isCounted)
    #expect(row.isEnabled)
    #expect(!row.isActive)
    var query = GridImagesQuery()
    query.hasLook = true
    let active = try #require(hasLookRow(query))
    #expect(active.isActive && active.isEnabled)
  }

  @Test("A2: a counted row still disables at zero; Has look toggles and clears")
  func hasLookActivationAndClearing() {
    var query = GridImagesQuery()
    InspectorFacetField.hasLook.toggle("true", in: &query)
    #expect(query.hasLook == true)
    #expect(InspectorFacetFilters.activeCount(query) == 1)
    InspectorFacetField.hasLook.toggle("true", in: &query)
    #expect(query.hasLook == nil)
    query.hasLook = true
    query.mark = "pick"
    InspectorFacetFilters.clear(&query)
    #expect(query.hasLook == nil && query.mark == nil)
    let zeroMaster = FilterPopoverModel.rows(nil, GridImagesQuery()).flatMap(\.rows)
      .first { $0.field == .hasMaster }
    #expect(zeroMaster?.isEnabled == false)
  }

  @Test("The Stats tab renders no Look row")
  func statsTabHasNoLookRow() {
    #expect(!InspectorFacetFilters.statsFields.contains(.hasLook))
    #expect(InspectorFacetFilters.statsFields.count == InspectorFacetField.allCases.count - 1)
    #expect(InspectorFacetFilters.clearableFields.contains(.hasLook))
  }
}
