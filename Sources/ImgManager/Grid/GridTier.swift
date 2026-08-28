import CoreGraphics

/// P4 fold item 4: the six ROW-HEIGHT steps are a NATIVE decision, pinned one-to-one from the
/// premise gate — NOT parity with the web's continuous 120...600px domain (that continuous
/// range is a stale premise the fold explicitly overrides; do not reintroduce it).
enum GridRowHeight: CGFloat, CaseIterable, Sendable {
  case step120 = 120
  case step160 = 160
  case step200 = 200
  case step260 = 260
  case step320 = 320
  case step400 = 400
}

/// The two proxy tiers this screen ever requests (fold item 2's closed set; no new tier is
/// invented here). Matches the `tier` PATH parameter's two documented values verbatim
/// (`get_proxy_api_images__image_id__proxy__tier__get`'s description: "grid or preview").
enum ProxyTier: String, Sendable, Equatable {
  case grid
  case preview
}

/// What the server reports for one image at one tier, collapsed to the three outcomes this
/// screen actually branches on. `ProxyState.verdict` (`ok`/`pending`/`permanent_fail`) plus
/// "no entry in `proxies` at all for this tier" collapse into these cases — the resolver below
/// never sees, and never needs, the raw `ProxyState`.
enum ProxyAvailability: Equatable, Sendable {
  /// The tier is generated and its real pixel dimensions are known.
  case ok(width: Int, height: Int)
  case pending
  case permanentFail
  /// No `ProxyState` entry exists for this tier on this image at all.
  case missing
}

/// Why a tile shows the preparation/failure placeholder instead of pixels (fold item 4: "an
/// unavailable required tier shows the preparation/failure placeholder, never an undersized
/// fallback" — there is no case here for "fell back to a smaller tier", because that fallback
/// is exactly what the pin forbids).
enum TilePlaceholderReason: Equatable, Sendable {
  case pending
  case permanentFail
  case missing
}

/// The resolved outcome of `GridTierResolver.plan` for one tile at one row-height step: either
/// a tier to fetch and the size to actually render it at (already reflowed/capped so it never
/// asks for more pixels than the tier can supply), or a placeholder and why.
enum TileRenderPlan: Equatable, Sendable {
  case display(tier: ProxyTier, size: CGSize)
  case placeholder(reason: TilePlaceholderReason)
}

/// Pure tier-choice and never-upscale resolver (P4 fold item 4; premise.out Pick Lock section's
/// sibling pin on tiering). Nothing here touches SwiftUI, networking, or the proxy cache — it is
/// a function of four inputs and is exhaustively unit-testable (equality/@2x/@3x/panorama/
/// display-scale-change, per the phase's own Verification line).
enum GridTierResolver {
  /// "Grid is allowed through exactly 400 pixels then preview" — the pixel-domain (not
  /// point-domain) ceiling that decides which tier a required pixel count maps to.
  static let gridTierPixelCeiling: Int = 400

  /// - Parameters:
  ///   - aspectRatio: image width / height. The caller substitutes a fallback (e.g. 1.0) for a
  ///     missing `ImageSummary.aspectRatio` upstream — this function never invents one itself.
  ///   - rowHeight: one of the six pinned steps, in points.
  ///   - displayScale: the real screen scale (`UITraitCollection.displayScale` /
  ///     `EnvironmentValues.displayScale`), e.g. 2 or 3 — never assumed to be 1.
  ///   - availability: the tier's real reported state; queried only for the CHOSEN tier (never
  ///     both), so a placeholder tier's sibling is never probed needlessly.
  static func plan(
    aspectRatio: Double,
    rowHeight: GridRowHeight,
    displayScale: CGFloat,
    availability: (ProxyTier) -> ProxyAvailability
  ) -> TileRenderPlan {
    let height = rowHeight.rawValue
    let width = height * CGFloat(aspectRatio)
    let requiredPixels = (Double(max(width, height)) * Double(displayScale)).rounded(.up)
    let tier: ProxyTier = requiredPixels <= Double(gridTierPixelCeiling) ? .grid : .preview

    switch availability(tier) {
    case .pending:
      return .placeholder(reason: .pending)
    case .permanentFail:
      return .placeholder(reason: .permanentFail)
    case .missing:
      return .placeholder(reason: .missing)
    case .ok(let availWidth, let availHeight):
      let availableLongEdge = Double(max(availWidth, availHeight))
      guard availableLongEdge > 0 else { return .placeholder(reason: .missing) }
      if availableLongEdge >= requiredPixels {
        return .display(tier: tier, size: CGSize(width: width, height: height))
      }
      // Never upscale: reflow/cap the row so the requested size draws exactly what the tier
      // actually has, never more (fold item 4; the panorama case named in the pin).
      let capScale = CGFloat(availableLongEdge / requiredPixels)
      return .display(
        tier: tier,
        size: CGSize(width: width * capScale, height: height * capScale))
    }
  }
}
