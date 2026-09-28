import SwiftUI
import Testing

@testable import ImgManager

/// The inspector's PRESENTATION per layout mode, pinned as values. `InspectorPlacement` is the
/// production decision itself — `WorkspaceContent`'s toolbar condition reads it.
///
/// WP28 P3 (IMGMGR-450) retired the hand-built topology (a Regular-2 overlay panel and a
/// Regular-3 split column) for the system `.inspector`. The pins below carry the same intents
/// onto it: Compact is the modal sheet, both Regular widths are ONE non-modal column, the Info
/// control reaches it everywhere, and the split keeps the sidebar beside the grid (IMGMGR-390).
@Suite("Inspector presentation per layout mode (WP13 P10, WP28 P3)")
struct LayoutPresentationTests {

  @Test("Regular-2 presents the inspector as a non-modal column, never a sheet")
  func regular2PresentsTheInspectorAsANonModalColumn() {
    let presentation = InspectorPlacement.presentation(for: .regular2)
    #expect(presentation == .inspectorColumn)
    // The load-bearing half ([/link/3220] §2.2): the grid keeps taking taps beside it. The UI
    // twin is `InspectorSummaryUITests.testBRegular2...`, which taps a grid cell while it is open.
    #expect(presentation.isModal == false)
    #expect(presentation.usesChromeControl)
  }

  @Test("Compact still presents the sheet")
  func compactStillPresentsTheSheet() {
    let presentation = InspectorPlacement.presentation(for: .compact)
    #expect(presentation == .sheet)
    #expect(presentation.isModal)
    #expect(presentation.usesChromeControl)
  }

  /// WP16 P2 (IMGMGR-298, [/link/3332] decision 4) made Regular-3's inspector collapsible from the
  /// chrome control; WP28 P3 keeps that and makes it the same system column Regular-2 has.
  @Test("Regular-3 presents the same non-modal column, reached from chrome")
  func regular3PresentsTheSameNonModalColumn() {
    let presentation = InspectorPlacement.presentation(for: .regular3)
    #expect(presentation == .inspectorColumn)
    #expect(presentation.isModal == false)
    #expect(presentation.usesChromeControl)
  }

  /// WP28 P3 collapses the three presentations to two: the two Regular widths now share one, and
  /// Compact alone differs. A change that made Regular-2 modal again, or gave Compact a column,
  /// fails here.
  @Test("Both Regular widths share one presentation; Compact alone is the sheet")
  func bothRegularWidthsShareOnePresentation() {
    #expect(
      InspectorPlacement.presentation(for: .regular2)
        == InspectorPlacement.presentation(for: .regular3))
    #expect(
      InspectorPlacement.presentation(for: .compact)
        != InspectorPlacement.presentation(for: .regular2))
  }

  /// Scope: this pins the STRINGS and the fact that a chrome control exists at every width. The
  /// proof that the shipped button consumes them lives in `InspectorSlideOverUITests`
  /// .assertTheChromeControlReportsTheActiveFilterCount.
  @Test("The Info control still carries the active filter count")
  func theInfoControlStillCarriesTheActiveFilterCount() {
    for mode in [LayoutMode.compact, .regular2, .regular3] {
      #expect(InspectorPlacement.presentation(for: mode).usesChromeControl)
    }

    var query = GridImagesQuery(folderID: 7)
    query.mark = "pick"
    query.ratingMin = 4
    // The shoot scope is deliberately NOT counted — browsing one folder must not read as
    // "filtered" (see `InspectorFacetFilters`).
    #expect(InspectorFacetFilters.activeCount(query) == 2)
    #expect(InspectorFacetFilters.infoButtonTitle(activeCount: 2) == "Info · 2")
    #expect(
      InspectorFacetFilters.infoButtonAccessibilityLabel(activeCount: 2)
        == "Info, 2 filters active")
  }

  /// IMGMGR-390 (owner decision on IMGMGR-338, comment 3731): "the sidebar/queue stays visible".
  /// Before WP28 P3 that took a pure function choosing `.doubleColumn` for the collapsed 3-column
  /// state; with the inspector out of the split, the split is always 2-column and the resolver's
  /// own answer is what `RootView.applyWidth` applies. `.detailOnly` — the grid alone, what WP16
  /// P2 shipped — is the value that must never come back at a Regular width.
  @Test("Every Regular width keeps the sidebar beside the grid")
  func everyRegularWidthKeepsTheSidebarBesideTheGrid() {
    for mode in [LayoutMode.regular2, .regular3] {
      #expect(LayoutResolver.columnVisibility(for: mode) != .detailOnly)
    }
    #expect(LayoutResolver.columnVisibility(for: .regular3) == .all)
    #expect(LayoutResolver.columnVisibility(for: .regular2) == .doubleColumn)
  }

  @Test("The Regular-3 width pin matches the literal the UI test classifies layouts with")
  func theRegular3WidthPinMatchesTheUITestLiteral() {
    // `InspectorSlideOverUITests`, `Regular3CollapsedChromeUITests` and `InspectorSummaryUITests`
    // classify the layout from the measured window width. A UI-test bundle drives an installed
    // app rather than linking it, so it duplicates this pin as a literal; this is the join.
    #expect(LayoutResolver.regular3Threshold == 1197)
    #expect(LayoutResolver.resolve(width: 402, horizontalSizeClass: .compact) == .compact)
    #expect(LayoutResolver.resolve(width: 874, horizontalSizeClass: .compact) == .compact)
    #expect(LayoutResolver.resolve(width: 1032, horizontalSizeClass: .regular) == .regular2)
    #expect(LayoutResolver.resolve(width: 1376, horizontalSizeClass: .regular) == .regular3)
    // The trait, not the width, decides Compact/Regular: no width literal exists to join there.
    #expect(LayoutResolver.resolve(width: 874, horizontalSizeClass: .regular) == .regular2)
  }

  /// Replaces the retired panel's 40 %-of-pane rule: the system column takes a min/ideal/max
  /// request. The ceiling is the old panel's cap, so a Regular-2 window keeps the same grid width
  /// beside an open inspector that it had before.
  @Test("The inspector column's width request is ordered and keeps the old 360 pt ceiling")
  func theInspectorColumnWidthRequestIsOrdered() {
    #expect(InspectorColumnMetrics.minWidth > 0)
    #expect(InspectorColumnMetrics.minWidth <= InspectorColumnMetrics.idealWidth)
    #expect(InspectorColumnMetrics.idealWidth <= InspectorColumnMetrics.maxWidth)
    #expect(InspectorColumnMetrics.maxWidth == 360)
  }
}

/// IMGMGR-390 (owner decision on IMGMGR-338, comment 3731): **which surface carries the six host
/// chrome controls**, pinned as a value for the same reason `InspectorPlacement` is — the answer
/// is stated once and `GridView.toolbarContent` renders the statement, so a test can interrogate
/// the decision without driving a `@ViewBuilder`.
///
/// The owner's decision named the inspector's own bar as the expanded state's host. Two gate runs
/// (`37ac723` bar items, `b383b5a` a rendered row) measured that nothing in that column can be
/// tapped while it is expanded — `exists == true`, `isHittable == false`, hit point {-1, -1} —
/// because the retired prominent-detail split rendered the grid as a column overlaying a
/// non-interactive detail pane. So the grid's bar hosts the set in BOTH states — kept with the
/// system `.inspector` (WP28 P3) — and these tests pin that there is nowhere else to put them.
@Suite("Host chrome placement per layout mode (IMGMGR-390)")
struct WorkspaceChromePlacementTests {

  @Test("Every Regular width hands the controls to the grid's own bar")
  func everyRegularWidthHandsTheControlsToTheGridsOwnBar() {
    // Regular-3 collapsed — the launch state: the grid IS the wide detail column, so all six are
    // primary and directly hittable there. Expanded, the same bar belongs to the ~209 pt content
    // column and the OS folds three of the six into the overflow chevron: the deviation already
    // declared on IMGMGR-293, kept because the alternative column takes no taps at all.
    #expect(WorkspaceChromePlacement.host(for: .regular3) == .gridColumn)
    // Regular-2 is untouched by this story and asserted so it cannot drift with Regular-3.
    #expect(WorkspaceChromePlacement.host(for: .regular2) == .gridColumn)
  }

  @Test("Compact keeps its options row")
  func compactKeepsItsOptionsRow() {
    // Compact has no room beside Account and Info, so the five ride `GridOptionsRow` under the
    // bar — the shipped arrangement, named rather than folded into the Regular rule so it cannot
    // be swept into one.
    #expect(WorkspaceChromePlacement.host(for: .compact) == .compactOptionsRow)
  }

  @Test("Exactly one surface hosts the set at every width")
  func exactlyOneSurfaceHostsTheSetAtEveryWidth() {
    // The invariant the view depends on, stated over the WHOLE input space rather than left as a
    // property of conditions that happen to agree: every width answers exactly one host, so no
    // width can render the set twice or not at all.
    let hosts = [LayoutMode.compact, .regular2, .regular3].map {
      WorkspaceChromePlacement.host(for: $0)
    }
    #expect(hosts.count == 3)
    #expect(hosts.filter { $0 == .gridColumn }.count == 2)
    #expect(hosts.filter { $0 == .compactOptionsRow }.count == 1)
  }
}
