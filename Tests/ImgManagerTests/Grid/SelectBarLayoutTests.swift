import Foundation
import Testing

@testable import ImgManager

/// WP29 P4 (IMGMGR-455): the action bar's order in all four states, and the Select tiers' widths.
/// The bar renders `ActionBarLayout.controls`, so these are the orders a reader sees.
@MainActor
@Suite("Select bar — layout (WP29 P4)")
struct SelectBarLayoutTests {

  @Test("At rest: the shipped order with Tap to Pick beside Pick; Regular without More")
  func atRestTheOrderIsUnchanged() {
    #expect(
      SelectBarLayout.controls(selecting: false, carriesMore: false)
        == [.pick, .tapToPick, .dislike, .clear, .undo, .tag])
    #expect(
      SelectBarLayout.controls(selecting: false, carriesMore: true)
        == [.pick, .tapToPick, .dislike, .clear, .undo, .tag, .more])
    #expect(
      SelectBarLayout.controls(selecting: false, carriesMore: true, foldsClearIntoMore: true)
        == [.pick, .tapToPick, .dislike, .undo, .tag, .more])
  }

  /// IMGMGR-475: the toggle never folds (More holds six rows) and never rides the Select bar,
  /// where lock entry is disabled (pin e).
  @Test("Tap to Pick is on every at-rest tier and on no Select tier")
  func tapToPickIsAtRestOnly() {
    for carriesMore in [false, true] {
      let atRest = ActionBarMetrics.tiers(carriesMore: carriesMore, selecting: false)
      #expect(atRest.allSatisfy { $0.controls.contains(.tapToPick) })
      let selecting = ActionBarMetrics.tiers(carriesMore: carriesMore, selecting: true)
      #expect(selecting.allSatisfy { !$0.controls.contains(.tapToPick) })
    }
    // IMGMGR-542 (R3-22): seven since Collapse all joined View for the peek bands.
    #expect(GridMoreMenu.entries.count == 7)
  }

  @Test("Select: Regular is Pick · Dislike · Clear · Tag · Scene ‖ Undo; Compact adds More")
  func selectOrder() {
    #expect(
      SelectBarLayout.controls(selecting: true, carriesMore: false)
        == [.pick, .dislike, .clear, .tag, .scene, .spacer, .undo])
    #expect(
      SelectBarLayout.controls(selecting: true, carriesMore: true)
        == [.pick, .dislike, .clear, .tag, .scene, .more, .spacer, .undo])
    // The narrow tier still folds Clear into More — under the bar's own identifier, which is the
    // More menu's business (`GridMoreMenu.accessibilityIdentifier(for:foldsClearIntoMore:)`).
    #expect(
      SelectBarLayout.controls(selecting: true, carriesMore: true, foldsClearIntoMore: true)
        == [.pick, .dislike, .tag, .scene, .more, .spacer, .undo])
  }

  @Test("More is present in every Compact tier, at rest and in Select, and in no Regular tier")
  func moreIsPresentInEveryCompactTier() {
    for selecting in [false, true] {
      let compact = ActionBarMetrics.tiers(carriesMore: true, selecting: selecting)
      #expect(!compact.isEmpty)
      #expect(compact.allSatisfy { $0.controls.contains(.more) })
      let regular = ActionBarMetrics.tiers(carriesMore: false, selecting: selecting)
      #expect(!regular.isEmpty)
      #expect(regular.allSatisfy { !$0.controls.contains(.more) })
    }
    // Scene ▸ is a Select control only.
    #expect(ActionBarMetrics.tiers.allSatisfy { !$0.controls.contains(.scene) })
    #expect(ActionBarMetrics.selectTiers.allSatisfy { $0.controls.contains(.scene) })
  }

  @Test("Every tier's stored control count is its rendered control list, spacer excluded")
  func everyTiersCountIsItsList() {
    let all =
      ActionBarMetrics.tiers + ActionBarMetrics.regularTiers + ActionBarMetrics.selectTiers
      + ActionBarMetrics.regularSelectTiers
    for tier in all {
      #expect(
        tier.controlCount == tier.controls.filter { $0 != .spacer }.count, "tier \(tier.name)")
    }
    // Names are ForEach identities across whichever list renders — unique over all of them.
    #expect(Set(all.map(\.name)).count == all.count)
  }

  @Test("The tight Regular Select tier fits the measured 315-pt expanded-inspector column")
  func theTightRegularSelectTierFits315() {
    let tight = ActionBarMetrics.regularSelectTight
    #expect(tight.spacing == 4 && tight.horizontalPadding == 8)
    #expect(ActionBarMetrics.requiredWidth(for: tight) == 304)
    #expect(
      ActionBarMetrics.requiredWidth(for: tight) <= ActionBarMetrics.measuredRegular3GridColumn)
    let column = ActionBarMetrics.layout(
      forWidth: ActionBarMetrics.measuredRegular3GridColumn, carriesMore: false, selecting: true)
    #expect(column.name == "regular-select-tight")
    #expect(!column.foldsClearIntoMore)
    // Widest first, so ViewThatFits and `layout(forWidth:)` agree.
    let widths = ActionBarMetrics.regularSelectTiers.map(ActionBarMetrics.requiredWidth(for:))
    #expect(widths == [392, 304])
  }

  @Test("Compact Select fits the 402-pt iPhone without folding; the fold is the narrow tier")
  func compactSelectFitsTheIPhone() {
    let widths = ActionBarMetrics.selectTiers.map(ActionBarMetrics.requiredWidth(for:))
    #expect(widths == [452, 380, 328])
    let phone = ActionBarMetrics.layout(
      forWidth: ActionBarMetrics.narrowestCompactWidth, carriesMore: true, selecting: true)
    #expect(phone.name == "select-tight")
    #expect(!phone.foldsClearIntoMore)
    #expect(
      ActionBarMetrics.selectTiers.filter(\.foldsClearIntoMore).map(\.name) == ["select-folded"])
  }

  @Test("At-rest widths carry Tap to Pick and are unchanged by the spacer arithmetic")
  func atRestWidthsAreUnchanged() {
    #expect(
      ActionBarMetrics.tiers.map(ActionBarMetrics.requiredWidth(for:)) == [436, 372, 320, 300])
    #expect(
      ActionBarMetrics.regularTiers.map(ActionBarMetrics.requiredWidth(for:)) == [472, 376, 300])
  }

  /// IMGMGR-475 review round 1: the toggle's title shows only where its room is counted — the
  /// widest Regular tier — and the arithmetic charges exactly that room.
  @Test("Only the titled Regular tier shows Tap to Pick's title, and its width counts it")
  func toggleTitleOnlyWhereCounted() {
    let all =
      ActionBarMetrics.tiers + ActionBarMetrics.regularTiers + ActionBarMetrics.selectTiers
      + ActionBarMetrics.regularSelectTiers
    let titled = all.filter { $0.showsToggleTitle }.map { $0.name }
    #expect(titled == ["regular-titled"])
    let titledWidth = ActionBarMetrics.requiredWidth(for: ActionBarMetrics.regularTitled)
    let roomyWidth = ActionBarMetrics.requiredWidth(for: ActionBarMetrics.regularRoomy)
    #expect(titledWidth - roomyWidth == ActionBarMetrics.toggleTitleAllowance)
    #expect(ActionBarMetrics.regularTitled.controls == ActionBarMetrics.regularRoomy.controls)
    // The measured 315-pt expanded column still takes the icon-only tight tier.
    let column = ActionBarMetrics.layout(
      forWidth: ActionBarMetrics.measuredRegular3GridColumn, carriesMore: false)
    #expect(!column.showsToggleTitle)
  }
}
