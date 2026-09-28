import SwiftUI

/// WP28 P2 (IMGMGR-449): the six controls the grid's bar carries at Regular — the five grid view
/// options and the inspector's persistent chrome control (IMGMGR-338 calls them host chrome).
/// Each case names the accessibility identifier its control already ships with; none is renamed.
enum ShellToolbarControl: CaseIterable, Hashable, Sendable {
  /// The inspector's Info button. Root-owned: `WorkspaceContent` builds it, because what it
  /// toggles is the inspector topology, which the grid does not know about.
  case info
  /// WP16 P3 (IMGMGR-295), decision 1: filtering reaches the grid's own chrome.
  case filter
  /// WP13 P5b: how the stream is arranged.
  case sort
  case group
  case zoom
  /// Regular's only chrome route into the shortcut help sheet. The other two routes are not
  /// drivable there: ⌘/ never reached the app on the iPad simulator (no attached hardware
  /// keyboard) and a UI test cannot open the system menu bar. WP16 P3 removed it once to free a
  /// slot and put it back, because that cost a shipped control its only Regular route.
  case shortcutHelp

  var accessibilityIdentifier: String {
    switch self {
    case .info: "inspectorChromeButton"
    case .filter: "gridFilterControl"
    case .sort: "gridSortControl"
    case .group: "gridGroupControl"
    case .zoom: "gridZoomControl"
    case .shortcutHelp: "gridShortcutHelpControl"
    }
  }
}

/// WP28 P2 (IMGMGR-449): the grid bar's membership and order, stated once. `ShellToolbarGroup`
/// renders exactly this list as ONE `ToolbarItemGroup(placement: .primaryAction)`, so what the
/// bar carries is a value a unit test reads, not six declarations spread over two files.
///
/// **The order is the shipped rendered order, and it is load-bearing.** The OS folds a crowded bar
/// from its TRAILING end, so declaration order decides which control survives a narrow pane:
///
/// - Info leads. Before P2 it was declared on the toolbar around `GridView` and the five inside
///   it, and the gate probe read the bar as `navBarButtons=["Info", "Filters", ...]`
///   (`Regular3CollapsedChromeUITests`). While the Regular-3 inspector is expanded the grid is a
///   ~209 pt column and three of the six fold; Info is the escape hatch that collapses it, so the
///   fold must never reach it.
/// - Filter comes next (WP16 P3, decision 1): it should not be the first casualty of a fold.
/// - Sort, Group, Zoom and "?" keep their shipped positions after it.
///
/// Info-first is a declared deviation from the brief's listing (Filter … "?", then Info), accepted
/// at the P2 review: it keeps the rendered order the bar shipped with.
enum ShellToolbarLayout {
  /// Every Regular width, both inspector states (`WorkspaceChromeHost.gridColumn`).
  static let regularGridBar: [ShellToolbarControl] = [
    .info, .filter, .sort, .group, .zoom, .shortcutHelp,
  ]

  /// The controls the grid's bar carries at `mode`. At Compact the five view options ride
  /// `GridOptionsRow` under the bar instead, so only Info is a bar item there.
  /// `inspectorUsesChromeControl` is `InspectorPresentation.usesChromeControl`, which is true at
  /// every width today; it stays an input so a presentation without the control drops Info here
  /// and nowhere else.
  static func gridBar(for mode: LayoutMode, inspectorUsesChromeControl: Bool)
    -> [ShellToolbarControl]
  {
    let members: [ShellToolbarControl]
    switch WorkspaceChromePlacement.host(for: mode) {
    case .gridColumn: members = regularGridBar
    case .compactOptionsRow: members = [.info]
    }
    return inspectorUsesChromeControl ? members : members.filter { $0 != .info }
  }
}

/// Renders a `ShellToolbarLayout` list as ONE `ToolbarItemGroup(placement: .primaryAction)`.
/// Whether the system draws the group as one glass cluster is decided by the gate's screenshots,
/// not here: system components only, no background of its own (ADR-N1).
struct ShellToolbarGroup<Info: View>: ToolbarContent {
  let controls: [ShellToolbarControl]
  let store: GridStore
  /// The Info button, built by `WorkspaceContent`.
  let info: Info

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      ForEach(controls, id: \.self) { control in
        switch control {
        case .info: info
        case .filter: GridFilterControl(store: store)
        case .sort: GridSortControl(store: store)
        case .group: GridGroupControl(store: store)
        case .zoom: GridZoomControl(store: store)
        case .shortcutHelp: GridShortcutHelpControl(store: store)
        }
      }
    }
  }
}
