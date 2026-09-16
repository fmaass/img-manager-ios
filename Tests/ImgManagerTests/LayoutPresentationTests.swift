import SwiftUI
import Testing

@testable import ImgManager

/// WP13 P10 (IMGMGR-219): the inspector's PRESENTATION per layout mode, pinned as values.
/// `InspectorPlacement.presentation(for:)` is the production decision itself — `RootView`'s
/// toolbar condition, sheet binding and slide-over overlay all read it — so these assertions are
/// about the shipped behaviour, not a re-implementation of it (same discipline as
/// `LayoutModeTests`/`SidebarRoutingTests`).
///
/// The phase reverses a documented WP8 P4 simplification (the modal sheet at Regular-2) on the
/// authority of design round [/link/3220] §2.2; `compactStillPresentsTheSheet` and
/// `regular3StillPresentsThePermanentColumn` are the pins that keep the reversal scoped to the
/// one width it is meant for.
@Suite("Inspector presentation per layout mode (WP13 P10)")
struct LayoutPresentationTests {

  @Test("Regular-2 presents the inspector as a non-modal panel, never a sheet")
  func regular2PresentsTheInspectorAsANonModalPanel() {
    let presentation = InspectorPlacement.presentation(for: .regular2)
    #expect(presentation == .slideOver)
    // The load-bearing half: a slide-over that still blocked the grid would be the sheet with a
    // different animation. Non-modality is what [/link/3220] §2.2 asked for and what the
    // matching UI test observes on a real simulator (the grid stays hittable beside the panel).
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

  /// WP16 P2 (IMGMGR-298, design record [/link/3332] decision 4) REVERSES this test's third
  /// assertion, and only that one. Regular-3 keeps the permanent-column PRESENTATION — the
  /// inspector is still a real third column and still non-modal — but it stops being permanent
  /// in the sense of unavoidable: the reader hides and restores it from the same persistent
  /// chrome control Compact and Regular-2 already use, so `usesChromeControl` is now true at
  /// every width. The old `== false` was the pinned contract at 4753450 and is the RED this
  /// phase observed first (its UI twin is `InspectorSlideOverUITests`' `.regular3` branch).
  @Test("Regular-3 keeps the permanent column, and now reaches it from chrome too")
  func regular3StillPresentsThePermanentColumn() {
    let presentation = InspectorPlacement.presentation(for: .regular3)
    #expect(presentation == .permanentColumn)
    #expect(presentation.isModal == false)
    // Decision 4: the column is collapsible here as well, so there IS something for a chrome
    // control to do — this is the condition `RootView`'s toolbar reads (`RootView.swift:422`).
    #expect(presentation.usesChromeControl)
  }

  /// The other half of the reversal, stated as its own pin: decision 4 changes Regular-3 and
  /// NOTHING else. A change that also flipped Compact's modality or Regular-2's placement would
  /// pass the test above and fail here, which is why the two are separate.
  @Test("Decision 4 changes Regular-3 only — Compact's sheet and Regular-2's slide-over stand")
  func decisionFourLeavesTheOtherTwoPresentationsAlone() {
    #expect(InspectorPlacement.presentation(for: .compact) == .sheet)
    #expect(InspectorPlacement.presentation(for: .compact).isModal)
    #expect(InspectorPlacement.presentation(for: .regular2) == .slideOver)
    #expect(InspectorPlacement.presentation(for: .regular2).isModal == false)
    // And the resolver still answers three different presentations — a `usesChromeControl` that
    // is now true everywhere must not have been "simplified" by collapsing the enum itself.
    #expect(
      InspectorPlacement.presentation(for: .compact)
        != InspectorPlacement.presentation(for: .regular2))
    #expect(
      InspectorPlacement.presentation(for: .regular2)
        != InspectorPlacement.presentation(for: .regular3))
  }

  /// Scope, stated because a diff-gate round-1 finding was that this test's name overclaimed:
  /// this pins the STRINGS and the fact that a chrome control exists at both non-permanent
  /// widths. It does NOT prove `RootView`'s button consumes them — no unit test can render that
  /// button. That proof lives in `InspectorSlideOverUITests`
  /// .assertTheChromeControlReportsTheActiveFilterCount, which drives a real facet filter and
  /// reads the shipped control's own accessibility label.
  @Test("The Info control still carries the active filter count")
  func theInfoControlStillCarriesTheActiveFilterCount() {
    // The indicator's whole point is that it rides the control that OPENS the inspector — so it
    // must survive at both widths where that control exists, sheet and slide-over alike.
    #expect(InspectorPlacement.presentation(for: .compact).usesChromeControl)
    #expect(InspectorPlacement.presentation(for: .regular2).usesChromeControl)

    var query = GridImagesQuery(folderID: 7)
    query.mark = "pick"
    query.ratingMin = 4
    // The shoot scope is deliberately NOT counted — browsing one folder must not read as
    // "filtered" (see `InspectorFacetFilters`); `InspectorModelTests` owns that rule's own
    // exhaustive coverage. Repeated here only as the input to the button's rendered strings.
    #expect(InspectorFacetFilters.activeCount(query) == 2)
    #expect(InspectorFacetFilters.infoButtonTitle(activeCount: 2) == "Info · 2")
    #expect(
      InspectorFacetFilters.infoButtonAccessibilityLabel(activeCount: 2)
        == "Info, 2 filters active")
  }

  /// WP16 P2 (IMGMGR-298): the collapse MECHANISM, pinned as a value because the gate proved the
  /// obvious implementation is a no-op. Rendering an `EmptyView` into the third column left the
  /// grid exactly where it was (`actionBarMidX before=104.5 after=104.5`, 1376 pt window): a
  /// `NavigationSplitView` reserves its columns by initializer arity, so the collapsed state has
  /// to render the two-column shape instead — and then this function says which of ITS panes the
  /// workspace wants.
  ///
  /// **RE-SPECIFIED by IMGMGR-390.** WP16 P2 answered `.detailOnly` and this test pinned it, on
  /// the reading that [/link/3220] keeps the sidebar off at Regular-3. The owner's decision on
  /// IMGMGR-338 (comment 3731) is the opposite trade and is the REASON the inspector starts
  /// collapsed: "so the sidebar/queue stays visible". `.doubleColumn` is that sentence as a
  /// value — and it is why the default flip and this answer are one change, not two: flipping the
  /// default while this still answered `.detailOnly` would have launched the workspace with the
  /// queue gone, which is what the premise gate caught before any code was written.
  @Test("The collapsed Regular-3 workspace keeps the sidebar beside the grid")
  func theCollapsedRegular3WorkspaceAsksForTheSidebarBesideTheGrid() {
    // Shown: unchanged from what ships — the three-column request.
    #expect(
      InspectorPlacement.columnVisibility(for: .regular3, regular3InspectorShown: true) == .all)
    // Collapsed: TWO panes, sidebar + grid. `.detailOnly` (what WP16 P2 shipped) renders the grid
    // alone and is the exact behaviour IMGMGR-390 reverses; `.all` is what the no-op EmptyView
    // build was still asking for.
    #expect(
      InspectorPlacement.columnVisibility(for: .regular3, regular3InspectorShown: false)
        == .doubleColumn)
    // The flag is a REGULAR-3 fact only: it must not reach a width whose inspector is a sheet or
    // a slide-over, where the visibility is the resolver's own answer. Both values, so a rule
    // written as "collapsed -> doubleColumn" everywhere would still have to agree with
    // `LayoutResolver` here rather than by coincidence.
    for shown in [true, false] {
      #expect(
        InspectorPlacement.columnVisibility(for: .compact, regular3InspectorShown: shown)
          == LayoutResolver.columnVisibility(for: .compact))
      #expect(
        InspectorPlacement.columnVisibility(for: .regular2, regular3InspectorShown: shown)
          == LayoutResolver.columnVisibility(for: .regular2))
    }
  }

  @Test("The Regular-3 width pin matches the literal the UI test classifies layouts with")
  func theRegular3WidthPinMatchesTheUITestLiteral() {
    // `InspectorSlideOverUITests` classifies the layout from the measured window width — an
    // input INDEPENDENT of the inspector presentation it is judging (diff-gate round 1, blocking
    // finding 1). A UI-test bundle drives an installed app rather than linking it, so it cannot
    // read this pin and duplicates it as a literal. This is the join: move the production pin
    // and this fails, naming the literal that has to move with it.
    #expect(LayoutResolver.regular3Threshold == 1197)
    // 1197 is the ONLY literal the UI test duplicates: it splits Regular-2 from Regular-3 by
    // width. It does NOT duplicate a Compact/Regular width, because there is no correct one to
    // duplicate — see this file's note below — so it reads the rendered column count instead.
    //
    // All four anchors the UI test actually meets on the gate's two destinations, replayed
    // through the production resolver so the duplicated pin is joined to real behaviour rather
    // than to a bare number. Widths and traits are the live P10 probe's own readings.
    #expect(LayoutResolver.resolve(width: 402, horizontalSizeClass: .compact) == .compact)
    #expect(LayoutResolver.resolve(width: 874, horizontalSizeClass: .compact) == .compact)
    #expect(LayoutResolver.resolve(width: 1032, horizontalSizeClass: .regular) == .regular2)
    #expect(LayoutResolver.resolve(width: 1376, horizontalSizeClass: .regular) == .regular3)
    // Why no Compact/Regular width literal exists to join: 874 pt is Compact (iPhone landscape)
    // while a windowed iPad is Regular well below it — the trait, not the width, decides. A UI
    // test that guessed a floor between 874 and 1032 would misclassify every iPad half-window.
    #expect(LayoutResolver.resolve(width: 874, horizontalSizeClass: .regular) == .regular2)
  }

  @Test("The slide-over is width-limited: 40 % of the pane, capped at 360 pt")
  func slideOverWidthIsProportionalUntilItHitsTheCap() {
    // Below the cap the panel is a fraction of the pane it overlays, so a half-width iPad window
    // keeps a usable grid beside it...
    #expect(InspectorSlideOverMetrics.width(inPane: 600) == 240)
    #expect(InspectorSlideOverMetrics.width(inPane: 500) == 200)
    // ...and above it the panel stops growing rather than eating a wide pane.
    #expect(InspectorSlideOverMetrics.width(inPane: 900) == 360)
    #expect(InspectorSlideOverMetrics.width(inPane: 1032) == 360)
    // The exact crossover, so a changed cap or fraction cannot pass unnoticed.
    #expect(InspectorSlideOverMetrics.width(inPane: 900) == InspectorSlideOverMetrics.maxWidth)
    // A pane with no width yet (the first layout pass) must not produce a negative frame.
    #expect(InspectorSlideOverMetrics.width(inPane: 0) == 0)
    #expect(InspectorSlideOverMetrics.width(inPane: -50) == 0)
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
/// because `.prominentDetail` with `columnVisibility == .all` renders the grid as a column
/// overlaying a non-interactive detail pane. So the grid's bar hosts the set in BOTH states, the
/// enum has no third case, and these tests pin that there is nowhere else to put them.
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
