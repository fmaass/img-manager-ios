import CoreGraphics

/// P4 fold item 4: the six ROW-HEIGHT steps are a NATIVE decision, pinned one-to-one from the
/// premise gate — NOT parity with the web's continuous 120...600px domain (that continuous
/// range is a stale premise the fold explicitly overrides; do not reintroduce it). This is the
/// REQUESTED/target height justified packing aims for — the row's actual rendered height can
/// differ slightly (justification stretch) or a lot (pixel-availability reflow/cap,
/// `JustifiedRowLayout`), which is exactly why tier selection is never keyed off this enum
/// directly (diff-gate blocker 2) — only off the tile's own actual rendered edge.
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
/// "no entry in `proxies` at all for this tier" collapse into these cases.
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
/// fallback").
enum TilePlaceholderReason: Equatable, Sendable {
  case pending
  case permanentFail
  case missing
}

/// The resolved outcome for one tile: either a tier to fetch and the size to actually render it
/// at (already reflowed/capped at the ROW level by `JustifiedRowLayout` so it never asks for
/// more pixels than the tier can supply), or a placeholder and why.
enum TileRenderPlan: Equatable, Sendable {
  case display(tier: ProxyTier, size: CGSize)
  case placeholder(reason: TilePlaceholderReason)
}

/// Pure tier-CHOICE (diff-gate blocker 2, round 2): given a tile's ACTUAL rendered size — the
/// real edge that justified packing computed for it, never a nominal row-height guess — decide
/// grid vs preview. Placeholder/never-upscale reflow is a ROW-level concern now
/// (`JustifiedRowLayout.pack`), because capping one tile in isolation breaks the row's uniform
/// height (exactly what the gate's "reflow/cap the ROW not individual tiles" blocker named).
enum GridTierResolver {
  /// "Grid is allowed through exactly 400 pixels then preview" — the pixel-domain (not
  /// point-domain) ceiling that decides which tier a required pixel count maps to.
  static let gridTierPixelCeiling: Int = 400

  /// `size` is the tile's actual rendered size in POINTS (the real edge, post-justification,
  /// pre-any-pixel-availability capping); `displayScale` is the real screen scale.
  static func requiredPixels(for size: CGSize, displayScale: CGFloat) -> Double {
    (Double(max(size.width, size.height)) * Double(displayScale)).rounded(.up)
  }

  static func chooseTier(for size: CGSize, displayScale: CGFloat) -> ProxyTier {
    requiredPixels(for: size, displayScale: displayScale) <= Double(gridTierPixelCeiling)
      ? .grid : .preview
  }
}
