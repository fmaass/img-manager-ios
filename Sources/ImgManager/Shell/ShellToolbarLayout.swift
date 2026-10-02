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
  /// WP29 P2 (IMGMGR-453): how the stream is arranged — sort, direction, grouping and thumbnail
  /// size in one popover (`GridArrangeControl`). It replaced the Sort, Group and Zoom controls.
  case arrange
  /// The shortcut help sheet's chrome route. WP29 P1 (plan Decision 1) takes it off the REGULAR
  /// bar — its homes there are ⌘/ and the menu bar's "Keyboard Shortcuts" — and keeps it on
  /// Compact's options row, because an iPhone has no menu bar.
  case shortcutHelp
  /// WP29 P1: the grid's More menu. At Regular it moved from the bottom action bar to the bar;
  /// at Compact it stays on the action bar (`WorkspaceChromePlacement.actionBarCarriesMore`).
  case more
  /// WP31 P1 (IMGMGR-460): the way into Triage — Compact only (iPad culls in the loupe). Its
  /// home is Compact's options row (IMGMGR-462), never a bar.
  case triage

  /// Nil for the system search item, which carries no identifier of the app's.
  var accessibilityIdentifier: String? {
    switch self {
    case .info: "inspectorChromeButton"
    case .search: nil
    case .select: "gridSelectCommand"
    case .filter: "gridFilterControl"
    case .arrange: GridArrangeControl.accessibilityIdentifier
    case .shortcutHelp: "gridShortcutHelpControl"
    case .more: "gridMoreMenu"
    case .triage: GridTriageControl.accessibilityIdentifier
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
///   Filter · Arrange · More. WP29 P2 (IMGMGR-453) put Arrange in its slot.
enum ShellToolbarLayout {
  /// Every Regular width, both inspector states (`WorkspaceChromeHost.gridColumn`).
  static let regularGridBar: [ShellToolbarControl] = [
    .info, .search, .select, .filter, .arrange, .more,
  ]

  /// WP29 P1: Compact's navigation bar — Info, and Select beside it. Search is the Search tab
  /// there and More stays on the bottom action bar.
  ///
  /// IMGMGR-462 (WP31 P3): back to its pre-WP31 members. WP31 P1 had Triage leading this bar,
  /// and on iOS 26 a long title (a shoot's tree name, "2026-08-27 — Stub Shoot") pushed all
  /// three controls into the bar's "More" overflow — Triage, Info and Select each one tap
  /// further away. Triage now lives in `compactOptionsRow`, which is content, not bar, and
  /// never overflows.
  static let compactGridBar: [ShellToolbarControl] = [.info, .select]

  /// Compact's persistent options row (`GridOptionsRow`): Arrange, the funnel, Triage, and "?"
  /// at the trailing end (WP29 P2; Triage since IMGMGR-462, WP31 P3).
  static let compactOptionsRow: [ShellToolbarControl] = [
    .arrange, .filter, .triage, .shortcutHelp,
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

/// WP29 P1 (IMGMGR-452): a `ShellToolbarLayout` list cut where the toolbar renders it. The
/// system search is toolbar content (`DefaultToolbarItem`), never a view inside a group, so the
/// app's controls ride the two group runs on either side of it. Pure, so a unit test pins that
/// the rendered order IS the declared order (`flattened == controls`) at every width.
///
/// Filter rides the trailing run. The plan's own `ToolbarItem` for it (to carry a count badge)
/// was built and gated on c96429a: on iPad the standalone item never re-rendered after a filter
/// landed (its value stayed "Off" — `FilterPopoverUITests`, `GridToolbarUITests` (d)), a
/// regression of shipped behaviour. The badge is UNRESOLVED per the plan's fallback (the dot
/// stays); SDK 26.5 has no `ToolbarItem` badge at all (`SDKSurfaceProbe`).
struct ShellToolbarRuns: Equatable, Sendable {
  /// The app's controls before the search item — Info at every width.
  private(set) var leading: [ShellToolbarControl] = []
  private(set) var search = false
  /// After the search item — Select, Filter, Arrange and More at Regular.
  private(set) var trailing: [ShellToolbarControl] = []

  init(_ controls: [ShellToolbarControl]) {
    for control in controls {
      if control == .search {
        search = true
      } else if search {
        trailing.append(control)
      } else {
        leading.append(control)
      }
    }
  }

  /// The order the toolbar renders: leading group, search item, trailing group.
  var flattened: [ShellToolbarControl] {
    leading + (search ? [.search] : []) + trailing
  }
}

/// Renders a `ShellToolbarLayout` list as `ShellToolbarRuns` cuts it: the app's runs are
/// `ToolbarItemGroup`s and the system search a `DefaultToolbarItem` — the declared order either
/// way. Whether the system draws them as one glass cluster is decided by the gate's screenshots,
/// not here: system components only, no background of its own (ADR-N1).
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
    // The shipped funnel and its dot, unchanged (see `ShellToolbarRuns` for the badge).
    case .filter: GridFilterControl(store: store)
    case .arrange: GridArrangeControl(store: store)
    case .shortcutHelp: GridShortcutHelpControl(store: store)
    case .more: GridToolbarMoreMenu(store: store, openShootWindow: openShootWindow)
    // A member of no bar (`compactOptionsRow` holds it); here only for exhaustiveness.
    case .triage: GridTriageControl(store: store)
    }
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
