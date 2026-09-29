import Foundation
import Testing

@testable import ImgManager

/// WP29 P4 (IMGMGR-455): the action bar's order in all four states, and the Select tiers' widths.
/// The bar renders `ActionBarLayout.controls`, so these are the orders a reader sees.
@MainActor
@Suite("Select bar — layout (WP29 P4)")
struct SelectBarLayoutTests {

  @Test("At rest the order is the shipped one: Regular without More, Compact with it")
  func atRestTheOrderIsUnchanged() {
    #expect(
      SelectBarLayout.controls(selecting: false, carriesMore: false)
        == [.pick, .dislike, .clear, .undo, .tag])
    #expect(
      SelectBarLayout.controls(selecting: false, carriesMore: true)
        == [.pick, .dislike, .clear, .undo, .tag, .more])
    #expect(
      SelectBarLayout.controls(selecting: false, carriesMore: true, foldsClearIntoMore: true)
        == [.pick, .dislike, .undo, .tag, .more])
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

  @Test("At-rest widths are unchanged by the spacer arithmetic")
  func atRestWidthsAreUnchanged() {
    #expect(ActionBarMetrics.tiers.map(ActionBarMetrics.requiredWidth(for:)) == [376, 320, 268])
    #expect(ActionBarMetrics.regularTiers.map(ActionBarMetrics.requiredWidth(for:)) == [316, 268])
  }
}
