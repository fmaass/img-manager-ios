import SwiftUI

/// The mark states that carry a colour, and no others (WP16 P1, p3332 decision 5 — "Marks gain
/// the web's colors … Pick green / Dislike red / Edited gold").
///
/// Good, Select's tick and the changed-elsewhere glyph are deliberately absent: Lightroom's
/// read-only Good must never look like this app's writable Pick (the web pins that separation as
/// a value test, `frontend/tests/workspaceTokens.spec.ts`), and the other two are not verdicts.
enum MarkRole: CaseIterable, Sendable {
  case pick
  case dislike
  case edited

  /// The colour set in `Assets.xcassets` that carries this role's hex. Named here and nowhere
  /// else, so no call site can reach a mark colour by typing a string.
  var assetName: String {
    switch self {
    case .pick: return "MarkPick"
    case .dislike: return "MarkDislike"
    case .edited: return "MarkEdited"
    }
  }
}

/// The ONE place a mark colour is named. The values themselves live in `Assets.xcassets` —
/// `#7fe0b2` / `#f0a3aa` / `#c9a44d`, the web's own `mark-pick` / `mark-reject` / `mark-edited`
/// DEFAULT triples (`frontend/tailwind.config.js`, pinned web-side by
/// `frontend/tests/workspaceTokens.spec.ts`), so one visual language spans both surfaces.
///
/// Appearance-INDEPENDENT by decision: every surface but the loupe's mark bar draws its glyph on
/// the same `.black.opacity(0.55)` plate, so the hex is always read against a dark ground whatever
/// appearance the system is in, and a light variant would make those badges worse rather than
/// better. `MarkPaletteTests` asserts both appearances resolve to the same triple, so a variant
/// cannot creep in unnoticed.
enum MarkPalette {
  static func color(for role: MarkRole) -> Color { Color(role.assetName) }
}

extension TileBadgeItem {
  /// Which tile badges take the palette; `nil` means "keep `.white`". The badge priority order,
  /// the two-badge cap and every SF-Symbol name are untouched by decision 5 — colour augments the
  /// shape channel, it never replaces it.
  var markRole: MarkRole? {
    switch self {
    case .pick: return .pick
    case .dislike: return .dislike
    case .edited: return .edited
    case .selected, .good, .changedElsewhere: return nil
    }
  }
}

extension LatchVerb {
  /// The grid action bar's two latch-capable verbs, tinted from the same table the badges read.
  var markRole: MarkRole {
    switch self {
    case .pick: return .pick
    case .dislike: return .dislike
    }
  }
}

extension LoupeMarkPresentation.Control {
  /// The loupe mark bar's two verdict controls (IMGMGR-275), tinted from that same table — so a
  /// Pick cannot be green in the grid and accent-blue in the loupe.
  var markRole: MarkRole {
    switch self {
    case .pick: return .pick
    case .dislike: return .dislike
    }
  }
}
