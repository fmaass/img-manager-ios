import Testing

@testable import ImgManager

/// Pure formatter over `source_kind` — mirrors the web's own `sourceKindLabel`
/// (`frontend/src/lib/filters.ts`) verbatim, one test per live vocabulary value plus the
/// nil/unrecognized fallback (spec: "the fidelity source label always visible").
@Suite("LoupeFidelityLabel (P5)")
struct LoupeFidelityLabelTests {
  @Test(
    "Every live SourceKind value (app/derivatives/source.py) maps to the web-matching label",
    arguments: [
      ("master", "Master"),
      ("web_preview", "Web preview"),
      ("template_export", "Template export"),
      ("image_raster", "Original file"),
      ("raw_embedded", "Camera preview"),
    ])
  func knownSourceKinds(kind: String, expected: String) {
    #expect(LoupeFidelityLabel.label(sourceKind: kind) == expected)
  }

  @Test("nil source_kind renders the SAME visible fallback the web uses, never a blank string")
  func nilSourceKindIsVisibleFallback() {
    #expect(LoupeFidelityLabel.label(sourceKind: nil) == "Unavailable")
    #expect(!LoupeFidelityLabel.label(sourceKind: nil).isEmpty)
  }

  @Test(
    "An unrecognized value (schema drift) falls back the same way as nil -- never crashes, never blank"
  )
  func unrecognizedValueFallsBack() {
    #expect(LoupeFidelityLabel.label(sourceKind: "future_kind_not_yet_known") == "Unavailable")
  }
}
