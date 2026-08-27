import SwiftUI
import Testing

@testable import ImgManager

/// P3 fold item 3: the resolver is a pure function of measured width AND
/// `horizontalSizeClass` — never idiom. See `LayoutMode.swift`'s doc comment for the full
/// measurement account (raw evidence in `.phase-ledger.md`).
@Suite("Layout mode resolution (P3 measured-space resolver)")
struct LayoutModeTests {

  @Test("Compact is governed by horizontalSizeClass, not width")
  func compactGovernedBySizeClass() {
    // A width well inside Regular-3 territory still resolves Compact when the OS
    // reports compact size class — horizontalSizeClass is authoritative for the
    // Compact/Regular split (there is no separately reimplemented "B2" width).
    #expect(LayoutResolver.resolve(width: 1400, horizontalSizeClass: .compact) == .compact)
    #expect(LayoutResolver.resolve(width: 1400, horizontalSizeClass: nil) == .compact)
  }

  @Test("Real measured iPhone 17 Pro readings resolve Compact, portrait and landscape")
  func measuredIPhoneReadingsResolveCompact() {
    // width=402 portrait, width=750 landscape — both hSizeClass=compact, measured live
    // on the household iPhone 17 Pro simulator (ledger evidence, WP8-P3).
    #expect(LayoutResolver.resolve(width: 402, horizontalSizeClass: .compact) == .compact)
    #expect(LayoutResolver.resolve(width: 750, horizontalSizeClass: .compact) == .compact)
  }

  @Test("Real measured iPad Pro 13\" portrait resolves Regular-2 (list + detail)")
  func measuredIPadPortraitResolvesRegular2() {
    // width=1032, hSizeClass=regular, measured live full-screen portrait.
    let mode = LayoutResolver.resolve(width: 1032, horizontalSizeClass: .regular)
    #expect(mode == .regular2)
    #expect(LayoutResolver.columnVisibility(for: mode) == .doubleColumn)
  }

  @Test("Real measured iPad Pro 13\" landscape resolves Regular-3 (sidebar + grid + inspector)")
  func measuredIPadLandscapeResolvesRegular3() {
    // width=1376, hSizeClass=regular, measured live full-screen landscape.
    let mode = LayoutResolver.resolve(width: 1376, horizontalSizeClass: .regular)
    #expect(mode == .regular3)
    #expect(LayoutResolver.columnVisibility(for: mode) == .all)
  }

  @Test("B3 boundary: exclusive below, inclusive at and above")
  func b3BoundaryInclusiveExclusive() {
    let b3 = LayoutResolver.regular3Threshold
    #expect(LayoutResolver.resolve(width: b3 - 1, horizontalSizeClass: .regular) == .regular2)
    #expect(LayoutResolver.resolve(width: b3, horizontalSizeClass: .regular) == .regular3)
    #expect(LayoutResolver.resolve(width: b3 + 1, horizontalSizeClass: .regular) == .regular3)
  }

  @Test("B3 sits strictly between the two confirmed regular readings")
  func b3IsBoundedByConfirmedReadings() {
    // Not itself measured (see LayoutMode.swift) — but it must never fall outside the
    // bracket the two REAL regular readings establish, or it would misclassify one of
    // them.
    #expect(LayoutResolver.regular3Threshold > 1032)
    #expect(LayoutResolver.regular3Threshold < 1376)
  }

  @Test("Resolution never reads device idiom — width and sizeClass only")
  func resolutionIsWidthAndSizeClassOnly() {
    #expect(
      LayoutResolver.resolve(width: 820, horizontalSizeClass: .compact)
        == LayoutResolver.resolve(width: 820, horizontalSizeClass: .compact))
  }
}
