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
  /// WP442 P12: the grid instance's CONSTANT scope — `.stream` for the workspace route, the
  /// entered scene for a pushed `.scene` route; Regular passes `store.activeScope`.
  let scope: GridScope
  /// WP28 P3: the queue the Summary sheet reads its server counts from.
  let queueStore: QueueStore
  /// WP28 P3: the grid's navigation title (`WorkspaceTitle`), nil only when no folder is shown —
  /// a shown folder always has one, so its title menu (the Summary entry) always exists.
  /// WP29 P1 (IMGMGR-452): carried by the breadcrumb, which adds the server count.
  let breadcrumb: GridBreadcrumb?
  /// The one inspector flag, at every width. Session-scoped, collapsed at launch (IMGMGR-390).
  @Binding var showInspector: Bool
  /// IMGMGR-478: the Regular split's visibility, so the grid's bar can bring a hidden sidebar
  /// back (`GridBarSidebarToggle`). At Compact the toggle is never built.
  @Binding var columnVisibility: NavigationSplitViewVisibility
  /// WP28 P3: the Summary sheet, opened only from the title menu (Decision 1, no auto-trigger).
  @State private var showSummary = false
  /// WP29 P1: the scene's window action, for the Regular bar's More ("Open in New Window"). Copied
  /// into a local before the opener's closure is formed, as `GridView.openShootWindow` does.
  @Environment(\.openWindow) private var openWindow

  private var title: String? { breadcrumb?.title }

  private var isActive: Bool { scope == store.activeScope }

  /// The entered destination's own title: "Scene · N photos" inside a scene, "493 photos
  /// without a mark" inside the Mark/Rating remainder (IMGMGR-541, frozen at entry), nil on the
  /// stream.
  private var entryTitle: String? {
    switch scope {
    case .stream: return nil
    case .scene(let id): return store.sceneTitle(for: id)
    case .remainder(let key):
      return GroupRemainder.rowTitle(count: store.remainderEntryCount, groupBy: key)
    }
  }

  /// The navigation title: the folder's, or the entered destination's.
  private var shownTitle: String {
    entryTitle ?? title ?? ""
  }

  /// D1: inside a scene (or the remainder) the principal breadcrumb is its title with NO folder
  /// counts.
  private var shownBreadcrumb: GridBreadcrumb? {
    guard let entryTitle else { return breadcrumb }
    return GridBreadcrumb(title: entryTitle, subtitle: nil)
  }

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
        // WP30 P1 (IMGMGR-456): the loupe's own toolbar (`LoupeToolbar`) renders on this
        // column's bar; the grid's `.toolbar` below is attached only in the `else` branch, so no
        // grid item is mounted while the loupe is open.
        // WP30 P3 (IMGMGR-458), plan decision 5: Compare is a state swap in this same container,
        // never a push; its Back swaps the loupe back in on the current left image.
        if store.isCompareOpen {
          CompareView(store: store, chrome: loupeChrome)
        } else {
          LoupeView(store: store, layoutMode: layoutMode, share: share, chrome: loupeChrome)
        }
      } else {
        GridView(store: store, layoutMode: layoutMode, scope: scope)
          .id(scope)
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
            // IMGMGR-478: the bar's leading slot, while the Regular sidebar is hidden — a visible
            // way back that is not the system toggle alone.
            GridBarSidebarToggle(layoutMode: layoutMode, columnVisibility: $columnVisibility)
          }
          // WP28 P3 (IMGMGR-450), Decision 1: the folder's name in the grid's principal slot, and
          // its title menu's one row, "Shoot Summary". WP29 P1 (IMGMGR-452): at Regular the slot
          // is p4128's breadcrumb (`GridBreadcrumbTitle`); Compact keeps its pushed title alone.
          .navigationTitle(shownTitle)
          .modifier(
            SceneFolderSubtitle(
              subtitle: entryTitle != nil && layoutMode == .compact ? (title ?? "") : nil)
          )
          .navigationBarTitleDisplayMode(.inline)
          .modifier(
            GridBreadcrumbTitle(
              breadcrumb: shownBreadcrumb, isRegular: layoutMode != .compact,
              openSummary: { showSummary = true })
          )
          .toolbar {
            if entryTitle != nil, layoutMode != .compact {
              ToolbarItem(placement: .topBarLeading) {
                SceneBackButton(folderTitle: title ?? "", store: store)
              }
            }
          }
          .sheet(isPresented: $showSummary) {
            ShootSummarySheet(
              queueStore: queueStore, folderID: store.query.folderID, title: title,
              layoutMode: layoutMode, syncService: service.syncService)
          }
      }
    }
    .inspector(isPresented: isActive ? $showInspector : .constant(false)) {
      InspectorView(store: store, service: service)
        .inspectorColumnWidth(
          min: InspectorColumnMetrics.minWidth, ideal: InspectorColumnMetrics.idealWidth,
          max: InspectorColumnMetrics.maxWidth)
    }
  }

  /// WP30 P1: the loupe's title and Info, from the SAME breadcrumb title and inspector flag the
  /// grid bar uses — so the loupe's Info toggles the one inspector.
  private var loupeChrome: LoupeChrome {
    guard inspectorPresentation.usesChromeControl else {
      return LoupeChrome(shootTitle: title ?? "", info: nil)
    }
    let binding = $showInspector
    let info = LoupeChrome.Info(isPresented: showInspector) {
      withAnimation(.snappy(duration: 0.25)) { binding.wrappedValue.toggle() }
    }
    return LoupeChrome(shootTitle: title ?? "", info: info)
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

/// WP29 P1 (IMGMGR-452): the grid's title slot. At Regular it is p4128's breadcrumb — the
/// shoot's name over the server's count — as a PRINCIPAL toolbar item holding the Summary row in
/// a `Menu`. That is the plan's named pivot: the system title with `.navigationSubtitle` and
/// `.toolbarTitleMenu` lead-aligned on iPadOS 26.5 (gate on c96429a: title minX 340, off its
/// bar's midX by -81 pt at Regular-2 and -253 pt at Regular-3). Compact keeps the system title
/// menu. Keyed on the WIDTH alone, so a count that arrives later
/// never swaps the grid's view identity; the Summary row keeps its one identifier either way.
struct GridBreadcrumbTitle: ViewModifier {
  let breadcrumb: GridBreadcrumb?
  let isRegular: Bool
  let openSummary: () -> Void

  func body(content: Content) -> some View {
    if isRegular {
      content.toolbar {
        if let breadcrumb {
          ToolbarItem(placement: .principal) {
            Menu {
              summaryRow
            } label: {
              VStack(spacing: 0) {
                Text(breadcrumb.title).font(.headline).lineLimit(1)
                if let subtitle = breadcrumb.subtitle {
                  Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
              }
            }
          }
        }
      }
    } else {
      content.toolbarTitleMenu {
        summaryRow
      }
    }
  }

  private var summaryRow: some View {
    Button(action: openSummary) {
      Label(ShootSummarySheet.sheetTitle, systemImage: "chart.bar.doc.horizontal")
    }
    .accessibilityIdentifier("shootSummaryTitleMenuRow")
  }
}
