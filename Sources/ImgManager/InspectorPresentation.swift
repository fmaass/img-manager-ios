import SwiftUI

/// Where the inspector lives at each layout mode, as a value — pulled out for the same reason
/// `LayoutResolver`, `RootRouting` and `SidebarRouting` are: the decision `RootView` actually
/// makes becomes the decision a test can read, rather than a re-implementation of it. The
/// decision stays a `LayoutMode` one; nothing here (or in its call sites) reads a device idiom.
///
/// WP13 P10 (IMGMGR-219) deliberately REVERSES a documented WP8 P4 simplification. Fold item 7
/// pinned "Compact gets Info and Stats as ONE sheet presented from a persistent chrome control",
/// and `RootView` extended that same sheet to Regular-2 "per this pass's simplification". The
/// accepted design round [/link/3220] §2.2 asked instead for a slide-over at that width,
/// mirroring the reference app's side-panel behaviour, and the WP13 gap audit [/link/3282]
/// records the shipped sheet as precisely the side-panel feel that got cut. The reversal is
/// scoped to Regular-2 ONLY — Compact keeps its sheet and Regular-3 keeps its permanent column,
/// both unchanged.
enum InspectorPresentation: Equatable {
  /// Compact: ONE modal Info/Stats sheet, from the persistent chrome control (fold item 7).
  case sheet
  /// Regular-2: a non-modal panel anchored to the trailing edge of the grid pane. The grid stays
  /// visible AND interactive beside it ([/link/3220] §2.2).
  case slideOver
  /// Regular-3: the permanent third column (`RootView.detailColumn`) — no chrome control needed
  /// because the inspector is never absent.
  case permanentColumn

  /// True only where the inspector takes the screen and the grid beneath it stops responding.
  /// This is the property the phase turns over at Regular-2, so this is the property tested.
  var isModal: Bool { self == .sheet }

  /// Both non-permanent presentations are opened — and, for the slide-over, closed again — from
  /// the SAME persistent chrome control, the Info button that also carries the active-filter
  /// count. Never a second, width-specific surface.
  var usesChromeControl: Bool { self != .permanentColumn }
}

/// The one place the layout mode is turned into an inspector presentation.
enum InspectorPlacement {
  static func presentation(for mode: LayoutMode) -> InspectorPresentation {
    switch mode {
    case .compact: return .sheet
    case .regular2: return .slideOver
    case .regular3: return .permanentColumn
    }
  }
}

/// The slide-over's own geometry. Capped in points AND as a fraction of the pane it overlays: a
/// half-width iPad window gets a panel proportional to what is left of the grid instead of one
/// that swallows it, and a very wide pane still stops at a readable column width rather than
/// growing without limit.
enum InspectorSlideOverMetrics {
  static let maxWidth: CGFloat = 360
  static let paneFraction: CGFloat = 0.4

  static func width(inPane paneWidth: CGFloat) -> CGFloat {
    min(maxWidth, max(0, paneWidth) * paneFraction)
  }
}
