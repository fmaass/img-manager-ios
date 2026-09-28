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
/// ## What the P3 measurement passes actually measured
///
/// Three measurement passes, run live on merkur against the household simulators (iPhone
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
/// This closed the B2 boundary below with real device data instead of a guess. Pass 2's
/// apparent B3 bracket was later found to be CIRCULAR (see Pass 3) — its diagnostic
/// computed the sampled `mode` by calling this same resolver's `width >= threshold`
/// decision and logged the resolver's own output back at itself, so the (1190, 1204]
/// figure it produced merely re-observed the placeholder it started from. It is not
/// cited as evidence below.
///
/// **Pass 3 — an independent re-derivation**, built specifically to remove Pass 2's
/// circularity: a `NavigationSplitView` with `columnVisibility` seeded to `.automatic`
/// and never written to again (no resolver call anywhere on the sampled path), with the
/// three panes' actually-RENDERED state read via `.isHittable` on real accessibility
/// identifiers (`paneSidebar`/`paneContent`/`paneDetail`) — an observation of the OS's
/// own collapse behavior, not of this resolver. Two sweeps: a 25-step calibration run
/// and a full 60-step sweep (PASSED, 544.29s, 63 samples spanning the device's entire
/// reachable window-width range, 375–1376pt). Results:
///
/// - **B2 corroborated independently**: the sweep's own rendered-column crossover
///   (sidebar-shown-alone → content+detail-shown) brackets at width **(654, 676]** —
///   consistent with Pass 2's `horizontalSizeClass`-based bracket (664, 667]. Two
///   independent observation methods, one OS trait and one rendered-pixel reading,
///   agree. See the B2 section below.
/// - **No B3 OS-automatic threshold exists**: across all 43 samples from width=672
///   through width=1376 (the device's absolute maximum landscape width), the rendered
///   pane count stayed at exactly 2 (content + detail; sidebar never shown) — it never
///   reached 3 anywhere in the reachable range, including at the physical width
///   ceiling. Under the prominent-detail style the three-column split then used (retired
///   by WP28 P3, IMGMGR-450) with un-forced `.automatic` visibility, this three-column split view simply does not
///   autonomously reveal all three columns based on width. See the B3 section below for
///   what this means for `regular3Threshold`.
///
/// ## B2 (Compact → Regular) — not a separate width constant
///
/// `horizontalSizeClass` is the OS's own compact/regular classification. Pass 2's three
/// independent sweeps bracket the real OS crossing at width **(664, 667]** — tightest
/// bound: last-observed-compact = 664pt (portrait sweep), first-observed-regular = 667pt
/// (landscape re-grow sweep); a separate landscape-shrink pass bracketed the same
/// crossing at (661, 683], consistent but coarser. Pass 3's independently-derived,
/// non-circular rendered-column crossover corroborates this at (654, 676] — a second,
/// different observation method (actual on-screen pane visibility rather than the OS
/// trait) landing on the same real boundary. The trait and both measured width
/// boundaries never disagreed anywhere in ~290 combined samples spanning 375–1376pt.
/// Reimplementing that boundary as a second hand-picked width number would itself be a
/// guess (exactly what fold item 3 forbids) and would need to be kept in sync with the
/// OS's own definition by hand; using the trait directly is both more correct and
/// requires no invented number. `horizontalSizeClass` therefore gates Compact vs Regular
/// outright.
///
/// ## B3 (Regular-2 → Regular-3) — PRODUCT-PINNED inside a measured bracket
///
/// Pass 3 proved there is no OS-automatic width threshold to measure here (see above) —
/// under the then-used prominent-detail style with un-forced `.automatic` visibility, that
/// split view never autonomously shows all three columns at any width, including the device's
/// physical maximum. The app only ever reaches the three-column state because
/// `resolve(width:horizontalSizeClass:)` below EXPLICITLY requests it
/// (`columnVisibility(for: .regular3) == .all`). Where to draw that line is therefore a
/// PRODUCT decision, not an OS fact — but it is not an unconstrained guess: it is pinned
/// inside the empirically-required bracket **(1032, 1376]**, whose both endpoints are
/// real Pass-1 measurements (full-screen portrait → 1032, resolves Regular-2;
/// full-screen landscape → 1376, resolves Regular-3) — the pin cannot legitimately sit
/// outside that bracket without contradicting a real measured anchor. `regular3Threshold`
/// is pinned at 1197, inside the bracket and closer to its portrait end: above the
/// portrait anchor (1032) so a full-screen iPad portrait keeps the deliberate two-pane
/// list+detail reading layout rather than cramming in a third column, and below the
/// landscape anchor (1376) so a full-screen iPad landscape reaches the full
/// sidebar+grid+inspector workspace. No claim is made that 1197 is where an OS boundary
/// actually sits — there isn't one to find.
enum LayoutResolver {
  /// PRODUCT-PINNED (not measured — see the enum doc comment's B3 section). Sits inside
  /// the empirically-required bracket (1032, 1376] — both endpoints real Pass-1
  /// full-screen measurements — chosen so full-screen portrait (1032) stays Regular-2
  /// and full-screen landscape (1376) reaches Regular-3. Pass 3 proved no OS-automatic
  /// threshold exists in this range to measure instead (43 samples, width 672–1376,
  /// rendered pane count constant at 2 throughout).
  static let regular3Threshold: CGFloat = 1197

  static func resolve(width: CGFloat, horizontalSizeClass: UserInterfaceSizeClass?) -> LayoutMode {
    guard horizontalSizeClass == .regular else { return .compact }
    return width >= regular3Threshold ? .regular3 : .regular2
  }

  static func columnVisibility(for mode: LayoutMode) -> NavigationSplitViewVisibility {
    switch mode {
    // WP8 P7 (advisory 1, in scope): Compact used to force `.detailOnly` — the empty grid, with
    // the sidebar (now the queue) unreachable until a shoot was somehow already selected. The
    // queue is the launch surface now, so Compact starts on the sidebar column like Regular-2
    // already does; tapping a queue card still pushes into `detail` (the grid) exactly as
    // tapping a shoot in the old sidebar List always did.
    case .compact: return .doubleColumn
    case .regular2: return .doubleColumn
    case .regular3: return .all
    }
  }
}
