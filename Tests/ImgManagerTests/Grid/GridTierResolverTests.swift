import CoreGraphics
import Testing

@testable import ImgManager

/// Plan §Phase 4 fold item 4's own Verification line: "Tests: equality, @2x, @3x, a panorama,
/// a display-scale change." Every case here is a pure function call — no view, no network.
@Suite("Grid tier resolver (P4 fold item 4)")
struct GridTierResolverTests {

  @Test("Equality: exactly 400 required pixels is STILL grid tier — 'through exactly 400px'")
  func exactly400IsGridTier() {
    // Square tile, row height 400pt, displayScale 1 -> requiredPixels == 400 exactly.
    var queriedTier: ProxyTier?
    let plan = GridTierResolver.plan(
      aspectRatio: 1.0, rowHeight: .step400, displayScale: 1.0
    ) { tier in
      queriedTier = tier
      return .ok(width: 400, height: 400)
    }
    #expect(queriedTier == .grid)
    if case .display(let tier, _) = plan {
      #expect(tier == .grid)
    } else {
      Issue.record("expected .display, got \(plan)")
    }
  }

  @Test("A tile that needs more than 400 required pixels tips to preview tier")
  func over400TipsToPreview() {
    // A 2:1 landscape tile at the tallest step (400pt), displayScale 1 -> width = 800pt,
    // requiredPixels = max(800, 400) * 1 = 800 > 400.
    var queriedTier: ProxyTier?
    let plan = GridTierResolver.plan(
      aspectRatio: 2.0, rowHeight: .step400, displayScale: 1.0
    ) { tier in
      queriedTier = tier
      return .ok(width: 800, height: 800)
    }
    #expect(queriedTier == .preview)
    if case .display(let tier, _) = plan {
      #expect(tier == .preview)
    } else {
      Issue.record("expected .display, got \(plan)")
    }
  }

  @Test("@2x: a 200pt row needs 400 required pixels at scale 2 -> still grid, boundary again")
  func doubleScaleBoundary() {
    var queriedTier: ProxyTier?
    let plan = GridTierResolver.plan(
      aspectRatio: 1.0, rowHeight: .step200, displayScale: 2.0
    ) { tier in
      queriedTier = tier
      return .ok(width: 400, height: 400)
    }
    #expect(queriedTier == .grid)
    if case .display(let tier, let size) = plan {
      #expect(tier == .grid)
      #expect(size == CGSize(width: 200, height: 200))
    } else {
      Issue.record("expected .display, got \(plan)")
    }
  }

  @Test("@3x: a 160pt row needs 480 required pixels at scale 3 -> tips to preview")
  func tripleScaleTipsToPreview() {
    var queriedTier: ProxyTier?
    let plan = GridTierResolver.plan(
      aspectRatio: 1.0, rowHeight: .step160, displayScale: 3.0
    ) { tier in
      queriedTier = tier
      return .ok(width: 1000, height: 1000)
    }
    #expect(queriedTier == .preview)
    if case .display(let tier, _) = plan {
      #expect(tier == .preview)
    } else {
      Issue.record("expected .display, got \(plan)")
    }
  }

  @Test("Display-scale change on the SAME image flips the chosen tier")
  func displayScaleChangeFlipsTier() {
    func tierFor(_ scale: CGFloat) -> ProxyTier? {
      let plan = GridTierResolver.plan(
        aspectRatio: 1.0, rowHeight: .step400, displayScale: scale
      ) { _ in .ok(width: 4000, height: 4000) }
      if case .display(let tier, _) = plan { return tier }
      return nil
    }
    #expect(tierFor(1.0) == .grid)  // 400 required -> grid
    #expect(tierFor(2.0) == .preview)  // 800 required -> preview
  }

  @Test("Panorama: preview's actual pixels fall short -> reflow/cap, never upscale")
  func panoramaReflowsAndCaps() {
    // A 4:1 panorama at the tallest step (400pt) and scale 2 needs width = 1600pt * 2 =
    // 3200px required (long edge). The preview tier only actually has 1600x400 pixels
    // available (long edge 1600) — less than required, so the tile must be capped DOWN,
    // never upscaled to fill 3200.
    let plan = GridTierResolver.plan(
      aspectRatio: 4.0, rowHeight: .step400, displayScale: 2.0
    ) { tier in
      #expect(tier == .preview)
      return .ok(width: 1600, height: 400)
    }
    guard case .display(let tier, let size) = plan else {
      Issue.record("expected .display, got \(plan)")
      return
    }
    #expect(tier == .preview)
    // capScale = 1600 / 3200 = 0.5 -> rendered long edge (width) = 1600pt * 0.5 = 800pt... in
    // POINTS the natural width was 1600pt (400 * 4.0); after a 0.5 cap it is 800pt, height
    // 200pt. Crucially: rendered pixels (width*scale) now equal 800*2=1600 == available, never
    // more.
    #expect(size.width == 800)
    #expect(size.height == 200)
    #expect(Double(size.width) * 2.0 <= 1600.0 + 0.001)
  }

  @Test("An unavailable required tier shows a placeholder, never an undersized fallback")
  func unavailableTierIsPlaceholderNeverFallback() {
    let pending = GridTierResolver.plan(
      aspectRatio: 1.0, rowHeight: .step200, displayScale: 1.0
    ) { _ in .pending }
    #expect(pending == .placeholder(reason: .pending))

    let failed = GridTierResolver.plan(
      aspectRatio: 1.0, rowHeight: .step200, displayScale: 1.0
    ) { _ in .permanentFail }
    #expect(failed == .placeholder(reason: .permanentFail))

    let missing = GridTierResolver.plan(
      aspectRatio: 1.0, rowHeight: .step200, displayScale: 1.0
    ) { _ in .missing }
    #expect(missing == .placeholder(reason: .missing))
  }

  @Test(
    "The six native row-height steps are exactly 120/160/200/260/320/400 — not the web's continuous domain"
  )
  func sixNativeSteps() {
    let raw = GridRowHeight.allCases.map(\.rawValue).sorted()
    #expect(raw == [120, 160, 200, 260, 320, 400])
  }
}
