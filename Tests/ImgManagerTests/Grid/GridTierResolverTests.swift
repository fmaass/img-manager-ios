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

  // MARK: - R3-15: the ceiling follows the SERVED grid edge

  @Test(
    "Served edge 800: square tiles of 260/320/400pt at 2x (520/640/800px) pick grid",
    arguments: [260.0, 320.0, 400.0])
  func servedEdge800PicksGridThrough400pt(points: Double) {
    let size = CGSize(width: points, height: points)
    #expect(
      GridTierResolver.chooseTier(for: size, displayScale: 2.0, servedGridEdge: 800) == .grid)
  }

  @Test(
    "Served edge 400: the same 260/320/400pt tiles at 2x still pick preview",
    arguments: [260.0, 320.0, 400.0])
  func servedEdge400PicksPreview(points: Double) {
    let size = CGSize(width: points, height: points)
    #expect(
      GridTierResolver.chooseTier(for: size, displayScale: 2.0, servedGridEdge: 400) == .preview)
  }

  @Test("Unknown served edge assumes 400 — the client never assumes 800 before the flip")
  func unknownEdgeAssumes400() {
    let size = CGSize(width: 260, height: 260)
    #expect(GridTierResolver.chooseTier(for: size, displayScale: 2.0) == .preview)
    #expect(
      GridTierResolver.chooseTier(for: size, displayScale: 2.0, servedGridEdge: nil) == .preview)
    #expect(GridTierResolver.gridCeiling(servedGridEdge: nil) == 400)
  }

  @Test("The served edge is the LONG side of an ok grid proxy, portrait or landscape")
  func portraitServedEdgeIsLongEdge() {
    #expect(GridTierResolver.servedGridEdge(.ok(width: 600, height: 800)) == 800)
    #expect(GridTierResolver.servedGridEdge(.ok(width: 533, height: 800)) == 800)
    #expect(GridTierResolver.servedGridEdge(.ok(width: 800, height: 533)) == 800)
    #expect(GridTierResolver.servedGridEdge(.pending) == nil)
    #expect(GridTierResolver.servedGridEdge(.permanentFail) == nil)
    #expect(GridTierResolver.servedGridEdge(.missing) == nil)
    #expect(GridTierResolver.servedGridEdge(.ok(width: 0, height: 0)) == nil)
  }

  @Test("Boundary: 400pt at 2x is grid at served 800; 401pt tips to preview")
  func boundary401pt() {
    let exact = CGSize(width: 400, height: 300)
    let over = CGSize(width: 401, height: 300)
    #expect(
      GridTierResolver.chooseTier(for: exact, displayScale: 2.0, servedGridEdge: 800) == .grid)
    #expect(
      GridTierResolver.chooseTier(for: over, displayScale: 2.0, servedGridEdge: 800) == .preview)
  }

  @Test("The served edge is clamped to the client range 400...800")
  func clamp() {
    #expect(GridTierResolver.gridCeiling(servedGridEdge: 1600) == 800)
    #expect(GridTierResolver.gridCeiling(servedGridEdge: 300) == 400)
    #expect(GridTierResolver.gridCeiling(servedGridEdge: 600) == 600)
    #expect(GridTierResolver.gridTierPixelCeiling == 800)
  }
}
