import SwiftUI

/// Where the inspector lives at each layout mode, as a value — pulled out for the same reason
/// `LayoutResolver`, `RootRouting` and `SidebarRouting` are: the decision `RootView` actually
/// makes becomes the decision a test can read, rather than a re-implementation of it. The
/// decision stays a `LayoutMode` one; nothing here (or in its call sites) reads a device idiom.
///
/// WP28 P3 (IMGMGR-450) replaces the hand-built topology with the system `.inspector`
/// (`WorkspaceContent`). What is left to decide is only whether the system shows it as a sheet
/// (Compact) or as a trailing inspector column beside the grid (every Regular width) — the
/// system makes that adaptation itself; this value names it so a test can read it.
enum InspectorPresentation: Equatable {
  /// Compact: the system adapts `.inspector` to ONE modal Info/Stats sheet, reached from the
  /// persistent chrome control (fold item 7).
  case sheet
  /// Regular-2 and Regular-3: the system inspector column, trailing the grid inside the split's
  /// detail. Non-modal — the grid stays visible and takes taps beside it — and collapsed at
  /// launch (IMGMGR-390).
  case inspectorColumn

  /// True only where the inspector takes the screen and the grid beneath it stops responding.
  var isModal: Bool { self == .sheet }

  /// EVERY presentation is opened — and closed again — from the SAME persistent chrome control,
  /// the Info button that also carries the active-filter count. Never a second, width-specific
  /// surface. Constant, and still a property: a future width without the control changes this
  /// and nothing else (`ShellToolbarLayout.gridBar`).
  var usesChromeControl: Bool { true }
}

/// The one place the layout mode is turned into an inspector presentation.
enum InspectorPlacement {
  static func presentation(for mode: LayoutMode) -> InspectorPresentation {
    mode == .compact ? .sheet : .inspectorColumn
  }
}

/// The system inspector column's width request (`.inspectorColumnWidth(min:ideal:max:)`). The
/// 360 pt ceiling is the one the retired Regular-2 panel used, so a Regular-2 window keeps a
/// usable grid beside it; the floor keeps the Stats rows readable.
enum InspectorColumnMetrics {
  static let minWidth: CGFloat = 280
  static let idealWidth: CGFloat = 320
  static let maxWidth: CGFloat = 360
}

/// IMGMGR-390: which surface carries the six controls the owner called host chrome — the five
/// grid view-option controls (`gridFilterControl`, `gridSortControl`, `gridGroupControl`,
/// `gridZoomControl`, `gridShortcutHelpControl`) and the inspector's own persistent control
/// (`inspectorChromeButton`).
///
/// A VALUE, and the same "declare the decision, then render the declaration" discipline
/// `GridChromeRows` and `InspectorPlacement` already follow: the answer is stated once, here,
/// and `ShellToolbarLayout` renders the statement.
///
/// **There is deliberately no inspector-bar case.** IMGMGR-338 comment 3731 asked for the six to
/// move to the inspector's own bar while it is expanded. Two gate runs on the retired
/// three-column split (`37ac723`, `b383b5a`) measured that nothing placed in that column took a
/// tap, so the grid's own bar hosts the set in both states. WP28 P3 keeps that placement with the
/// system `.inspector`: the grid's bar is the one surface proven interactive in both states.
enum WorkspaceChromeHost: Equatable, Sendable {
  /// Compact: the five view-option controls ride `GridOptionsRow` under the bar (there is no room
  /// beside Account and Info), and only the inspector's chrome control is a bar item. Unchanged
  /// by this story, and named rather than folded into `gridColumn` so the compact case cannot be
  /// silently swept into a Regular rule.
  case compactOptionsRow
  /// The GRID's own bar, at every Regular width and in BOTH inspector states.
  ///
  /// Collapsed — the launch state since IMGMGR-390 — the grid is the wide pane, so all six are
  /// primary and directly hittable, which is the reach the owner's decision buys. Expanded, the
  /// grid gives the inspector column its width and the OS may fold some of the six into the
  /// overflow chevron — every one stays reachable there (IMGMGR-427 owns the budget gap;
  /// `InspectorSummaryUITests` asserts the reach).
  case gridColumn
}

enum WorkspaceChromePlacement {
  /// Width alone decides. The inspector's state deliberately does NOT move the controls — see
  /// the type's note — so no flag is taken: a host that cannot be expressed cannot be regressed
  /// into by a later call site.
  static func host(for mode: LayoutMode) -> WorkspaceChromeHost {
    mode == .compact ? .compactOptionsRow : .gridColumn
  }

  /// WP29 P1 (IMGMGR-452, plan Decision 2): whether the bottom action bar carries More. At
  /// Regular More is the grid bar's own item (`ShellToolbarControl.more`); at Compact the action
  /// bar is More's only home, at rest and in Select. One width rule for both, so More is never
  /// rendered in two places or in none.
  static func actionBarCarriesMore(for mode: LayoutMode) -> Bool {
    host(for: mode) == .compactOptionsRow
  }
}
