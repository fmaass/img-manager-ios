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
  /// Regular-3: the inspector as a real third column (`RootView.detailColumn`). WP16 P2
  /// (IMGMGR-298) made that column COLLAPSIBLE and IMGMGR-390 makes COLLAPSED its launch state —
  /// see `usesChromeControl`. The case name still describes the presentation (a column, not a
  /// sheet or an overlay), which is what every call site branches on; whether the column is on
  /// screen is view state, not a presentation.
  case permanentColumn

  /// True only where the inspector takes the screen and the grid beneath it stops responding.
  /// This is the property WP13 P10 turned over at Regular-2, so this is the property tested.
  var isModal: Bool { self == .sheet }

  /// EVERY presentation is opened — and closed again — from the SAME persistent chrome control,
  /// the Info button that also carries the active-filter count. Never a second, width-specific
  /// surface.
  ///
  /// Constant, and deliberately still a property rather than an inlined `true`. WP16 P2
  /// (IMGMGR-298, design record [/link/3332] decision 4: "both panels collapsible") reversed the
  /// one case that used to answer false — at Regular-3 the inspector was permanent, so there was
  /// nothing for a control to open. It is now hideable there too, so the answer is the same at
  /// all three widths. Keeping the property is what keeps `RootView`'s toolbar condition, the
  /// pinned unit test and this reversal in ONE named place: a future width that genuinely has no
  /// chrome control changes this and nothing else.
  var usesChromeControl: Bool { true }
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

  /// WP16 P2 (IMGMGR-298), the MECHANISM behind decision 4's Regular-3 collapse, learned from
  /// the gate rather than assumed. The first attempt rendered an `EmptyView` in the third column
  /// and the measured result was `actionBarMidX before=104.5 after=104.5` at a 1376 pt window:
  /// the inspector left the screen and the grid gained nothing, because a column of a
  /// `NavigationSplitView` is reserved by the INITIALIZER's arity, not by what is put in it —
  /// the same finding `RootView`'s own 2-column comment already recorded for Regular-2.
  ///
  /// Reclaiming the width therefore means not asking for that column at all: the collapsed state
  /// renders the two-column initializer — the shape Compact and Regular-2 already ship — with the
  /// grid as its detail, and this function says which of ITS panes are wanted.
  ///
  /// **IMGMGR-390 changes that answer from `.detailOnly` to `.doubleColumn`.** WP16 P2 read
  /// [/link/3220] as keeping the sidebar off at Regular-3, so the width the inspector gave up
  /// went entirely to the grid. The owner's decision on IMGMGR-338 (comment 3731) is the
  /// opposite trade and is what the collapse is FOR: "the sidebar/queue stays visible". The two
  /// facts are one function because they are one decision — a default flip alone would have
  /// hidden the queue on every launch, which is the drift the premise gate caught.
  ///
  /// A pure function beside `presentation(for:)`, not a branch inside `RootView`: the launch
  /// path (`applyWidth`) and the toggle path both need the same answer, and a rule computed
  /// twice is a rule that can disagree with itself. `LayoutResolver` is deliberately NOT changed
  /// — it answers for the workspace's layout mode, which the collapse does not alter.
  static func columnVisibility(
    for mode: LayoutMode, regular3InspectorShown: Bool
  ) -> NavigationSplitViewVisibility {
    guard mode == .regular3, !regular3InspectorShown else {
      return LayoutResolver.columnVisibility(for: mode)
    }
    return .doubleColumn
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

/// IMGMGR-390: which surface carries the six controls the owner called host chrome — the five
/// grid view-option controls (`gridFilterControl`, `gridSortControl`, `gridGroupControl`,
/// `gridZoomControl`, `gridShortcutHelpControl`) and the inspector's own persistent control
/// (`inspectorChromeButton`).
///
/// A VALUE, and the same "declare the decision, then render the declaration" discipline
/// `GridChromeRows` and `InspectorPlacement` already follow: the answer is stated once, here,
/// and `GridView.toolbarContent` renders the statement.
///
/// **There is deliberately no inspector-column case, and that is a platform finding rather than
/// a preference.** IMGMGR-338 comment 3731 asked for the six to move to the inspector's own bar
/// while it is expanded. Two gate runs measured that nothing placed in that column can be
/// reached at all: with `.prominentDetail` and `columnVisibility == .all` the OS renders the
/// grid as a column OVERLAYING a non-interactive detail pane (the sidebar is not rendered at all
/// in that state — `LayoutMode.swift`'s Pass 3 measured the same thing from the other side: 43
/// samples, 672–1376 pt, rendered pane count constant at 2, "sidebar never shown"), so
/// every control inside the inspector column reads `exists == true`, `isHittable == false`, and
/// a tap on one computes hit point {-1, -1}. That held identically for bar items (gate
/// `37ac723`) and for a rendered row (gate `b383b5a`): the COLUMN is dimmed, not the bar. The
/// grid's own bar — which stays interactive in both states, as the shipped
/// `InspectorSlideOverUITests` collapse leg proves by tapping it while the inspector is up —
/// therefore hosts the set in both states, and this enum has no case to express the placement
/// that cannot work.
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
  /// grid is the ~209 pt content column and the OS folds three of the six into the overflow
  /// chevron: the deviation main already declares on IMGMGR-293 (see `GridView.toolbarContent`),
  /// left standing here because the alternative placement is unreachable, not merely cramped.
  case gridColumn
}

enum WorkspaceChromePlacement {
  /// Width alone decides. The inspector's state deliberately does NOT move the controls — see
  /// the type's note — so no flag is taken: a host that cannot be expressed cannot be regressed
  /// into by a later call site.
  static func host(for mode: LayoutMode) -> WorkspaceChromeHost {
    mode == .compact ? .compactOptionsRow : .gridColumn
  }
}
