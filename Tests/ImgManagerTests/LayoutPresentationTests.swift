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

  @Test("Regular-3 still presents the permanent column")
  func regular3StillPresentsThePermanentColumn() {
    let presentation = InspectorPlacement.presentation(for: .regular3)
    #expect(presentation == .permanentColumn)
    #expect(presentation.isModal == false)
    // No chrome control at Regular-3: the inspector is never absent, so there is nothing to
    // open. This is the condition `RootView`'s toolbar reads.
    #expect(presentation.usesChromeControl == false)
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

  @Test("The Regular-3 width pin matches the literal the UI test classifies layouts with")
  func theRegular3WidthPinMatchesTheUITestLiteral() {
    // `InspectorSlideOverUITests` classifies the layout from the measured window width — an
    // input INDEPENDENT of the inspector presentation it is judging (diff-gate round 1, blocking
    // finding 1). A UI-test bundle drives an installed app rather than linking it, so it cannot
    // read this pin and duplicates it as a literal. This is the join: move the production pin
    // and this fails, naming the literal that has to move with it.
    #expect(LayoutResolver.regular3Threshold == 1197)
    // The two measured full-screen iPad anchors the UI test actually meets, replayed through the
    // production resolver so the duplicated literal is pinned to real behaviour, not just to a
    // number: 1032 pt portrait must classify Regular-2, 1376 pt landscape Regular-3.
    #expect(LayoutResolver.resolve(width: 1032, horizontalSizeClass: .regular) == .regular2)
    #expect(LayoutResolver.resolve(width: 1376, horizontalSizeClass: .regular) == .regular3)
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
