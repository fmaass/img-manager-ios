import SwiftUI

/// The presentation the root resolves to (plan §Phase 3; [/link/3220] §2.0).
///
/// - `.compact` — one column (iPhone portrait; iPad in a narrow window or Slide Over).
/// - `.regular2` — list + detail (iPad portrait; iPad half-width window; large iPhone
///   landscape — Pro Max only. The household iPhone 17 Pro, non-Max, measured COMPACT in
///   both orientations in the P3 measurement pass — see below — so it never reaches this
///   mode on this household's hardware).
/// - `.regular3` — sidebar + grid + inspector (iPad landscape/full-screen; external
///   display).
enum LayoutMode: Equatable {
  case compact
  case regular2
  case regular3
}

/// A pure function of measured width AND `horizontalSizeClass` — never of device idiom
/// (plan invariant (i), mac-gate-enforced absence grep). Both are real runtime inputs;
/// nothing here is guessed or derived from a device name (P3 fold item 3).
///
/// ## What the P3 measurement pass actually measured
///
/// Two measurement passes, run live on merkur against the household simulators (iPhone
/// 17 Pro and iPad Pro 13" M5). Full raw evidence in `.phase-ledger.md` under WP8-P3.
///
/// **Pass 1 — four full-screen anchors** (`.onGeometryChange` + a temporary diagnostic
/// overlay, removed once this resolver replaced the P0a placeholder):
///
/// | Configuration                              | width  | horizontalSizeClass |
/// |---------------------------------------------|-------:|----------------------|
/// | iPhone 17 Pro, portrait                      |    402 | compact              |
/// | iPhone 17 Pro, landscape                     |    750 | compact              |
/// | iPad Pro 13" (M5), full-screen portrait       |   1032 | regular              |
/// | iPad Pro 13" (M5), full-screen landscape      |   1376 | regular              |
///
/// **Pass 2 — a continuous closed-loop sweep** through the iPadOS 26 windowing system's
/// own per-app resize handle (XCUITest driving the real `resize-grabber` accessibility
/// element springboard exposes for a windowed app; ~230 logged `.onGeometryChange`
/// samples across three independent passes — a portrait grow, a landscape shrink, and a
/// landscape re-grow — covering the full 375–1376pt range with no disagreement anywhere).
/// This closed the two open boundaries below with real device data instead of guesses.
///
/// ## B2 (Compact → Regular) — not a separate width constant
///
/// `horizontalSizeClass` is the OS's own compact/regular classification. Pass 2's three
/// independent sweeps bracket the real OS crossing at width **(664, 667]** — tightest
/// bound: last-observed-compact = 664pt (portrait sweep), first-observed-regular = 667pt
/// (landscape re-grow sweep); a separate landscape-shrink pass bracketed the same
/// crossing at (661, 683], consistent but coarser. The trait and this measured width
/// boundary never disagreed anywhere in ~230 samples spanning 375–1376pt. Reimplementing
/// that boundary as a second hand-picked width number would itself be a guess (exactly
/// what fold item 3 forbids) and would need to be kept in sync with the OS's own
/// definition by hand; using the trait directly is both more correct and requires no
/// invented number. `horizontalSizeClass` therefore gates Compact vs Regular outright.
///
/// ## B3 (Regular-2 → Regular-3) — MEASURED, not interim
///
/// Pass 2's landscape-shrink sweep bracketed the real crossing at width **(1190, 1204]**
/// — last-observed-regular2 = 1190pt, first-observed-regular3 = 1204pt, a 14pt-wide real
/// bracket (down from a 344pt-wide "somewhere between the two full-screen anchors"
/// placeholder). `regular3Threshold` below is pinned at the bracket's midpoint, 1197,
/// with the real ±7pt uncertainty stated here rather than hidden — the true OS crossing
/// was not sampled at single-point precision, but it is now bounded within 14pt by a
/// real device sweep, not guessed within 344pt.
enum LayoutResolver {
  /// MEASURED (Pass 2, landscape-shrink sweep) — see the enum doc comment. The real OS
  /// crossing lies in (1190, 1204]; this is that bracket's midpoint, ±7pt of real
  /// measured uncertainty, never a guess bounded only by the two full-screen anchors.
  static let regular3Threshold: CGFloat = 1197

  static func resolve(width: CGFloat, horizontalSizeClass: UserInterfaceSizeClass?) -> LayoutMode {
    guard horizontalSizeClass == .regular else { return .compact }
    return width >= regular3Threshold ? .regular3 : .regular2
  }

  static func columnVisibility(for mode: LayoutMode) -> NavigationSplitViewVisibility {
    switch mode {
    case .compact: return .detailOnly
    case .regular2: return .doubleColumn
    case .regular3: return .all
    }
  }
}
