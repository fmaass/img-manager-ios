import ImgManagerAPI
import SwiftUI
import Testing

@testable import ImgManager

/// WP28 P2 (IMGMGR-449) + WP29 P1 (IMGMGR-452): the grid bar as ONE declared list — the spec's
/// trailing group in p4128's order, nothing dropped, nothing on two surfaces.
@MainActor
@Suite("ShellToolbarLayout — the grid bar's one declared group")
struct ShellToolbarLayoutTests {

  /// The shipped identifiers of the Regular bar's app items, in order, as literals:
  /// `GridToolbarUITests`, `Regular3CollapsedChromeUITests` and `InspectorSummaryUITests` spell
  /// them too, because a UI-test bundle drives the app rather than linking it. The system search
  /// carries none of the app's.
  private static let regularIdentifiers = [
    "inspectorChromeButton",
    "gridSelectCommand",
    "gridFilterControl",
    "gridArrangeControl",
    "gridMoreMenu",
  ]

  @Test("Regular: Info, then Search · Select · Filter · Arrange · More, in that order")
  func regularOrderIsTheSpecOrder() {
    #expect(
      ShellToolbarLayout.regularGridBar == [
        .info, .search, .select, .filter, .arrange, .more,
      ])
    for mode in [LayoutMode.regular2, .regular3] {
      let bar = ShellToolbarLayout.gridBar(for: mode, inspectorUsesChromeControl: true)
      #expect(bar == ShellToolbarLayout.regularGridBar, "The bar at \(mode) is \(bar)")
      #expect(Set(bar).count == bar.count, "A control is on the bar twice at \(mode)")
      #expect(bar.compactMap(\.accessibilityIdentifier) == Self.regularIdentifiers)
    }
  }

  /// IMGMGR-462 (WP31 P3): the bar is back to its pre-WP31 members — with Triage leading it, a
  /// long title pushed all three controls into iOS 26's "More" overflow — and Triage rides the
  /// options row, which is content and never overflows. IMGMGR-464 (WP32 P2): "?" left the row.
  @Test("Compact: Info and Select on the bar; the options row is Arrange · Filter · Triage")
  func compactCarriesInfoAndSelect() {
    #expect(
      ShellToolbarLayout.gridBar(for: .compact, inspectorUsesChromeControl: true)
        == [.info, .select])
    #expect(ShellToolbarLayout.compactOptionsRow == [.arrange, .filter, .triage])
  }

  /// IMGMGR-464 (WP32 P2): owner ruling 2026-10-02, "remove the visible help control at
  /// Compact". WP29 P1 had already taken it off the Regular bar, so its shipped identifier is now
  /// on no bar and no options row at either width. The sheet's two remaining entry points (⌘/
  /// and its silent `?` twin) are `ShortcutHelpEntryPointsTests`'.
  @Test("The keyboard-glyph help control is on no bar and no options row, at either width")
  func shortcutHelpControlIsOnNoSurface() {
    let removed = "gridShortcutHelpControl"
    func carriesTheHelpControl(_ identifiers: [String]) -> Bool {
      identifiers.contains(removed)
    }
    for mode in [LayoutMode.compact, .regular2, .regular3] {
      let bar = ShellToolbarLayout.gridBar(for: mode, inspectorUsesChromeControl: true)
      let row: [ShellToolbarControl] =
        WorkspaceChromePlacement.host(for: mode) == .compactOptionsRow
        ? ShellToolbarLayout.compactOptionsRow : []
      let ids = (bar + row).compactMap(\.accessibilityIdentifier)
      #expect(!carriesTheHelpControl(ids), "The help control is on a surface at \(mode): \(ids)")
      // Positive controls: the surfaces really were enumerated (the funnel rides both widths),
      // and the predicate fails a surface that still carries the control.
      #expect(ids.contains("gridFilterControl"), "No surface was enumerated at \(mode): \(ids)")
      #expect(carriesTheHelpControl(ids + [removed]))
    }
    let everyIdentifier = ShellToolbarControl.allCases.compactMap(\.accessibilityIdentifier)
    #expect(!carriesTheHelpControl(everyIdentifier), "A control still ships the help identifier")
  }

  @Test("Select has one touch home per width: the bar, never the More menu")
  func selectHasOneTouchHomePerWidth() {
    for mode in [LayoutMode.compact, .regular2, .regular3] {
      let bar = ShellToolbarLayout.gridBar(for: mode, inspectorUsesChromeControl: true)
      #expect(bar.filter { $0 == .select }.count == 1, "Select is not on the bar at \(mode)")
    }
    #expect(!ShellToolbarLayout.compactOptionsRow.contains(.select))
    #expect(!GridMoreMenu.entries.contains { $0.accessibilityIdentifier == "gridSelectCommand" })
    #expect(
      ShellToolbarControl.select.accessibilityIdentifier
        == GridSelectCommand.accessibilityIdentifier)
  }

  @Test("More is on exactly one surface per width: the bar at Regular, the action bar at Compact")
  func moreHasOneHomePerWidth() {
    for mode in [LayoutMode.compact, .regular2, .regular3] {
      let onBar = ShellToolbarLayout.gridBar(for: mode, inspectorUsesChromeControl: true)
        .contains(.more)
      let onActionBar = WorkspaceChromePlacement.actionBarCarriesMore(for: mode)
      #expect(onBar != onActionBar, "More at \(mode): bar=\(onBar) actionBar=\(onActionBar)")
    }
    #expect(WorkspaceChromePlacement.actionBarCarriesMore(for: .compact))
  }

  @Test("No identifier appears twice across the bar, the options row and the More menu")
  func noIdentifierTwiceAcrossTheSurfaces() {
    for mode in [LayoutMode.compact, .regular2, .regular3] {
      let bar = ShellToolbarLayout.gridBar(for: mode, inspectorUsesChromeControl: true)
      let row: [ShellToolbarControl] =
        WorkspaceChromePlacement.host(for: mode) == .compactOptionsRow
        ? ShellToolbarLayout.compactOptionsRow : []
      let ids =
        (bar + row).compactMap(\.accessibilityIdentifier)
        + GridMoreMenu.entries.map(\.accessibilityIdentifier)
      #expect(Set(ids).count == ids.count, "Duplicated identifier at \(mode): \(ids)")
      // Positive control: the three surfaces really were enumerated.
      #expect(ids.contains("gridMoreMenu.more.clearMark"))
      #expect(ids.contains("inspectorChromeButton"))
    }
  }

  @Test("Every control the type knows has a home at some width")
  func nothingDropped() {
    let homes = Set(
      ShellToolbarLayout.regularGridBar + ShellToolbarLayout.compactGridBar
        + ShellToolbarLayout.compactOptionsRow)
    #expect(homes == Set(ShellToolbarControl.allCases))
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
      // Info leads every bar (the IMGMGR-390 fold argument); IMGMGR-462 took Triage, which led
      // the Compact bar under WP31 P1, off the bar altogether.
      #expect(bar.first == .info, "Info does not lead the bar at \(mode)")
      #expect(bar.contains(.info), "Info is not on the bar at \(mode)")
    }
  }

  /// IMGMGR-462 (WP31 P3): the options row is mounted only at Compact
  /// (`GridChromeRows.rows`), so its membership plus "on no bar" is "Compact only".
  @Test("Triage has one home: the Compact options row, enabled only with a photograph in scope")
  func triageIsCompactOnly() {
    let store = GridStore(
      service: GridService(client: ImgManagerAPIClient.make(transport: GridStubTransport())))
    for mode in [LayoutMode.compact, .regular2, .regular3] {
      let bar = ShellToolbarLayout.gridBar(for: mode, inspectorUsesChromeControl: true)
      #expect(!bar.contains(.triage), "Triage is on the bar at \(mode)")
      let rows = GridChromeRows.rows(layoutMode: mode, store: store)
      #expect(rows.contains(.options) == (mode == .compact), "Options row presence at \(mode)")
    }
    #expect(!ShellToolbarLayout.regularGridBar.contains(.triage))
    #expect(ShellToolbarLayout.compactOptionsRow.filter { $0 == .triage }.count == 1)
    #expect(ShellToolbarControl.triage.accessibilityIdentifier == "gridTriageButton")
    #expect(store.canOpenTriage == false)
    store.openTriage()
    #expect(store.isTriagePresented == false, "Triage opened on an empty scope")
  }

  @Test("The identifiers are distinct and are the shipped ones; search has none of the app's")
  func identifiersAreTheShippedOnes() {
    let identifiers = ShellToolbarControl.allCases.compactMap(\.accessibilityIdentifier)
    #expect(Set(identifiers).count == identifiers.count)
    #expect(
      Set(identifiers)
        == Set(Self.regularIdentifiers + ["gridTriageButton"]))
    #expect(ShellToolbarControl.search.accessibilityIdentifier == nil)
  }

  @Test("The rendered order is the declared order; only the search item leaves the groups")
  func renderedOrderIsTheDeclaredOrder() {
    for mode in [LayoutMode.compact, .regular2, .regular3] {
      for chrome in [true, false] {
        let bar = ShellToolbarLayout.gridBar(for: mode, inspectorUsesChromeControl: chrome)
        let runs = ShellToolbarRuns(bar)
        #expect(runs.flattened == bar, "At \(mode) the bar renders \(runs.flattened), not \(bar)")
        let grouped = runs.leading + runs.trailing
        #expect(!grouped.contains(.search), "The search item rides a group at \(mode)")
      }
    }
    let regular = ShellToolbarRuns(ShellToolbarLayout.regularGridBar)
    #expect(regular.leading == [.info])
    #expect(regular.search)
    #expect(regular.trailing == [.select, .filter, .arrange, .more])
    #expect(ShellToolbarRuns([]).flattened == [])
    #expect(ShellToolbarRuns([.info, .select]).trailing == [])
  }

  @Test("The Regular sidebar's section names and identifiers")
  func sidebarSectionHeaders() {
    #expect(SidebarSectionHeader.allCases.map(\.title) == ["Shoots", "Library"])
    #expect(
      SidebarSectionHeader.allCases.map(\.identifier)
        == ["sidebarSectionShoots", "sidebarSectionLibrary"])
  }
}
