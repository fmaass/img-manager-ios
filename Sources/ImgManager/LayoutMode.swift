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
/// Run live on merkur against the household simulators — iPhone 17 Pro and iPad Pro 13"
/// (M5) — via a temporary `.onGeometryChange` diagnostic (removed once this resolver
/// replaced the P0a placeholder; full protocol and raw evidence in
/// `.phase-ledger.md` under WP8-P3):
///
/// | Configuration                              | width  | horizontalSizeClass |
/// |---------------------------------------------|-------:|----------------------|
/// | iPhone 17 Pro, portrait                      |    402 | compact              |
/// | iPhone 17 Pro, landscape                     |    750 | compact              |
/// | iPad Pro 13" (M5), full-screen portrait       |   1032 | regular              |
/// | iPad Pro 13" (M5), full-screen landscape      |   1376 | regular              |
///
/// Per the Navigation model spec, iPad portrait full-screen is `.regular2` and iPad
/// landscape full-screen is `.regular3` — so both confirmed `regular` readings above are
/// real anchors for this resolver's two regular modes.
///
/// ## B2 (Compact -> Regular) — not a separate width constant
///
/// `horizontalSizeClass` is the OS's own compact/regular classification, and every
/// compact reading topped out at width=750 while every regular reading started at
/// width=1032 — the two never disagreed anywhere this session reached. Reimplementing
/// that boundary as a second hand-picked width number would itself be a guess (exactly
/// what fold item 3 forbids); using the trait directly is both more correct and requires
/// no invented number. `horizontalSizeClass` therefore gates Compact vs Regular outright.
///
/// ## B3 (Regular-2 -> Regular-3) — INTERIM, not independently measured
///
/// This is the one number genuinely still open. The fold's own protocol calls for a
/// narrowest-permitted-window reading and an exact-half-display reading to pin this
/// crossing precisely; neither was obtainable in this session's remaining budget after a
/// documented, good-faith attempt (no `cliclick`/buildable `pyobjc` on merkur; a direct
/// AppleScript `set size` and a synthetic `CGEvent` drag on the host Simulator window
/// were both silently rejected — the window did not resize; the iPadOS 26 App Switcher's
/// `resize-grabber` accessibility element was located and confirmed real via XCUITest,
/// but a closed-loop measurement through it was not completed in time). See
/// `.phase-ledger.md` for the full account.
///
/// `regular3Threshold` below is therefore an INTERIM value, bounded strictly between the
/// two confirmed regular readings (1032 Regular-2, 1376 Regular-3) so every
/// **real observed** configuration still resolves correctly — it must never be read as a
/// measurement, and is the named open item for the next session (narrowest-window /
/// half-display pass, then replace this constant and its doc comment together).
enum LayoutResolver {
  /// INTERIM — see the enum doc comment. Bounded between the confirmed Regular-2 reading
  /// (1032, iPad portrait) and the confirmed Regular-3 reading (1376, iPad landscape);
  /// not itself independently measured.
  static let regular3Threshold: CGFloat = 1200

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
