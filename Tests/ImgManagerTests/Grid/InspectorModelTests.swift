import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

@Suite("Inspector model (P4 Approach: Info/Stats separation, no path row, absence-tolerant)")
struct InspectorModelTests {

  private func exif(_ pairs: [String: (String?, Int?, Double?)])
    -> Components.Schemas.ImageDetail
    .ExifPayload
  {
    var props: [String: Components.Schemas.ImageDetail.ExifPayload.AdditionalPropertiesPayload] =
      [:]
    for (key, value) in pairs {
      props[key] = .init(value1: value.0, value2: value.1, value3: value.2)
    }
    return .init(additionalProperties: props)
  }

  @Test("Present EXIF fields render their real value, by whichever union slot is populated")
  func presentFieldsRenderRealValues() {
    let e = exif([
      "Make": ("Fujifilm", nil, nil),
      "ISO": (nil, 400, nil),
      "FNumber": (nil, nil, 2.8),
    ])
    #expect(InspectorExifRow.stringValue(e, key: "Make") == "Fujifilm")
    #expect(InspectorExifRow.stringValue(e, key: "ISO") == "400")
    #expect(InspectorExifRow.stringValue(e, key: "FNumber") == "2.8")
  }

  @Test(
    "A key absent from THIS photograph's exif renders the absence marker, never a crash or a zero")
  func absentKeyRendersAbsenceMarker() {
    let e = exif(["Make": ("Fujifilm", nil, nil)])
    #expect(InspectorExifRow.stringValue(e, key: "LensModel") == InspectorFormat.absent)
    #expect(InspectorExifRow.stringValue(e, key: "LensModel") != "0")
  }

  @Test(
    "A nil exif dictionary entirely still renders every whitelisted row as absent, never throws")
  func nilExifStillRendersAllRowsAbsent() {
    let rows = InspectorExifRow.whitelistedRows(from: nil)
    #expect(rows.count == InspectorExifRow.whitelist.count)
    #expect(rows.allSatisfy { $0.value == InspectorFormat.absent })
  }

  @Test("The whitelist mirrors the web's own field set — same facts, same photograph")
  func whitelistMatchesWebFieldSet() {
    let keys = Set(InspectorExifRow.whitelist.map(\.key))
    #expect(
      keys == [
        "Make", "Model", "LensModel", "ISO", "FNumber", "ExposureTime", "FocalLength",
        "Orientation", "DateTimeOriginal",
      ])
  }

  @Test("Dimensions come from the whitelisted ImageWidth/ImageHeight EXIF keys, absence-tolerant")
  func dimensionsFromExifWidthHeight() {
    let present = exif(["ImageWidth": (nil, 6000, nil), "ImageHeight": (nil, 4000, nil)])
    #expect(InspectorDimensions.label(exif: present) == "6000 × 4000")

    let missing = exif(["ImageWidth": (nil, 6000, nil)])  // no height
    #expect(InspectorDimensions.label(exif: missing) == InspectorFormat.absent)

    #expect(InspectorDimensions.label(exif: nil) == InspectorFormat.absent)
  }

  @Test("My marks and Lightroom are STRUCTURALLY separate types — never merged into one block")
  func markAndLightroomAreSeparateTypes() {
    let mark = Components.Schemas.MarkView(revision: "r1", state: .pick, tags: ["favorite"])
    let lightroom = Components.Schemas.LightroomMeta(
      good: true, keywords: ["wedding"], label: "Red", rating: 4, sidecarPresent: true)

    let markBlock = InspectorMarkBlock.build(from: mark)
    let lightroomBlock = InspectorLightroomBlock.build(from: lightroom)

    #expect(markBlock.stateLabel == "Picked")
    #expect(markBlock.tags == ["favorite"])
    #expect(lightroomBlock.rating == 4)
    #expect(lightroomBlock.label == "Red")
    #expect(lightroomBlock.good == true)
    #expect(lightroomBlock.sidecarPresent == true)

    // Structural: the two are DIFFERENT Swift types with no shared storage — there is no
    // single struct here a merge could have collapsed them into.
    #expect(String(describing: type(of: markBlock)) != String(describing: type(of: lightroomBlock)))
  }

  @Test("No Lightroom sidecar renders as absence, not an empty/zeroed rating")
  func noSidecarIsAbsenceNotZero() {
    let lightroom = Components.Schemas.LightroomMeta(sidecarPresent: false)
    let block = InspectorLightroomBlock.build(from: lightroom)
    #expect(block.sidecarPresent == false)
    #expect(block.rating == nil)
  }

  @Test("No mark state (nil) renders as 'No mark', never a crash")
  func nilMarkStateRendersNoMark() {
    let mark = Components.Schemas.MarkView(revision: "r1", state: nil, tags: nil)
    let block = InspectorMarkBlock.build(from: mark)
    #expect(block.stateLabel == "No mark")
    #expect(block.tags.isEmpty)
  }

  // MARK: - Stats-tab facet filters (WP12: the Compact filter surface)

  /// One row per dimension `GET /api/facets` actually returns, with the real wire values the
  /// backend emits (`app/api/images.py`'s facet builder: booleans as "true"/"false", the
  /// sidecar dimension as "present"/"absent", a NULL rating as "unset").
  private func serverFacets() -> Components.Schemas.ImageFacets {
    Components.Schemas.ImageFacets(
      camera: [.init(count: 11, value: "FUJIFILM X-T2"), .init(count: 9, value: "unset")],
      cameraPreviewOnly: [.init(count: 3, value: "true")],
      ext: [.init(count: 9, value: "raf")],
      good: [.init(count: 2, value: "true"), .init(count: 7, value: "false")],
      hasMaster: [.init(count: 4, value: "true"), .init(count: 5, value: "false")],
      keyword: [.init(count: 6, value: "wedding")],
      label: [.init(count: 1, value: "Red")],
      mark: [.init(count: 8, value: "pick"), .init(count: 1, value: "dislike")],
      rating: [.init(count: 5, value: "3"), .init(count: 2, value: "unset")],
      sidecar: [.init(count: 10, value: "present"), .init(count: 4, value: "absent")],
      sourceTier: [.init(count: 12, value: "archive")],
      tag: [.init(count: 2, value: "to-print")],
      total: 20)
  }

  @Test("Every dimension the Stats tab renders is actionable: a tap applies, a second clears")
  func everyRenderedDimensionIsActionable() {
    let facets = serverFacets()
    for field in InspectorFacetField.allCases {
      let counts = field.counts(from: facets)
      #expect(!counts.isEmpty, "\(field.rawValue) renders no row for a populated facet list")
      guard let value = counts.first?.value else { continue }

      var query = GridImagesQuery()
      field.toggle(value, in: &query)
      #expect(field.isActive(value, in: query), "\(field.rawValue) = \(value) did not apply")

      field.toggle(value, in: &query)
      #expect(!field.isActive(value, in: query), "\(field.rawValue) did not clear on a second tap")
    }
  }

  @Test("The active-filter count counts ONLY facet fields — never scope, q, tree, dates, missing")
  func activeCountCountsOnlyFacetFields() {
    var query = GridImagesQuery(folderID: 7)
    query.sourceTier = .archive
    query.q = "beach"
    query.tree = "photo_incoming"
    query.dateFrom = Date(timeIntervalSince1970: 0)
    query.dateTo = Date(timeIntervalSince1970: 86_400)
    query.missing = true
    #expect(InspectorFacetFilters.activeCount(query) == 0)

    query.mark = "pick"
    query.ratingMin = 3
    query.ext = "raf"
    #expect(InspectorFacetFilters.activeCount(query) == 3)
    // WP21 P2 (plan AC 12): a camera body is a FILTER, so it joins the badge's count and Clear
    // takes it — it is not shoot scope the way `folderID`/`sourceTier` are.
    query.camera = "FUJIFILM X-T2"
    #expect(InspectorFacetFilters.activeCount(query) == 4)
    #expect(InspectorFacetFilters.clearableFields.contains(.camera))
  }

  @Test("Clear resets every facet field and NOTHING else — the shoot scope and q survive")
  func clearResetsOnlyFacetFields() {
    var query = GridImagesQuery(folderID: 7)
    query.sourceTier = .archive
    query.q = "beach"
    query.tree = "photo_incoming"
    query.dateFrom = Date(timeIntervalSince1970: 0)
    query.dateTo = Date(timeIntervalSince1970: 86_400)
    query.missing = true
    query.mark = "pick"
    query.ratingMin = 3
    query.label = "Red"
    query.keyword = "wedding"
    query.tag = "to-print"
    query.ext = "raf"
    query.camera = "FUJIFILM X-T2"
    query.good = true
    query.hasMaster = true
    query.cameraPreviewOnly = true

    InspectorFacetFilters.clear(&query)

    #expect(InspectorFacetFilters.activeCount(query) == 0)
    #expect(query.mark == nil)
    #expect(query.ratingMin == nil)
    #expect(query.label == nil)
    #expect(query.keyword == nil)
    #expect(query.tag == nil)
    #expect(query.ext == nil)
    #expect(query.camera == nil)
    #expect(query.good == nil)
    #expect(query.hasMaster == nil)
    #expect(query.cameraPreviewOnly == nil)
    // Untouched: the shoot scope, and every surface no facet row renders.
    #expect(query.folderID == 7)
    #expect(query.sourceTier == .archive)
    #expect(query.q == "beach")
    #expect(query.tree == "photo_incoming")
    #expect(query.dateFrom != nil)
    #expect(query.dateTo != nil)
    #expect(query.missing == true)
  }

  @Test("One value per dimension: a different value switches, the active value clears")
  func oneValuePerDimension() {
    var query = GridImagesQuery()
    InspectorFacetField.mark.toggle("pick", in: &query)
    #expect(query.mark == "pick")
    InspectorFacetField.mark.toggle("dislike", in: &query)
    #expect(query.mark == "dislike")
    #expect(!InspectorFacetField.mark.isActive("pick", in: query))
    InspectorFacetField.mark.toggle("dislike", in: &query)
    #expect(query.mark == nil)
  }

  @Test("Rating rows bind to ratingMin; the server's 'unset' row is not a filterable value")
  func ratingRowsBindToRatingMin() {
    var query = GridImagesQuery()
    InspectorFacetField.rating.toggle("3", in: &query)
    #expect(query.ratingMin == 3)
    #expect(InspectorFacetField.rating.isActive("3", in: query))
    #expect(!InspectorFacetField.rating.isActive("4", in: query))

    InspectorFacetField.rating.toggle("unset", in: &query)
    #expect(query.ratingMin == nil)
    #expect(!InspectorFacetField.rating.isActive("unset", in: query))
  }

  @Test("The boolean dimensions read as Yes/No; every other row shows the server's own value")
  func booleanDimensionsRenderReadably() {
    #expect(InspectorFacetField.good.displayValue("true") == "Yes")
    #expect(InspectorFacetField.good.displayValue("false") == "No")
    #expect(InspectorFacetField.hasMaster.displayValue("false") == "No")
    #expect(InspectorFacetField.cameraPreviewOnly.displayValue("true") == "Yes")
    #expect(InspectorFacetField.keyword.displayValue("wedding") == "wedding")
    #expect(InspectorFacetField.mark.displayValue("pick") == "pick")
    #expect(InspectorFacetField.ext.displayValue("raf") == "raf")
    // Verbatim, camera included: the body's own EXIF name is what a `camera=` request must send.
    #expect(
      InspectorFacetField.camera.displayValue("SONY ILCE-7RM5") == "SONY ILCE-7RM5")
  }

  /// The camera dimension binds to `GridImagesQuery.camera`; the server's `unset` bucket is not a
  /// filterable body, so its tap clears the dimension — the same rule the rating facet's own
  /// `unset` row follows (WP21 P2, IMGMGR-376).
  @Test("Camera rows bind to `camera`; the server's 'unset' bucket is not a filterable value")
  func cameraRowsBindToCamera() {
    var query = GridImagesQuery()
    InspectorFacetField.camera.toggle("SONY ILCE-7RM5", in: &query)
    #expect(query.camera == "SONY ILCE-7RM5")
    #expect(InspectorFacetField.camera.isActive("SONY ILCE-7RM5", in: query))
    #expect(InspectorFacetField.camera.activeValue(in: query) == "SONY ILCE-7RM5")
    #expect(!InspectorFacetField.camera.isActive("FUJIFILM X-T2", in: query))
    #expect(InspectorFacetField.camera.isSet(in: query))

    // A different body switches to it; the value already in force clears the dimension.
    InspectorFacetField.camera.toggle("FUJIFILM X-T2", in: &query)
    #expect(query.camera == "FUJIFILM X-T2")
    InspectorFacetField.camera.toggle("FUJIFILM X-T2", in: &query)
    #expect(query.camera == nil)

    InspectorFacetField.camera.toggle("unset", in: &query)
    #expect(query.camera == nil)
    #expect(!InspectorFacetField.camera.isActive("unset", in: query))
    // ...and from a body already in force, the `unset` row still clears rather than sending it.
    query.camera = "SONY ILCE-7RM5"
    InspectorFacetField.camera.toggle("unset", in: &query)
    #expect(query.camera == nil)
  }

  @Test("The Info button carries the active-filter count, and says so out loud")
  func infoButtonCarriesTheActiveFilterCount() {
    #expect(InspectorFacetFilters.infoButtonTitle(activeCount: 0) == "Info")
    #expect(InspectorFacetFilters.infoButtonTitle(activeCount: 2) == "Info · 2")
    #expect(InspectorFacetFilters.infoButtonAccessibilityLabel(activeCount: 0) == "Info")
    #expect(
      InspectorFacetFilters.infoButtonAccessibilityLabel(activeCount: 1) == "Info, 1 filter active")
    #expect(
      InspectorFacetFilters.infoButtonAccessibilityLabel(activeCount: 3)
        == "Info, 3 filters active")
  }

  @Test("The tier is shoot SCOPE: its row toggles, but Clear and the count leave it alone")
  func sourceTierIsShootScopeNotAFilter() {
    var query = GridImagesQuery(folderID: 7)
    InspectorFacetField.sourceTier.toggle("archive", in: &query)
    #expect(query.sourceTier == .archive)
    #expect(InspectorFacetField.sourceTier.isActive("archive", in: query))
    // `selectShoot` sets folderID and sourceTier atomically as ONE destination, so the tier is
    // scope, not a filter: clearing it alone would publish a folder whose tier no longer
    // matches, and an archive shoot would badge "1 filter" with nothing filtered.
    #expect(InspectorFacetFilters.activeCount(query) == 0)
    InspectorFacetFilters.clear(&query)
    #expect(query.sourceTier == .archive)
    #expect(query.folderID == 7)
    // The row itself stays self-clearing — a second tap on the active tier still clears it.
    InspectorFacetField.sourceTier.toggle("archive", in: &query)
    #expect(query.sourceTier == nil)
  }

  @Test("The sidecar facet is not offered as a row — the generated client cannot carry it")
  func sidecarIsNotOfferedAsAFilterRow() {
    // Contract truth, not a preference: `sidecar` is declared
    // `anyOf: [$ref SidecarPresence, {"type": "null"}]`, the idiom swift-openapi-generator
    // drops silently (docs/OPENAPI_NORMALIZATION_DEBT.md — the 12 `$ref` + null forms the
    // retired bridge deliberately left alone). Neither images' nor facets' generated
    // `Input.Query` has the parameter at all (docs/evidence/p0a-probe/
    // Types-BRIDGED-COMPLETE.swift.gz), so a sidecar row could show its count but never apply
    // one — and a row that cannot filter is not offered.
    #expect(!InspectorFacetField.allCases.contains { $0.rawValue.contains("sidecar") })
    #expect(serverFacets().sidecar?.isEmpty == false)  // positive control: the server DOES send it
    // Ten until WP21 P2 added `.camera` (IMGMGR-376), the one dimension img-manager v0.20.0
    // made both countable and sendable.
    #expect(InspectorFacetField.allCases.count == 11)
    #expect(InspectorFacetField.allCases.contains(.camera))
  }

  @Test("InspectorInfo has NO property a path could bind to — structural 'no path row'")
  func noPathRowIsStructural() {
    // Reflect the actual field list of the built value and assert none of the labels even
    // suggest a filesystem path — the stronger guarantee is that `InspectorInfo`'s own
    // declaration (source of truth) simply has no such property to reflect in the first
    // place; this mirrors that fact at runtime over a real instance.
    let detail = Components.Schemas.ImageDetail(
      ext: "jpg", fileSize: 4_096, filename: "a.jpg", folderId: 1, id: 1,
      lightroom: .init(sidecarPresent: false), mark: .init(revision: "r1"),
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
    let info = InspectorInfo.build(from: detail)
    let mirror = Mirror(reflecting: info)
    let labels = mirror.children.compactMap(\.label)
    #expect(!labels.contains { $0.lowercased().contains("path") })
  }
}
