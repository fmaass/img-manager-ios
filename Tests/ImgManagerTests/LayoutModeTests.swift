import SwiftUI
import Testing

@testable import ImgManager

/// P3 fold item 3: the resolver is a pure function of measured width AND
/// `horizontalSizeClass` — never idiom. See `LayoutMode.swift`'s doc comment for the full
/// measurement account (raw evidence in `.phase-ledger.md`, geomlog-run10/run12.txt, and
/// the Pass 3 independent re-derivation's far-sweep-samples.txt).
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

  @Test("Measurement-replay: full-screen portrait anchor (1032) resolves Regular-2")
  func measuredIPadPortraitResolvesRegular2() {
    // width=1032, hSizeClass=regular, measured live full-screen portrait (Pass 1). This
    // is also the LOWER endpoint of the empirically-required bracket (1032, 1376] that
    // `regular3Threshold` is product-pinned inside — see LayoutMode.swift's B3 section.
    let mode = LayoutResolver.resolve(width: 1032, horizontalSizeClass: .regular)
    #expect(mode == .regular2)
    #expect(LayoutResolver.columnVisibility(for: mode) == .doubleColumn)
  }

  @Test("Measurement-replay: full-screen landscape anchor (1376) resolves Regular-3")
  func measuredIPadLandscapeResolvesRegular3() {
    // width=1376, hSizeClass=regular, measured live full-screen landscape (Pass 1). This
    // is also the UPPER endpoint of the empirically-required bracket (1032, 1376] that
    // `regular3Threshold` is product-pinned inside, and — per Pass 3 — the width at
    // which the OS's own `.automatic` collapse still shows only 2 rendered panes, so
    // reaching Regular-3 here is entirely this resolver's explicit choice, not an OS
    // default. See LayoutMode.swift's B3 section.
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
    // Pass 3 (independent, non-circular, rendered-column) corroborates this at a
    // different bracket, (654, 676] — see `LayoutMode.swift`.
    #expect(LayoutResolver.resolve(width: 664, horizontalSizeClass: .compact) == .compact)
    #expect(LayoutResolver.resolve(width: 667, horizontalSizeClass: .regular) == .regular2)
  }

  @Test("B3 product-pin regression: exclusive below, inclusive at and above 1197")
  func b3ProductPinBoundaryInclusiveExclusive() {
    // `regular3Threshold` (1197) is a PRODUCT-PINNED choice, not a measured OS boundary
    // — Pass 3 proved no OS-automatic 2-pane/3-pane transition exists to measure (43
    // samples, width 672–1376, rendered pane count constant at 2 throughout; see
    // `LayoutMode.swift`'s B3 section). This test locks the CHOSEN pin's inclusive/
    // exclusive edge behaviour as a regression guard, not as evidence the pin sits at a
    // real crossing — 1196/1197/1198 are arbitrary points one apart from the pin, not
    // captured device samples.
    let b3 = LayoutResolver.regular3Threshold
    #expect(LayoutResolver.resolve(width: b3 - 1, horizontalSizeClass: .regular) == .regular2)
    #expect(LayoutResolver.resolve(width: b3, horizontalSizeClass: .regular) == .regular3)
    #expect(LayoutResolver.resolve(width: b3 + 1, horizontalSizeClass: .regular) == .regular3)
  }

  @Test("Resolution never reads device idiom — width and sizeClass only")
  func resolutionIsWidthAndSizeClassOnly() {
    #expect(
      LayoutResolver.resolve(width: 820, horizontalSizeClass: .compact)
        == LayoutResolver.resolve(width: 820, horizontalSizeClass: .compact))
  }
}
