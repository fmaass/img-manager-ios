import SwiftUI
import Testing

@testable import ImgManager

/// P3 fold item 3: the resolver is a pure function of measured width AND
/// `horizontalSizeClass` — never idiom. See `LayoutMode.swift`'s doc comment for the full
/// measurement account (raw evidence in `.phase-ledger.md`, geomlog-run10/run12.txt).
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
    // on the household iPhone 17 Pro simulator (ledger evidence, WP8-P3 Pass 1).
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

  @Test("B2: real captured trait/width pairs bracketing the closed-loop measured crossing")
  func b2RealCapturedReadingsBracketTheCrossing() {
    // Replays actual `.onGeometryChange` samples from the Pass 2 closed-loop sweep
    // (geomlog-run10.txt / geomlog-run12.txt), not hypothetical widths: width=664 was
    // the last-observed-compact sample, width=667 the first-observed-regular sample,
    // in the tightest of three independent sweeps. horizontalSizeClass governs the
    // resolver outright, so both assertions are really about the trait — the widths
    // are the real evidence that the trait crossing and this resolver's behaviour agree.
    #expect(LayoutResolver.resolve(width: 664, horizontalSizeClass: .compact) == .compact)
    #expect(LayoutResolver.resolve(width: 667, horizontalSizeClass: .regular) == .regular2)
  }

  @Test("B3 boundary: exclusive below, inclusive at and above")
  func b3BoundaryInclusiveExclusive() {
    let b3 = LayoutResolver.regular3Threshold
    #expect(LayoutResolver.resolve(width: b3 - 1, horizontalSizeClass: .regular) == .regular2)
    #expect(LayoutResolver.resolve(width: b3, horizontalSizeClass: .regular) == .regular3)
    #expect(LayoutResolver.resolve(width: b3 + 1, horizontalSizeClass: .regular) == .regular3)
  }

  @Test("B3: real captured widths bracketing the closed-loop measured crossing")
  func b3RealCapturedReadingsBracketTheCrossing() {
    // Replays the actual `.onGeometryChange` samples that bracket the real OS crossing
    // (geomlog-run12.txt, landscape-shrink sweep): width=1190 was the
    // last-observed-regular2 sample, width=1204 the first-observed-regular3 sample —
    // a 14pt-wide real bracket, not the previous 344pt-wide "somewhere between the two
    // full-screen anchors" placeholder. `regular3Threshold` (1197) sits inside it.
    #expect(LayoutResolver.resolve(width: 1190, horizontalSizeClass: .regular) == .regular2)
    #expect(LayoutResolver.resolve(width: 1204, horizontalSizeClass: .regular) == .regular3)
    #expect(LayoutResolver.regular3Threshold > 1190)
    #expect(LayoutResolver.regular3Threshold <= 1204)
  }

  @Test("Resolution never reads device idiom — width and sizeClass only")
  func resolutionIsWidthAndSizeClassOnly() {
    #expect(
      LayoutResolver.resolve(width: 820, horizontalSizeClass: .compact)
        == LayoutResolver.resolve(width: 820, horizontalSizeClass: .compact))
  }
}
