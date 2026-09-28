import SwiftUI

/// WP28 P1 (IMGMGR-448): the one destination both shells show — the grid, or at Regular the
/// docked loupe in its place, together with the Root-owned Info item on the grid's bar, the
/// inspector's presentation (sheet, slide-over) and the overlays that hang off the grid pane.
/// Extracted verbatim from `RootView.contentColumn`; what it does not carry is deliberate:
///
/// - the Account item. At Compact it used to ride this bar as well (IMGMGR-255), because the
///   collapsed split pushed the grid over the only other bar that carried it. The Compact shell's
///   Shoots tab is now Account's one Compact home (p4128 R2-Inventory), and Regular never had it
///   here;
/// - the facets-refresh trigger, which stays on `RootView.workspace` so it outlives any shell,
///   tab or inspector state (IMGMGR-298);
/// - the Regular-3 inspector COLUMN and the split view's visibility, which are the split's own
///   topology — the chrome control reaches them only through `inspectorVisibility`, the binding
///   `RootView` resolves in one place.
struct WorkspaceContent: View {
  let store: GridStore
  let service: GridService
  let share: ShareExportStore
  let layoutMode: LayoutMode
  /// WP28 P2 (IMGMGR-449): the shared folder search text, which the grid's toolbar search edits
  /// at Regular and the sidebar's tree filters by.
  let folderSearch: FolderSearchModel
  /// The one flag behind every NON-permanent presentation (sheet, slide-over).
  @Binding var showInspector: Bool
  /// What the persistent chrome control toggles at the current width — `RootView`'s
  /// `inspectorVisibilityBinding`, which picks the column flag at Regular-3 and `showInspector`
  /// everywhere else.
  let inspectorVisibility: Binding<Bool>

  var body: some View {
    Group {
      // P5: Regular-2/3's loupe presentation — docked in place of the grid, never a takeover
      // (spec: "not a full-screen takeover by default... the detail pane, with the grid retained
      // as a filmstrip"). Compact never takes this branch (its loupe is always the full-screen
      // cover on `RootView`).
      if store.isLoupeOpen && layoutMode != .compact {
        LoupeView(store: store, layoutMode: layoutMode, share: share)
      } else {
        GridView(store: store, layoutMode: layoutMode)
          .toolbar {
            // Fold item 7's persistent chrome control, unchanged in role: wherever the inspector
            // is not a permanent column, this ONE control is how it is reached — never a second,
            // width-specific surface (`InspectorPlacement` decides what it presents). IMGMGR-390:
            // it is the sixth member of the set `WorkspaceChromePlacement` places on the GRID's
            // bar in every state; the inspector column could not host it (`WorkspaceChromeHost`).
            // WP28 P2 (IMGMGR-449): it and the five grid view options are ONE group, whose
            // membership and order `ShellToolbarLayout` states.
            ShellToolbarGroup(
              controls: ShellToolbarLayout.gridBar(
                for: layoutMode,
                inspectorUsesChromeControl: inspectorPresentation.usesChromeControl),
              store: store, info: inspectorChromeButton)
          }
          // WP28 P2: the Regular folder search, on the grid only — the docked loupe branch above
          // carries none, so its chrome is unchanged — and never at Compact, whose Search tab is
          // the one search surface there.
          .modifier(RegularFolderSearch(search: folderSearch, isEnabled: layoutMode != .compact))
          .overlay(alignment: .trailing) {
            // The ONE place P10 could have gone wrong: the slide-over is an overlay ON THE
            // DETAIL PANE, never a third column. `workspace`'s 2-column `NavigationSplitView`
            // for Compact/Regular-2 is a deliberate WP8 diff-gate round-3 fix (reusing the
            // 3-column initializer with an empty `detailColumn` still reserved a wasted pane
            // under `.doubleColumn`, squeezing the grid), and a panel built as a column would
            // undo it. An overlay sits outside NavigationSplitView's column management
            // entirely, so the two cannot fight over the same space.
            if showInspector && inspectorPresentation == .slideOver {
              inspectorSlideOver
            }
          }
          .sheet(isPresented: inspectorSheetBinding) {
            InspectorView(store: store, service: service)
          }
      }
    }
  }

  /// The inspector's presentation at the CURRENT layout mode. One resolver, read by the toolbar
  /// condition, the sheet binding and the slide-over overlay alike, so the three can never
  /// disagree about which surface is showing.
  private var inspectorPresentation: InspectorPresentation {
    InspectorPlacement.presentation(for: layoutMode)
  }

  /// The sheet presents ONLY where the resolved presentation IS the sheet. One `showInspector`
  /// state drives every non-permanent presentation, so there is no width at which two of them
  /// could be on screen at once, and no second flag to drift out of step.
  private var inspectorSheetBinding: Binding<Bool> {
    Binding(
      get: { showInspector && inspectorPresentation.isModal },
      set: { showInspector = $0 })
  }

  /// [/link/3220] §2.2's side panel: anchored to the trailing edge of the grid pane,
  /// width-limited by `InspectorSlideOverMetrics`, and NON-MODAL — nothing dims, nothing is
  /// disabled, and the grid keeps taking taps beside it. Two details carry that guarantee:
  /// `GeometryReader` measures the PANE the overlay covers (so the width rule applies to the
  /// space actually available, including a half-width iPad window), and the widened frame around
  /// the panel carries no background, so it has no hit region of its own and taps in it reach the
  /// grid underneath. System materials only, never a custom `glassEffect` (ADR-N1) — `.bar` and
  /// `.thinMaterial` are already this app's chrome backing (`ActionBarView`, `GridView`).
  private var inspectorSlideOver: some View {
    GeometryReader { proxy in
      InspectorView(store: store, service: service)
        .frame(width: InspectorSlideOverMetrics.width(inPane: proxy.size.width))
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) { Divider() }
        .accessibilityIdentifier("inspectorSlideOver")
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .transition(.move(edge: .trailing))
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
      // A TOGGLE, not a one-way open: the slide-over has no sheet grabber to dismiss it, so the
      // persistent chrome control is also how it closes (zero gesture-only actions). At Compact
      // the sheet covers this control while it is up, so toggling reads exactly as before.
      // WP16 P2 (IMGMGR-298): at Regular-3 the same tap hides and restores the COLUMN — which
      // flag that is comes from `inspectorVisibilityBinding`, never from a branch written here.
      withAnimation(.snappy(duration: 0.25)) { inspectorVisibility.wrappedValue.toggle() }
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
