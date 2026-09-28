import Testing

@testable import ImgManager

/// WP28 P2 (IMGMGR-449): the grid bar's six controls as ONE declared group — exactly the six
/// shipped controls, nothing dropped, nothing duplicated, in the shipped order.
@Suite("ShellToolbarLayout — the grid bar's one declared group")
struct ShellToolbarLayoutTests {

  /// The shipped identifiers, as literals: `Regular3CollapsedChromeUITests.hostChromeIdentifiers`
  /// and `RegularSidebarShellUITests.barControlIdentifiers` duplicate them, because a UI-test
  /// bundle drives the app rather than linking it. This list is the join between the two.
  private static let shippedIdentifiers = [
    "inspectorChromeButton",
    "gridFilterControl",
    "gridSortControl",
    "gridGroupControl",
    "gridZoomControl",
    "gridShortcutHelpControl",
  ]

  @Test("At every Regular width the bar carries exactly the six shipped controls")
  func regularCarriesExactlyTheSix() {
    for mode in [LayoutMode.regular2, .regular3] {
      let bar = ShellToolbarLayout.gridBar(for: mode, inspectorUsesChromeControl: true)
      #expect(bar.count == 6, "The bar at \(mode) carries \(bar.count) controls")
      // Nothing duplicated: as many distinct members as members.
      #expect(Set(bar).count == bar.count)
      // Nothing dropped: every control the type knows is on the bar.
      #expect(Set(bar) == Set(ShellToolbarControl.allCases))
      #expect(bar.map(\.accessibilityIdentifier) == Self.shippedIdentifiers)
    }
  }

  @Test("The order is the shipped rendered order: Info, then Filter, Sort, Group, Zoom, ?")
  func orderIsTheShippedOrder() {
    // Info leads (the expanded Regular-3 escape hatch the trailing fold must never reach), and
    // Filter is the first of the five (WP16 P3, decision 1).
    #expect(
      ShellToolbarLayout.regularGridBar == [.info, .filter, .sort, .group, .zoom, .shortcutHelp])
    #expect(
      ShellToolbarLayout.gridBar(for: .regular3, inspectorUsesChromeControl: true)
        == ShellToolbarLayout.regularGridBar)
  }

  @Test("Compact carries Info alone on the bar; the five ride the options row")
  func compactCarriesInfoAlone() {
    #expect(ShellToolbarLayout.gridBar(for: .compact, inspectorUsesChromeControl: true) == [.info])
  }

  @Test("A presentation without the chrome control drops Info and nothing else")
  func withoutTheChromeControlOnlyInfoGoes() {
    for mode in [LayoutMode.compact, .regular2, .regular3] {
      let withInfo = ShellToolbarLayout.gridBar(for: mode, inspectorUsesChromeControl: true)
      let without = ShellToolbarLayout.gridBar(for: mode, inspectorUsesChromeControl: false)
      #expect(!without.contains(.info))
      #expect(without == withInfo.filter { $0 != .info })
    }
  }

  @Test("Every shipped presentation uses the chrome control, so Info is on every bar")
  func everyShippedBarCarriesInfo() {
    for mode in [LayoutMode.compact, .regular2, .regular3] {
      let presentation = InspectorPlacement.presentation(for: mode)
      let bar = ShellToolbarLayout.gridBar(
        for: mode, inspectorUsesChromeControl: presentation.usesChromeControl)
      #expect(bar.contains(.info), "Info is missing from the bar at \(mode)")
    }
  }

  @Test("The six identifiers are distinct and are the shipped ones")
  func identifiersAreTheShippedOnes() {
    let identifiers = ShellToolbarControl.allCases.map(\.accessibilityIdentifier)
    #expect(Set(identifiers).count == identifiers.count)
    #expect(Set(identifiers) == Set(Self.shippedIdentifiers))
  }

  @Test("The Regular sidebar's section names and identifiers")
  func sidebarSectionHeaders() {
    #expect(SidebarSectionHeader.allCases.map(\.title) == ["Shoots", "Library"])
    #expect(
      SidebarSectionHeader.allCases.map(\.identifier)
        == ["sidebarSectionShoots", "sidebarSectionLibrary"])
  }
}
