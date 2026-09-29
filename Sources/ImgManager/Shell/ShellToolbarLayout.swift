import SwiftUI

/// WP28 P2 (IMGMGR-449): the controls the grid's chrome carries — the grid view options, the
/// inspector's persistent chrome control (IMGMGR-338 calls them host chrome) and, since WP29 P1
/// (IMGMGR-452), the system search, Select and More. Each case names the accessibility
/// identifier its control already ships with; none is renamed.
enum ShellToolbarControl: CaseIterable, Hashable, Sendable {
  /// The inspector's Info button. Root-owned: `WorkspaceContent` builds it, because what it
  /// toggles is the inspector topology, which the grid does not know about.
  case info
  /// WP29 P1: the SYSTEM search item (`DefaultToolbarItem(kind: .search)`), placed by the app
  /// among its own items. The search itself is unchanged: WP28's folder-tree search.
  case search
  /// WP29 P1: Select, moved out of the More menu onto the bar. Same identifier, same action.
  case select
  /// WP16 P3 (IMGMGR-295), decision 1: filtering reaches the grid's own chrome.
  case filter
  /// WP13 P5b: how the stream is arranged. WP29 P1: the three hold Arrange's slot until P2.
  case sort
  case group
  case zoom
  /// The shortcut help sheet's chrome route. WP29 P1 (plan Decision 1) takes it off the REGULAR
  /// bar — its homes there are ⌘/ and the menu bar's "Keyboard Shortcuts" — and keeps it on
  /// Compact's options row, because an iPhone has no menu bar.
  case shortcutHelp
  /// WP29 P1: the grid's More menu. At Regular it moved from the bottom action bar to the bar;
  /// at Compact it stays on the action bar (`WorkspaceChromePlacement.actionBarCarriesMore`).
  case more

  /// Nil for the system search item, which carries no identifier of the app's.
  var accessibilityIdentifier: String? {
    switch self {
    case .info: "inspectorChromeButton"
    case .search: nil
    case .select: "gridSelectCommand"
    case .filter: "gridFilterControl"
    case .sort: "gridSortControl"
    case .group: "gridGroupControl"
    case .zoom: "gridZoomControl"
    case .shortcutHelp: "gridShortcutHelpControl"
    case .more: "gridMoreMenu"
    }
  }
}

/// WP28 P2 (IMGMGR-449): the grid bar's membership and order, stated once. `ShellToolbarGroup`
/// renders exactly this list, so what the bar carries is a value a unit test reads, not
/// declarations spread over two files.
///
/// **The order is load-bearing.** The OS folds a crowded bar from its TRAILING end, so
/// declaration order decides which control survives a narrow pane:
///
/// - Info leads. While the Regular-3 inspector is expanded the grid is a narrow column and the
///   fold takes several items; Info is the escape hatch that collapses it, so the fold must never
///   reach it (IMGMGR-390, `Regular3CollapsedChromeUITests`).
/// - WP29 P1 (IMGMGR-452): then the spec's trailing group, in p4128's order — Search · Select ·
///   Filter · Arrange · More. Sort · Group · Zoom hold Arrange's slot until P2 replaces them.
enum ShellToolbarLayout {
  /// Every Regular width, both inspector states (`WorkspaceChromeHost.gridColumn`).
  static let regularGridBar: [ShellToolbarControl] = [
    .info, .search, .select, .filter, .sort, .group, .zoom, .more,
  ]

  /// WP29 P1: Compact's navigation bar — Info, and Select beside it. Search is the Search tab
  /// there and More stays on the bottom action bar.
  static let compactGridBar: [ShellToolbarControl] = [.info, .select]

  /// Compact's persistent options row (`GridOptionsRow`), in its shipped order: the three
  /// value-carrying controls, the funnel, and "?" at the trailing end.
  static let compactOptionsRow: [ShellToolbarControl] = [
    .sort, .group, .zoom, .filter, .shortcutHelp,
  ]

  /// The controls the grid's bar carries at `mode`. `inspectorUsesChromeControl` is
  /// `InspectorPresentation.usesChromeControl`, which is true at every width today; it stays an
  /// input so a presentation without the control drops Info here and nowhere else.
  static func gridBar(for mode: LayoutMode, inspectorUsesChromeControl: Bool)
    -> [ShellToolbarControl]
  {
    let members: [ShellToolbarControl]
    switch WorkspaceChromePlacement.host(for: mode) {
    case .gridColumn: members = regularGridBar
    case .compactOptionsRow: members = compactGridBar
    }
    return inspectorUsesChromeControl ? members : members.filter { $0 != .info }
  }
}

/// WP29 P1 (IMGMGR-452): a `ShellToolbarLayout` list cut where the toolbar renders it. Two
/// members are toolbar items of their own and never a view inside a group: the system search
/// (`DefaultToolbarItem`, toolbar content rather than a view) and Filter (its own `ToolbarItem`,
/// so the count it carries belongs to that item alone — plan Phase 1, "Filter: its own
/// `ToolbarItem`"). Everything else rides the group runs between them. Pure, so a unit test pins
/// that the rendered order IS the declared order (`flattened == controls`) at every width.
struct ShellToolbarRuns: Equatable, Sendable {
  /// The app's controls before the search item — Info at every width.
  private(set) var leading: [ShellToolbarControl] = []
  private(set) var search = false
  /// Between the search item and Filter's item — Select at Regular.
  private(set) var middle: [ShellToolbarControl] = []
  private(set) var filter = false
  /// After Filter's item — Arrange's slot and More at Regular.
  private(set) var trailing: [ShellToolbarControl] = []

  init(_ controls: [ShellToolbarControl]) {
    // 0: before search, 1: after search, 2: after Filter. A Filter declared AHEAD of the search
    // would be rendered after it; `flattened` then differs from the declaration, which is what
    // the unit test catches.
    var stage = 0
    for control in controls {
      switch control {
      case .search:
        search = true
        stage = max(stage, 1)
      case .filter:
        filter = true
        stage = 2
      default:
        switch stage {
        case 0: leading.append(control)
        case 1: middle.append(control)
        default: trailing.append(control)
        }
      }
    }
  }

  /// The order the toolbar renders: leading group, search item, middle group, Filter's item,
  /// trailing group.
  var flattened: [ShellToolbarControl] {
    leading + (search ? [.search] : []) + middle + (filter ? [.filter] : []) + trailing
  }
}

/// Renders a `ShellToolbarLayout` list as `ShellToolbarRuns` cuts it: the app's runs are
/// `ToolbarItemGroup`s, the system search a `DefaultToolbarItem` and Filter a `ToolbarItem` —
/// the declared order either way. Whether the system draws them as one glass cluster is decided
/// by the gate's screenshots, not here: system components only, no background of its own
/// (ADR-N1).
struct ShellToolbarGroup<Info: View>: ToolbarContent {
  let controls: [ShellToolbarControl]
  let store: GridStore
  /// The Info button, built by `WorkspaceContent`.
  let info: Info
  /// WP29 P1: handed to the bar's More, whose "Open in New Window" row needs it.
  let openShootWindow: ShootWindowOpener

  private var runs: ShellToolbarRuns { ShellToolbarRuns(controls) }

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      ForEach(runs.leading, id: \.self) { control in
        rendered(control)
      }
    }
    if runs.search {
      DefaultToolbarItem(kind: .search, placement: .primaryAction)
    }
    if !runs.middle.isEmpty {
      ToolbarItemGroup(placement: .primaryAction) {
        ForEach(runs.middle, id: \.self) { control in
          rendered(control)
        }
      }
    }
    if runs.filter {
      ToolbarItem(placement: .primaryAction) {
        filterControl
      }
    }
    if !runs.trailing.isEmpty {
      ToolbarItemGroup(placement: .primaryAction) {
        ForEach(runs.trailing, id: \.self) { control in
          rendered(control)
        }
      }
    }
  }

  @ViewBuilder
  private func rendered(_ control: ShellToolbarControl) -> some View {
    switch control {
    case .info: info
    // Rendered by `DefaultToolbarItem` in `body`; never a view of the app's.
    case .search: EmptyView()
    case .select: GridSelectControl(store: store)
    // `ShellToolbarRuns` never puts Filter in a run; the one rendering is `filterControl`.
    case .filter: filterControl
    case .sort: GridSortControl(store: store)
    case .group: GridGroupControl(store: store)
    case .zoom: GridZoomControl(store: store)
    case .shortcutHelp: GridShortcutHelpControl(store: store)
    case .more: GridToolbarMoreMenu(store: store, openShootWindow: openShootWindow)
    }
  }

  /// WP29 P1 (plan Decision 1): Filter's count on its own item. SDK 26.5 declares no `badge` on
  /// `ToolbarItem` or `ToolbarContent` (`SDKSurfaceProbe`), so the plan's `ToolbarItem{}.badge`
  /// is UNRESOLVED and this is the probed fallback: `View.badge` on the ONE control of a
  /// `ToolbarItem` of its own — the exact shape the probe compiles. Inside a group the system
  /// re-hosts each control as a bar button and the count had no item to belong to. The
  /// funnel's dot stays (the plan's fallback) until a screenshot shows the bar drawing the
  /// count (`GridToolbarUITests` (d), `grid-filter-badge-*`); the spoken count is the
  /// control's own label either way.
  private var filterControl: some View {
    GridFilterControl(store: store).badge(filterCount)
  }

  private var filterCount: Int {
    InspectorFacetFilters.activeCount(store.currentQuery)
  }
}

/// WP29 P1 (IMGMGR-452): the grid's More menu on the Regular bar. The same rows the Compact
/// action bar's More renders (`GridMoreMenuContent`), never a second list; the Regular bar never
/// folds Clear (`ActionBarMetrics.regularTiers`), so the Clear row keeps its menu identity.
struct GridToolbarMoreMenu: View {
  let store: GridStore
  let openShootWindow: ShootWindowOpener

  var body: some View {
    Menu {
      GridMoreMenuContent(
        store: store, foldsClearIntoMore: false, openShootWindow: openShootWindow)
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    // The shipped identifier, kept: at Regular this IS the grid's More.
    .accessibilityIdentifier("gridMoreMenu")
  }
}
