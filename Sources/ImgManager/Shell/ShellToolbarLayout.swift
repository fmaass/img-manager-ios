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

/// Renders a `ShellToolbarLayout` list. The app's own controls are `ToolbarItemGroup`s; the
/// system search is a `DefaultToolbarItem`, which is toolbar content rather than a view, so the
/// list is rendered as the run BEFORE `.search`, the search item, and the run AFTER it — the
/// declared order either way. Whether the system draws them as one glass cluster is decided by
/// the gate's screenshots, not here: system components only, no background of its own (ADR-N1).
struct ShellToolbarGroup<Info: View>: ToolbarContent {
  let controls: [ShellToolbarControl]
  let store: GridStore
  /// The Info button, built by `WorkspaceContent`.
  let info: Info
  /// WP29 P1: handed to the bar's More, whose "Open in New Window" row needs it.
  let openShootWindow: ShootWindowOpener

  private var leading: [ShellToolbarControl] {
    guard let index = controls.firstIndex(of: .search) else { return controls }
    return Array(controls[..<index])
  }

  private var trailing: [ShellToolbarControl] {
    guard let index = controls.firstIndex(of: .search) else { return [] }
    return Array(controls[controls.index(after: index)...])
  }

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      ForEach(leading, id: \.self) { control in
        rendered(control)
      }
    }
    if controls.contains(.search) {
      DefaultToolbarItem(kind: .search, placement: .primaryAction)
    }
    if !trailing.isEmpty {
      ToolbarItemGroup(placement: .primaryAction) {
        ForEach(trailing, id: \.self) { control in
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
    // WP29 P1 (plan Decision 1): the count as a badge. SDK 26.5 declares no `badge` on
    // `ToolbarItem`, so the one spelling it has is `View.badge` on the item's control; the dot
    // stays until a screenshot shows the bar drawing this.
    case .filter: GridFilterControl(store: store).badge(filterCount)
    case .sort: GridSortControl(store: store)
    case .group: GridGroupControl(store: store)
    case .zoom: GridZoomControl(store: store)
    case .shortcutHelp: GridShortcutHelpControl(store: store)
    case .more: GridToolbarMoreMenu(store: store, openShootWindow: openShootWindow)
    }
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
