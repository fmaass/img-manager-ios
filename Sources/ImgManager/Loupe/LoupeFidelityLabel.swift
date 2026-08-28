import Foundation

/// The pixel-provenance label shown in every loupe state (spec: "the fidelity source label
/// always visible"). Pure formatter over `ImageSummary.source_kind` — no SwiftUI, independently
/// unit-testable, mirroring the WEB's own `sourceKindLabel` (`frontend/src/lib/filters.ts`)
/// verbatim so both clients describe the same photograph's pixel provenance identically. The
/// live vocabulary (`app/derivatives/source.py::SourceKind`) has exactly five values; anything
/// else — including a missing/tombstoned image's `nil` — is the SAME visible fallback the web
/// uses, never a blank space.
enum LoupeFidelityLabel {
  static let unavailable = "Unavailable"

  static func label(sourceKind: String?) -> String {
    switch sourceKind {
    case "master": return "Master"
    case "web_preview": return "Web preview"
    case "template_export": return "Template export"
    case "image_raster": return "Original file"
    case "raw_embedded": return "Camera preview"
    default: return unavailable
    }
  }
}
