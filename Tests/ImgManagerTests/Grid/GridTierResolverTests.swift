import CoreGraphics
import Testing

@testable import ImgManager

/// Plan §Phase 4 fold item 4's own Verification line: "Tests: equality, @2x, @3x, a panorama,
/// a display-scale change." Diff-gate round 2, blocker 2: tier choice is a pure function of the
/// tile's ACTUAL rendered size (the real edge justified packing computed), never a nominal
/// row-height guess — so every test here constructs a concrete `CGSize`, the way
/// `JustifiedRowLayout.packWithTierPlan` actually calls this resolver. The panorama/placeholder/
/// reflow-cap cases move to `JustifiedRowLayoutTests` (row-level, since capping is a ROW
/// concern, not this resolver's).
@Suite("Grid tier resolver — post-justification (diff-gate round 2, blocker 2)")
struct GridTierResolverTests {

  @Test("Equality: exactly 400 required pixels is STILL grid tier — 'through exactly 400px'")
  func exactly400IsGridTier() {
    // A tile actually rendered at 400x400pt, displayScale 1 -> requiredPixels == 400 exactly.
    let size = CGSize(width: 400, height: 400)
    #expect(GridTierResolver.requiredPixels(for: size, displayScale: 1.0) == 400)
    #expect(GridTierResolver.chooseTier(for: size, displayScale: 1.0) == .grid)
  }

  @Test("401 required pixels tips to preview tier — one pixel past the ceiling")
  func over400TipsToPreview() {
    let size = CGSize(width: 401, height: 200)
    #expect(GridTierResolver.requiredPixels(for: size, displayScale: 1.0) == 401)
    #expect(GridTierResolver.chooseTier(for: size, displayScale: 1.0) == .preview)
  }

  @Test(
    "@2x: a tile actually rendered at 200x200pt needs 400 required pixels at scale 2 -> still grid")
  func doubleScaleBoundary() {
    let size = CGSize(width: 200, height: 200)
    #expect(GridTierResolver.requiredPixels(for: size, displayScale: 2.0) == 400)
    #expect(GridTierResolver.chooseTier(for: size, displayScale: 2.0) == .grid)
  }

  @Test(
    "@3x: a tile actually rendered at 160x160pt needs 480 required pixels at scale 3 -> tips to preview"
  )
  func tripleScaleTipsToPreview() {
    let size = CGSize(width: 160, height: 160)
    #expect(GridTierResolver.requiredPixels(for: size, displayScale: 3.0) == 480)
    #expect(GridTierResolver.chooseTier(for: size, displayScale: 3.0) == .preview)
  }

  @Test("Display-scale change on the SAME rendered size flips the chosen tier")
  func displayScaleChangeFlipsTier() {
    let size = CGSize(width: 400, height: 400)
    #expect(GridTierResolver.chooseTier(for: size, displayScale: 1.0) == .grid)  // 400 required
    #expect(GridTierResolver.chooseTier(for: size, displayScale: 2.0) == .preview)  // 800 required
  }

  @Test("The long edge governs, not the short one — a 1600x400 rendered panorama at scale 1")
  func longEdgeGoverns() {
    let size = CGSize(width: 1600, height: 400)
    #expect(GridTierResolver.requiredPixels(for: size, displayScale: 1.0) == 1600)
    #expect(GridTierResolver.chooseTier(for: size, displayScale: 1.0) == .preview)
  }

  @Test(
    "The six native row-height steps are exactly 120/160/200/260/320/400 — not the web's continuous domain"
  )
  func sixNativeSteps() {
    let raw = GridRowHeight.allCases.map(\.rawValue).sorted()
    #expect(raw == [120, 160, 200, 260, 320, 400])
  }
}
