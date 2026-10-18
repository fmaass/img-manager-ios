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

/// R3-12 (IMGMGR-539): the gutter between tiles — 1 pt at the two smallest steps, where a 2-pt
/// gap reads as a grid of lines, and 2 pt above. ONE value serves the in-row gap the packer
/// subtracts AND the vertical gap between rows, so the rendered gaps and the packing arithmetic
/// always agree (a mismatch overflows the row).
enum GridGutter {
  static func spacing(for rowHeight: GridRowHeight) -> CGFloat {
    switch rowHeight {
    case .step120, .step160: return 1
    case .step200, .step260, .step320, .step400: return 2
    }
  }

  /// The inset the grid's scroll content keeps on every side (`GridView.scrollArea`'s padding).
  static let contentInset: CGFloat = 2

  /// The width a justified row is packed into: the measured pane less the inset on BOTH sides.
  /// Packed against the bare pane, a full row overflowed its container by twice the inset, and
  /// the ≥44-pt tile frame let the stack absorb that by narrowing the widest tile's slot — the
  /// photograph then overhung its slot into the gutter (iPhone, 200 step: tiles abutting).
  static func packingWidth(forPane paneWidth: CGFloat) -> CGFloat {
    max(paneWidth - 2 * contentInset, 0)
  }
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

/// What a cell actually DRAWS, once the tombstone question is asked before the proxy question.
///
/// WP12: `ImageSummary.missing` says the original is gone from the store, and an expanded scene's
/// membership deliberately includes tombstoned members ("every member of the scene,
/// capture-ordered, tombstones included"). A cached or still-servable proxy would otherwise draw
/// a photograph that no longer exists — the one thing a culling surface must never do — so the
/// tombstone OUTRANKS the render plan rather than being one more placeholder reason inside it.
/// Kept separate from `TilePlaceholderReason.missing` deliberately: that one means "no proxy has
/// been generated at this tier YET", a preparation state about the derivative, and collapsing the
/// two would make "not rendered yet" and "no longer exists" the same message when only one of
/// them is permanent.
///
/// A pure function, so the rule is testable without a render host: the views below are a switch
/// over its result and carry no second copy of the decision.
enum TilePresentation: Equatable, Sendable {
  case tombstone
  case display(tier: ProxyTier, size: CGSize)
  case placeholder(reason: TilePlaceholderReason)

  static func resolve(missing: Bool?, plan: TileRenderPlan) -> TilePresentation {
    if missing == true { return .tombstone }
    switch plan {
    case .display(let tier, let size): return .display(tier: tier, size: size)
    case .placeholder(let reason): return .placeholder(reason: reason)
    }
  }
}

/// Pure tier-CHOICE (diff-gate blocker 2, round 2): given a tile's ACTUAL rendered size — the
/// real edge that justified packing computed for it, never a nominal row-height guess — decide
/// grid vs preview. Placeholder/never-upscale reflow is a ROW-level concern now
/// (`JustifiedRowLayout.pack`), because capping one tile in isolation breaks the row's uniform
/// height (exactly what the gate's "reflow/cap the ROW not individual tiles" blocker named).
enum GridTierResolver {
  /// R3-15: the CLIENT maximum for the grid tier — "grid is allowed through 800 pixels, then
  /// preview" once the backend serves an 800-px grid edge. It is never assumed: the ceiling a
  /// tile actually uses is `gridCeiling(servedGridEdge:)`, which follows the edge the server
  /// reports for that image's own grid proxy and falls back to `assumedGridEdge`.
  static let gridTierPixelCeiling: Int = 800

  /// The grid edge used whenever the served edge is unknown (grid pending, failed, missing, or
  /// no dimensions) — the pre-R3-15 profile, so the client never assumes 800 before the backend
  /// flip (P19).
  static let assumedGridEdge: Int = 400

  /// The served grid edge for one image: the LONG side of an `ok` grid proxy. The backend renders
  /// each tier with the long side set to exactly the tier edge (portrait and landscape alike) and
  /// refuses a source smaller than the edge, so `max(width, height)` is that edge. Anything but
  /// `ok` is unknown (nil).
  static func servedGridEdge(_ grid: ProxyAvailability) -> Int? {
    guard case .ok(let width, let height) = grid else { return nil }
    let edge = max(width, height)
    return edge > 0 ? edge : nil
  }

  /// The pixel ceiling for one tile: the served edge clamped to
  /// `[assumedGridEdge, gridTierPixelCeiling]`. The lower clamp keeps every served edge at or
  /// below 400 exactly as before; the upper clamp is the client maximum.
  static func gridCeiling(servedGridEdge: Int?) -> Int {
    min(max(servedGridEdge ?? assumedGridEdge, assumedGridEdge), gridTierPixelCeiling)
  }

  /// `size` is the tile's actual rendered size in POINTS (the real edge, post-justification,
  /// pre-any-pixel-availability capping); `displayScale` is the real screen scale.
  static func requiredPixels(for size: CGSize, displayScale: CGFloat) -> Double {
    (Double(max(size.width, size.height)) * Double(displayScale)).rounded(.up)
  }

  /// `servedGridEdge` is the image's own served grid edge (`servedGridEdge(_:)`); nil (the
  /// default) means unknown, which keeps the 400-px rule.
  static func chooseTier(
    for size: CGSize, displayScale: CGFloat, servedGridEdge: Int? = nil
  ) -> ProxyTier {
    let ceiling = gridCeiling(servedGridEdge: servedGridEdge)
    return requiredPixels(for: size, displayScale: displayScale) <= Double(ceiling)
      ? .grid : .preview
  }
}
