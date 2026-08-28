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
