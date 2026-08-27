import SwiftUI

/// The presentation the root resolves to. P0a scaffolds the mechanism only; P3 replaces
/// this two-case placeholder with the real Compact / Regular-2 / Regular-3 modes (plan
/// §Phase 3), pinned against measured household device widths.
enum LayoutMode: Equatable {
    case compact
    case regular
}

/// A pure function of measured width — never of device idiom. Plan invariant (i), front-
/// loaded into every premise gate: "no idiom branching — any layout decision from
/// [UIDevice's idiom property] is BLOCKING" (Execution Protocol, step 1; the exact
/// property name is deliberately not spelled out here — the mac-gate absence grep treats
/// its own literal appearance as a violation, comments included, the same rule the
/// estate's dependency-layering check applies: "a check a comment can defeat is not a
/// check"). This is the whole mechanism P0a exists to prove; the specific threshold below
/// is a placeholder.
enum LayoutResolver {
    /// Placeholder threshold only — NOT the pinned Compact/Regular-2/Regular-3 boundary.
    /// P3's own known-unknown: "where the Compact/Regular-2/Regular-3 boundaries fall...
    /// measured against real household device widths in this phase and pinned in the
    /// spec — not guessed, and not derived from device names."
    static func resolve(width: CGFloat) -> LayoutMode {
        width >= 700 ? .regular : .compact
    }

    static func columnVisibility(for mode: LayoutMode) -> NavigationSplitViewVisibility {
        switch mode {
        case .regular: return .all
        case .compact: return .detailOnly
        }
    }
}
