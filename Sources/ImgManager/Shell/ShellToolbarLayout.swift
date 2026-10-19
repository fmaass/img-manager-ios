import SwiftUI

/// WP28 P2 (IMGMGR-449): the controls the grid's chrome carries — the grid view options, the
/// inspector's persistent chrome control (IMGMGR-338 calls them host chrome) and, since WP29 P1
/// (IMGMGR-452), Select and More. R3-18 (IMGMGR-550) removed the system search item. Each case
/// names the accessibility identifier its control already ships with; none is renamed.
enum ShellToolbarControl: CaseIterable, Hashable, Sendable {
  /// The inspector's Info button. Root-owned: `WorkspaceContent` builds it, because what it
  /// toggles is the inspector topology, which the grid does not know about.
  case info
  /// WP29 P1: Select, moved out of the More menu onto the bar. Same identifier, same action.
  case select
  /// WP16 P3 (IMGMGR-295), decision 1: filtering reaches the grid's own chrome.
  case filter
  /// WP29 P2 (IMGMGR-453): how the stream is arranged — sort, direction, grouping and thumbnail
  /// size in one popover (`GridArrangeControl`). It replaced the Sort, Group and Zoom controls.
  case arrange
  /// WP29 P1: the grid's More menu. At Regular it moved from the bottom action bar to the bar;
  /// at Compact it stays on the action bar (`WorkspaceChromePlacement.actionBarCarriesMore`).
  case more
  /// WP31 P1 (IMGMGR-460): the way into Triage — Compact only (iPad culls in the loupe). Its
  /// home is Compact's options row (IMGMGR-462), never a bar.
  case triage

  /// Every control ships an identifier of the app's (optional for a future system item).
  var accessibilityIdentifier: String? {
    switch self {
    case .info: "inspectorChromeButton"
    case .select: "gridSelectCommand"
    case .filter: "gridFilterControl"
    case .arrange: GridArrangeControl.accessibilityIdentifier
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
/// - WP29 P1 (IMGMGR-452): then the spec's trailing group, in p4128's order — Select · Filter ·
///   Arrange · More. WP29 P2 (IMGMGR-453) put Arrange in its slot; R3-18 (IMGMGR-550) removed
///   the system search that stood before Select.
enum ShellToolbarLayout {
  /// Every Regular width, both inspector states (`WorkspaceChromeHost.gridColumn`).
  static let regularGridBar: [ShellToolbarControl] = [
    .info, .select, .filter, .arrange, .more,
  ]

  /// WP29 P1: Compact's navigation bar — Info, and Select beside it. More stays on the bottom
  /// action bar.
  ///
  /// IMGMGR-462 (WP31 P3): back to its pre-WP31 members. WP31 P1 had Triage leading this bar,
  /// and on iOS 26 a long title (a shoot's tree name, "2026-08-27 — Stub Shoot") pushed all
  /// three controls into the bar's "More" overflow — Triage, Info and Select each one tap
  /// further away. Triage now lives in `compactOptionsRow`, which is content, not bar, and
  /// never overflows.
  static let compactGridBar: [ShellToolbarControl] = [.info, .select]

  /// Compact's persistent options row (`GridOptionsRow`): Arrange, the funnel and Triage (WP29
  /// P2; Triage since IMGMGR-462, WP31 P3).
  ///
  /// IMGMGR-464 (WP32 P2, p4128 D10): the trailing keyboard-glyph "?" is gone — owner ruling
  /// 2026-10-02, "remove the visible help control at Compact; the sheet opens with ⌘/ (hardware
  /// keyboard) and from the iPad menu bar". No `ShellToolbarControl` opens the shortcut sheet at
  /// any width; its two entry points are the View menu's "Keyboard Shortcuts" row (⌘/) and that
  /// row's silent `?` twin (`AppCommands.helpRow`).
  static let compactOptionsRow: [ShellToolbarControl] = [.arrange, .filter, .triage]

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

/// Renders a `ShellToolbarLayout` list as ONE `ToolbarItemGroup`, in the declared order — Info
/// first, so the OS's fold from the trailing end never reaches it (IMGMGR-390). Until R3-18
/// (IMGMGR-550) the list was cut into two groups around the system search item
/// (`DefaultToolbarItem(kind: .search)`); with the search gone there is nothing to cut around.
/// System components only, no background of its own (ADR-N1).
///
/// Filter rides the group. The plan's own `ToolbarItem` for it (to carry a count badge) was built
/// and gated on c96429a: on iPad the standalone item never re-rendered after a filter landed (its
/// value stayed "Off" — `FilterPopoverUITests`, `GridToolbarUITests` (d)), a regression of
/// shipped behaviour. The badge is UNRESOLVED per the plan's fallback (the dot stays); SDK 26.5
/// has no `ToolbarItem` badge at all (`SDKSurfaceProbe`).
struct ShellToolbarGroup<Info: View>: ToolbarContent {
  let controls: [ShellToolbarControl]
  let store: GridStore
  /// The Info button, built by `WorkspaceContent`.
  let info: Info
  /// WP29 P1: handed to the bar's More, whose "Open in New Window" row needs it.
  let openShootWindow: ShootWindowOpener

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      ForEach(controls, id: \.self) { control in
        rendered(control)
      }
    }
  }

  @ViewBuilder
  private func rendered(_ control: ShellToolbarControl) -> some View {
    switch control {
    case .info: info
    case .select: GridSelectControl(store: store)
    // The shipped funnel and its dot, unchanged (see `ShellToolbarGroup` for the badge).
    case .filter: GridFilterControl(store: store)
    case .arrange: GridArrangeControl(store: store)
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
