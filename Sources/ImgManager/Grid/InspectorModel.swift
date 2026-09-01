import Foundation
import ImgManagerAPI

/// Pure formatting/extraction layer for the inspector (P4 Approach: "the web's Info tab" +
/// "Stats is the inspector's second tab"). No SwiftUI here — every function is a value
/// transform over the generated schema types, independently unit-testable for the pinned
/// structural rules: Lightroom block visibly separated from My marks, no path row, and
/// absence-tolerant rows (a missing field renders "—", never a thrown error or a zero).
///
/// Display timezone mirrors the web's own convention (`frontend/src/lib/dates.ts`:
/// "Everything crossing the wire is UTC; everything a person reads is Europe/Zurich" —
/// ADR-0007). Every wire timestamp is UTC; every one shown to a person is Europe/Zurich,
/// labelled, never silently in the device's local zone.
enum InspectorFormat {
  static let displayTimeZoneIdentifier = "Europe/Zurich"
  static let absent = "—"

  static func timestamp(_ date: Date?) -> String {
    guard let date else { return absent }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.timeZone = TimeZone(identifier: displayTimeZoneIdentifier)
    return "\(formatter.string(from: date)) (\(displayTimeZoneIdentifier))"
  }
}

/// The Info tab's structural fields (P4 Approach: "filename, type, tier / source-kind badge,
/// capture time + zone, camera, lens, ISO · aperture · shutter, dimensions"). Deliberately has
/// NO property for a filesystem path — the "no path row" Do-NOT is structural: there is no
/// field here a view could even bind to render one.
struct InspectorInfo: Equatable {
  var filename: String
  var type: String
  var sourceBadge: String
  var capturedAtDisplay: String
  var dimensions: String
  var exifRows: [InspectorExifRow]

  static func build(from detail: Components.Schemas.ImageDetail) -> InspectorInfo {
    InspectorInfo(
      filename: detail.filename,
      type: detail.ext.uppercased(),
      sourceBadge: InspectorSourceBadge.label(
        sourceKind: detail.sourceKind, sourceTier: detail.sourceTier),
      capturedAtDisplay: InspectorFormat.timestamp(detail.capturedAt),
      dimensions: InspectorDimensions.label(exif: detail.exif),
      exifRows: InspectorExifRow.whitelistedRows(from: detail.exif))
  }
}

/// Camera/lens/exposure block. Whitelist mirrors the web's own (`InspectorPanel.vue`'s
/// `EXIF_FIELDS`, itself sourced from the backend's own whitelist, `app/api/images.py`) — the
/// same fields, not a native re-derivation, so the two clients show the same facts about the
/// same photograph. Every row is absence-tolerant: a key missing from THIS photograph's `exif`
/// renders "—", never a thrown error, never a zero (functional spec: "a field that IS in the
/// contract but missing for THIS photograph... renders an em dash").
struct InspectorExifRow: Equatable, Identifiable {
  var id: String { key }
  var key: String
  var label: String
  var value: String

  static let whitelist: [(key: String, label: String)] = [
    ("Make", "Camera"),
    ("Model", "Model"),
    ("LensModel", "Lens"),
    ("ISO", "ISO"),
    ("FNumber", "Aperture"),
    ("ExposureTime", "Shutter"),
    ("FocalLength", "Focal length"),
    ("Orientation", "Orientation"),
    ("DateTimeOriginal", "EXIF captured"),
  ]

  static func whitelistedRows(from exif: Components.Schemas.ImageDetail.ExifPayload?) -> [Self] {
    whitelist.map { key, label in
      InspectorExifRow(key: key, label: label, value: stringValue(exif, key: key))
    }
  }

  /// `exif`'s additional-properties value is a three-way union (string/int/double) decoded via
  /// `decodeFromSingleValueContainer` (the generated `AdditionalPropertiesPayload`) — exactly
  /// one of `value1`/`value2`/`value3` is populated per entry; this collapses whichever one it
  /// is to a display string, and collapses "the key isn't present at all" to the same absent
  /// marker a present-but-empty value would use, so the row never distinguishes "never asked"
  /// from "asked and got nothing" — both are equally absence.
  static func stringValue(
    _ exif: Components.Schemas.ImageDetail.ExifPayload?, key: String
  ) -> String {
    guard let entry = exif?.additionalProperties[key] else { return InspectorFormat.absent }
    if let s = entry.value1, !s.isEmpty { return s }
    if let i = entry.value2 { return String(i) }
    if let d = entry.value3 { return trimmedNumber(d) }
    return InspectorFormat.absent
  }

  private static func trimmedNumber(_ value: Double) -> String {
    if value == value.rounded() && abs(value) < 1e15 {
      return String(Int64(value))
    }
    return String(value)
  }
}

enum InspectorDimensions {
  /// `ImageWidth`/`ImageHeight` are in the same whitelisted EXIF dict, not a separate field on
  /// `ImageDetail` — this reads them by the same generic accessor rather than inventing a
  /// second dimensions source.
  static func label(exif: Components.Schemas.ImageDetail.ExifPayload?) -> String {
    let width = InspectorExifRow.stringValue(exif, key: "ImageWidth")
    let height = InspectorExifRow.stringValue(exif, key: "ImageHeight")
    guard width != InspectorFormat.absent, height != InspectorFormat.absent else {
      return InspectorFormat.absent
    }
    return "\(width) × \(height)"
  }
}

enum InspectorSourceBadge {
  static func label(sourceKind: String?, sourceTier: String) -> String {
    if let sourceKind, !sourceKind.isEmpty {
      return "\(sourceTier) · \(sourceKind)"
    }
    return sourceTier
  }
}

/// The app's OWN mutable state — a section deliberately separate from `InspectorLightroomBlock`
/// below (binding rule: "the Lightroom block visibly separated from My marks",
/// [/link/2929](/link/2929) via [/link/3206](/link/3206)). Read from the live `ImageSummary`/
/// `ImageDetail` row's `mark`, never merged with `lightroom`.
struct InspectorMarkBlock: Equatable {
  var stateLabel: String
  var tags: [String]

  static func build(from mark: Components.Schemas.MarkView) -> InspectorMarkBlock {
    // `mark.state` is `StatePayload?`, and `StatePayload` itself has a case named `none` — a
    // bare `case .none` would only match `Optional.none` (nil), leaving `.some(.none)`
    // unhandled; both mean "No mark" here, so they are matched explicitly and separately.
    let label: String
    switch mark.state {
    case .some(.pick): label = "Picked"
    case .some(.dislike): label = "Disliked"
    case .some(.none), .none: label = "No mark"
    }
    return InspectorMarkBlock(stateLabel: label, tags: mark.tags ?? [])
  }
}

/// The Stats tab's filter surface as a value type: one case per facet dimension the server
/// returns AND the generated client can actually send back as a filter, with the pure query
/// transforms a touch row needs. It lives here rather than in the view so that "which value is
/// active", "what a second tap does" and "what Clear clears" are unit-testable without SwiftUI —
/// the view only renders what this type decides.
///
/// `sidecar` is deliberately NOT a case, even though `GET /api/facets` returns a `sidecar` list:
/// the vendored contract declares that PARAMETER as `anyOf: [$ref SidecarPresence, null]`, the
/// idiom swift-openapi-generator drops silently (docs/OPENAPI_NORMALIZATION_DEBT.md — the 12
/// `$ref` + null forms the retired normalisation bridge deliberately left alone, "a reference
/// plus null is a different fix"). Neither `ListImagesApiImagesGet.Input.Query` nor
/// `ImageFacetsApiFacetsGet.Input.Query` has the property at all (verified in the probe's own
/// generated output, docs/evidence/p0a-probe/Types-BRIDGED-COMPLETE.swift.gz), which is also why
/// `GridImagesQuery` never had a `sidecar` field. A sidecar row could show a count but never
/// apply one, so it is not offered; closing that needs a backend schema change plus a re-vendor.
enum InspectorFacetField: String, CaseIterable, Identifiable, Sendable {
  case mark
  case rating
  case label
  case keyword
  case tag
  case sourceTier
  case ext
  case good
  case hasMaster
  case cameraPreviewOnly

  var id: String { rawValue }

  var title: String {
    switch self {
    case .mark: return "Mark"
    case .rating: return "Rating"
    case .label: return "Label"
    case .keyword: return "Keyword"
    case .tag: return "Tag"
    case .sourceTier: return "Source"
    case .ext: return "Type"
    case .good: return "Good"
    case .hasMaster: return "Master"
    case .cameraPreviewOnly: return "Camera preview only"
    }
  }

  /// The server's own counts for this dimension, verbatim — never recomputed or re-derived
  /// client-side. A dimension the server sent no values for renders as absence, not as a zero.
  func counts(from facets: Components.Schemas.ImageFacets) -> [Components.Schemas.FacetCount] {
    switch self {
    case .mark: return facets.mark ?? []
    case .rating: return facets.rating ?? []
    case .label: return facets.label ?? []
    case .keyword: return facets.keyword ?? []
    case .tag: return facets.tag ?? []
    case .sourceTier: return facets.sourceTier ?? []
    case .ext: return facets.ext ?? []
    case .good: return facets.good ?? []
    case .hasMaster: return facets.hasMaster ?? []
    case .cameraPreviewOnly: return facets.cameraPreviewOnly ?? []
    }
  }

  /// A row's label: the server's own value everywhere except the boolean dimensions, whose wire
  /// values ("true"/"false") are not something a person reads. Counts are never touched.
  func displayValue(_ value: String) -> String {
    switch self {
    case .good, .hasMaster, .cameraPreviewOnly:
      switch value {
      case "true": return "Yes"
      case "false": return "No"
      default: return value
      }
    case .mark, .rating, .label, .keyword, .tag, .sourceTier, .ext:
      return value
    }
  }

  /// Is `value` the value this dimension is currently filtered to? Drives the row's selected
  /// state AND the second-tap-clears rule below, so both can never disagree.
  func isActive(_ value: String, in query: GridImagesQuery) -> Bool {
    switch self {
    case .mark: return query.mark == value
    case .rating: return query.ratingMin.map { String($0) } == value
    case .label: return query.label == value
    case .keyword: return query.keyword == value
    case .tag: return query.tag == value
    case .sourceTier: return query.sourceTier?.rawValue == value
    case .ext: return query.ext == value
    case .good: return query.good.map { String($0) } == value
    case .hasMaster: return query.hasMaster.map { String($0) } == value
    // The parameter's contract default is `false`, so only `true` is ever a filter — the
    // server offers no "false" row for it either.
    case .cameraPreviewOnly: return query.cameraPreviewOnly == true && value == "true"
    }
  }

  /// The value this dimension is filtered to, if any — the same answer `isActive` gives, read out
  /// rather than tested against a candidate.
  ///
  /// WP16 P3 (IMGMGR-295) needs it for the ONE dimension whose rows are discovered from the
  /// response rather than declared (Type/`ext`, a free-form string in the contract): if the reader
  /// filters to a value and the next response no longer carries it, the popover must re-offer that
  /// value so the filter stays clearable from the surface that applied it. Deriving it here rather
  /// than reading `query.ext` at the call site keeps the rule general and keeps this enum the one
  /// place a dimension's query binding is written down.
  func activeValue(in query: GridImagesQuery) -> String? {
    switch self {
    case .mark: return query.mark
    case .rating: return query.ratingMin.map { String($0) }
    case .label: return query.label
    case .keyword: return query.keyword
    case .tag: return query.tag
    case .sourceTier: return query.sourceTier?.rawValue
    case .ext: return query.ext
    case .good: return query.good.map { String($0) }
    case .hasMaster: return query.hasMaster.map { String($0) }
    case .cameraPreviewOnly: return query.cameraPreviewOnly == true ? "true" : nil
    }
  }

  /// One value per dimension — the web's chip semantics: tapping a different value switches to
  /// it, tapping the value that is already active clears the dimension. A value this client
  /// cannot express as a filter (the rating facet's "unset" row, an unknown tier) clears the
  /// dimension rather than sending a filter the server would refuse or silently ignore.
  func toggle(_ value: String, in query: inout GridImagesQuery) {
    guard !isActive(value, in: query) else {
      clear(in: &query)
      return
    }
    switch self {
    case .mark: query.mark = value
    case .rating: query.ratingMin = Int(value)
    case .label: query.label = value
    case .keyword: query.keyword = value
    case .tag: query.tag = value
    case .sourceTier: query.sourceTier = GridSourceTier(rawValue: value)
    case .ext: query.ext = value
    case .good: query.good = Bool(value)
    case .hasMaster: query.hasMaster = Bool(value)
    case .cameraPreviewOnly: query.cameraPreviewOnly = value == "true" ? true : nil
    }
  }

  func clear(in query: inout GridImagesQuery) {
    switch self {
    case .mark: query.mark = nil
    case .rating: query.ratingMin = nil
    case .label: query.label = nil
    case .keyword: query.keyword = nil
    case .tag: query.tag = nil
    case .sourceTier: query.sourceTier = nil
    case .ext: query.ext = nil
    case .good: query.good = nil
    case .hasMaster: query.hasMaster = nil
    case .cameraPreviewOnly: query.cameraPreviewOnly = nil
    }
  }

  func isSet(in query: GridImagesQuery) -> Bool {
    switch self {
    case .mark: return query.mark != nil
    case .rating: return query.ratingMin != nil
    case .label: return query.label != nil
    case .keyword: return query.keyword != nil
    case .tag: return query.tag != nil
    case .sourceTier: return query.sourceTier != nil
    case .ext: return query.ext != nil
    case .good: return query.good != nil
    case .hasMaster: return query.hasMaster != nil
    case .cameraPreviewOnly: return query.cameraPreviewOnly == true
    }
  }
}

/// The active-filter count and the Clear action, over an EXPLICIT field list — never "every
/// non-nil property of the query", which would sweep up things no facet row ever set.
///
/// Out of the list by design: `folderID` and `sourceTier` are the SHOOT SCOPE, set atomically as
/// one destination by `GridStore.selectShoot`, so clearing the tier alone would publish a folder
/// whose tier no longer matches it, and an archive shoot would badge "1 filter" with nothing
/// filtered; `q`, `tree`, the date bounds and `missing` are surfaces this tab does not render at
/// all (the phone's free-text surface is a separate, still-open question). The Source row stays
/// tappable and self-clearing — only the count and Clear leave the tier alone.
enum InspectorFacetFilters {
  static let clearableFields: [InspectorFacetField] = [
    .mark, .rating, .label, .keyword, .tag, .ext, .good, .hasMaster, .cameraPreviewOnly,
  ]

  static func activeCount(_ query: GridImagesQuery) -> Int {
    clearableFields.filter { $0.isSet(in: query) }.count
  }

  static func clear(_ query: inout GridImagesQuery) {
    for field in clearableFields {
      field.clear(in: &query)
    }
  }

  /// The Info button's own title: on Compact the sheet is the ONLY filter surface, so the button
  /// that opens it is where "filters are on" has to be visible.
  static func infoButtonTitle(activeCount: Int) -> String {
    activeCount > 0 ? "Info · \(activeCount)" : "Info"
  }

  static func infoButtonAccessibilityLabel(activeCount: Int) -> String {
    switch activeCount {
    case 0: return "Info"
    case 1: return "Info, 1 filter active"
    default: return "Info, \(activeCount) filters active"
    }
  }
}

/// Read-only truth from the XMP sidecar — a DIFFERENT struct from `InspectorMarkBlock`, which is
/// the structural half of "visibly separated": there is no shared type or shared section a view
/// could accidentally fold the two into. Absence-tolerant: no sidecar is a stated fact, not an
/// error (`LightroomMeta.sidecarPresent` is first-class for exactly this reason).
struct InspectorLightroomBlock: Equatable {
  var sidecarPresent: Bool
  var rating: Int?
  var label: String?
  var good: Bool?

  static func build(from lightroom: Components.Schemas.LightroomMeta) -> InspectorLightroomBlock {
    InspectorLightroomBlock(
      sidecarPresent: lightroom.sidecarPresent, rating: lightroom.rating, label: lightroom.label,
      good: lightroom.good)
  }
}
