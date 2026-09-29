import SwiftUI

/// WP28 P1 (IMGMGR-448): the one destination both shells show — the grid, or at Regular the
/// docked loupe in its place, together with the Root-owned Info item on the grid's bar and the
/// inspector. Extracted verbatim from `RootView.contentColumn`; what it does not carry is
/// deliberate:
///
/// - the Account item. At Compact it used to ride this bar as well (IMGMGR-255), because the
///   collapsed split pushed the grid over the only other bar that carried it. The Compact shell's
///   Shoots tab is now Account's one Compact home (p4128 R2-Inventory), and Regular never had it
///   here;
/// - the facets-refresh trigger, which stays on `RootView.workspace` so it outlives any shell,
///   tab or inspector state (IMGMGR-298).
///
/// WP28 P3 (IMGMGR-450): the inspector is the system `.inspector`, attached to the WHOLE
/// destination so it stays beside the docked loupe exactly as the retired Regular-3 column did.
/// The system shows it as a trailing column at Regular and adapts it to a sheet at Compact; the
/// Info control toggles the one `showInspector` flag in every mode.
struct WorkspaceContent: View {
  let store: GridStore
  let service: GridService
  let share: ShareExportStore
  let layoutMode: LayoutMode
  /// WP28 P2 (IMGMGR-449): the shared folder search text, which the grid's toolbar search edits
  /// at Regular and the sidebar's tree filters by.
  let folderSearch: FolderSearchModel
  /// WP28 P3: the queue the Summary sheet reads its server counts from.
  let queueStore: QueueStore
  /// WP28 P3: the grid's navigation title (`WorkspaceTitle`), nil only when no folder is shown —
  /// a shown folder always has one, so its title menu (the Summary entry) always exists.
  /// WP29 P1 (IMGMGR-452): carried by the breadcrumb, which adds the server count.
  let breadcrumb: GridBreadcrumb?
  /// The one inspector flag, at every width. Session-scoped, collapsed at launch (IMGMGR-390).
  @Binding var showInspector: Bool
  /// WP28 P3: the Summary sheet, opened only from the title menu (Decision 1, no auto-trigger).
  @State private var showSummary = false
  /// WP29 P1: the scene's window action, for the Regular bar's More ("Open in New Window"). Copied
  /// into a local before the opener's closure is formed, as `GridView.openShootWindow` does.
  @Environment(\.openWindow) private var openWindow

  private var title: String? { breadcrumb?.title }

  private var shootWindowOpener: ShootWindowOpener {
    let open = openWindow
    return ShootWindowOpener { value in open(value: value) }
  }

  var body: some View {
    Group {
      // P5: Regular-2/3's loupe presentation — docked in place of the grid, never a takeover
      // (spec: "not a full-screen takeover by default... the detail pane, with the grid retained
      // as a filmstrip"). Compact never takes this branch (its loupe is always the full-screen
      // cover on `RootView`). The docked loupe carries no title and no title menu.
      if store.isLoupeOpen && layoutMode != .compact {
        LoupeView(store: store, layoutMode: layoutMode, share: share)
      } else {
        GridView(store: store, layoutMode: layoutMode)
          .toolbar {
            // Fold item 7's persistent chrome control, unchanged in role: this ONE control is how
            // the inspector is reached at every width — never a second, width-specific surface.
            // IMGMGR-390: it is the sixth member of the set `WorkspaceChromePlacement` places on
            // the GRID's bar in every state. WP28 P2 (IMGMGR-449): it and the five grid view
            // options are ONE group, whose membership and order `ShellToolbarLayout` states.
            ShellToolbarGroup(
              controls: ShellToolbarLayout.gridBar(
                for: layoutMode,
                inspectorUsesChromeControl: inspectorPresentation.usesChromeControl),
              store: store, info: inspectorChromeButton, openShootWindow: shootWindowOpener)
          }
          // WP28 P2: the Regular folder search, on the grid only — the docked loupe branch above
          // carries none, so its chrome is unchanged — and never at Compact, whose Search tab is
          // the one search surface there.
          .modifier(RegularFolderSearch(search: folderSearch, isEnabled: layoutMode != .compact))
          // WP28 P3 (IMGMGR-450), Decision 1: the folder's name in the grid's principal slot, and
          // its title menu's one row, "Shoot Summary". WP29 P1 (IMGMGR-452, plan Decision 3): at
          // Regular the slot is p4128's breadcrumb — the name plus the server's count as the
          // system subtitle; Compact keeps its pushed title alone.
          .navigationTitle(title ?? "")
          .modifier(
            RegularBreadcrumbSubtitle(
              subtitle: breadcrumb?.subtitle, isEnabled: layoutMode != .compact)
          )
          .navigationBarTitleDisplayMode(.inline)
          .toolbarTitleMenu {
            Button {
              showSummary = true
            } label: {
              Label(ShootSummarySheet.sheetTitle, systemImage: "chart.bar.doc.horizontal")
            }
            .accessibilityIdentifier("shootSummaryTitleMenuRow")
          }
          .sheet(isPresented: $showSummary) {
            ShootSummarySheet(
              queueStore: queueStore, folderID: store.query.folderID, title: title,
              layoutMode: layoutMode)
          }
      }
    }
    .inspector(isPresented: $showInspector) {
      InspectorView(store: store, service: service)
        .inspectorColumnWidth(
          min: InspectorColumnMetrics.minWidth, ideal: InspectorColumnMetrics.idealWidth,
          max: InspectorColumnMetrics.maxWidth)
    }
  }

  /// The inspector's presentation at the CURRENT layout mode — read by the toolbar condition.
  private var inspectorPresentation: InspectorPresentation {
    InspectorPlacement.presentation(for: layoutMode)
  }

  /// The Info button doubles as the "filters are on" indicator: on Compact the Info·Stats sheet
  /// is the ONLY filter surface, so the count has to ride the control that opens it — there is
  /// no other chrome to put it on, and a filtered grid that looks unfiltered is exactly the
  /// failure this prevents. The count is the facet fields only, never the shoot scope
  /// (`InspectorFacetFilters`), so browsing an archive shoot never reads as "filtered".
  @ViewBuilder
  private var inspectorChromeButton: some View {
    let activeFilters = InspectorFacetFilters.activeCount(store.currentQuery)
    let spokenLabel = InspectorFacetFilters.infoButtonAccessibilityLabel(activeCount: activeFilters)
    Button {
      // A TOGGLE, not a one-way open: the Regular inspector column has no grabber, so the
      // persistent chrome control is also how it closes (zero gesture-only actions). At Compact
      // the system's sheet covers this control while it is up and is dismissed by its own drag.
      withAnimation(.snappy(duration: 0.25)) { showInspector.toggle() }
    } label: {
      if activeFilters > 0 {
        // IMGMGR-224: the spoken phrasing rides the TITLE TEXT itself. A `ToolbarItem`'s bar item
        // is built from the button's title, and the WP13 P10 gate log recorded VoiceOver reading
        // the visual "Info · 1" while `.accessibilityLabel` on the button sat there as dead code;
        // the 23:26 run of this lane showed the same for the collapsed-content form. Labelling
        // the Text is the remaining attachment point that travels with the title the bar item
        // actually takes. The visual string is unchanged either way.
        Label {
          Text(InspectorFacetFilters.infoButtonTitle(activeCount: activeFilters))
            .accessibilityLabel(spokenLabel)
        } icon: {
          Image(systemName: "line.3.horizontal.decrease.circle.fill")
        }
        .labelStyle(.titleAndIcon)
      } else {
        Label {
          Text("Info").accessibilityLabel(spokenLabel)
        } icon: {
          Image(systemName: "info.circle")
        }
      }
    }
    .accessibilityLabel(spokenLabel)
    // Diagnostic AND useful: the account item's own identifier surfaces through the same bridge
    // (gate tree, `accountToolbarButton`), so if this one appears while the label still does not,
    // the bridge drops labels specifically — which is the finding, not a guess.
    .accessibilityIdentifier("inspectorChromeButton")
  }

}

/// WP29 P1 (IMGMGR-452): the breadcrumb's count, as the system navigation subtitle, at Regular
/// only. Keyed on the WIDTH alone (like `RegularFolderSearch`), never on whether a count is known,
/// so a folder whose count arrives later does not swap the grid's view identity: an unknown count
/// is an empty subtitle.
struct RegularBreadcrumbSubtitle: ViewModifier {
  let subtitle: String?
  let isEnabled: Bool

  func body(content: Content) -> some View {
    if isEnabled {
      content.navigationSubtitle(subtitle ?? "")
    } else {
      content
    }
  }
}

/// WP28 P2 (IMGMGR-449), plan Decision 5: the Regular shell's folder search — a toolbar search
/// that `.minimize` renders as a button and expands to a field when the reader asks for it. It
/// edits the shared `FolderSearchModel`, so the sidebar's tree filters as the reader types.
/// Disabled, it adds nothing at all.
struct RegularFolderSearch: ViewModifier {
  @Bindable var search: FolderSearchModel
  let isEnabled: Bool

  func body(content: Content) -> some View {
    if isEnabled {
      content
        .searchable(text: $search.text, placement: .toolbar, prompt: "Search folders")
        .searchToolbarBehavior(.minimize)
    } else {
      content
    }
  }
}
