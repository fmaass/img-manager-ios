import UIKit
import XCTest

/// WP28 P3 (IMGMGR-450), plan Phase 3 cases (a)-(f): the system `.inspector` toggled by Info, and
/// the Shoot Summary sheet opened from the grid's title menu.
///
/// Each case has its own test. A case whose layout this destination cannot resolve throws
/// `XCTSkip` with the measured window — it never returns as a pass. Layout is read from the
/// measured window width only (the Regular-3 pin, and the Compact tab shell's ceiling), never
/// from a device idiom.
///
/// Launch fixture: `-UITestStubGrid` (DEBUG-only `DebugStubTransport`), whose auto-select opens
/// folder 1 (`2026-08-27 — Stub Shoot`; server summary 40 total, 10 picked, 2 disliked,
/// 28 unmarked, `nothing_left_unmarked == false`). `-UITestSelectFolder <id>` opens folder 3
/// (`nothing_left_unmarked == true`, 12 total) or folder 4 (`template`, no summary at all).
final class InspectorSummaryUITests: OrientationPinnedUITestCase {

  private enum Layout: String {
    case compact
    case regular2
    case regular3
  }

  /// Mirrors `LayoutResolver.regular3Threshold`; `LayoutPresentationTests` is the join.
  private static let regular3WidthThreshold: CGFloat = 1197

  /// The six host chrome controls (IMGMGR-338): the five grid view options and Info.
  private static let hostChromeIdentifiers = [
    "inspectorChromeButton",
    "gridFilterControl",
    "gridSortControl",
    "gridGroupControl",
    "gridZoomControl",
    "gridShortcutHelpControl",
  ]

  private static let folderOneName = "2026-08-27 — Stub Shoot"
  /// `WorkspaceTitle.name`'s second source for folder 1 — `NeedsReview.shootName(for:)`, the
  /// leaf of the fixture summary's path, which is also what the Shoots tab's row shows. Compact
  /// resolves to it because the tree loads only when the Library tab mounts, and the DEBUG
  /// auto-select pushes the grid on Shoots (gate on 0d2d057: the iPhone bar's identifier is
  /// 'stub'). Regular shows the sidebar, so the tree has loaded and the first source wins.
  private static let folderOneSummaryName = "stub"

  // MARK: - (a) Regular-3

  /// (a), first half: collapsed at launch, Info opens it, a Stats facet row applies its filter
  /// (the Info control's filter count changes), Info closes it, the sidebar is shown throughout,
  /// and all six chrome controls are directly hittable in the COLLAPSED state.
  func testA1Regular3InfoTogglesTheInspectorAndAStatsRowFiltersTheGrid() throws {
    let app = launch(orientation: .landscapeLeft)
    try require(.regular3, in: app, context: "(a1)")

    let stats = app.buttons["Stats"]
    XCTAssertFalse(
      stats.exists,
      "Regular-3 launched with the inspector expanded; IMGMGR-390 launches it collapsed.")
    XCTAssertTrue(
      app.buttons["Dislike"].isHittable,
      "Positive control: the grid's action bar is not hittable, so the absence above is vacuous.")
    assertSidebarShown(in: app, state: "collapsed at launch")
    assertAllSixHittable(in: app, state: "collapsed at launch")

    let info = infoControl(app)
    XCTAssertEqual(info.label, "Info", "A filter is already active at launch.")
    info.tap()
    XCTAssertTrue(stats.waitForExistence(timeout: 10), "Info did not open the inspector.")
    assertSidebarShown(in: app, state: "expanded")
    attach(app, named: "IMGMGR-450-a-regular3-expanded")

    applyTheStubsPickFacet(in: app, info: info)
    assertSidebarShown(in: app, state: "expanded and filtered")

    info.tap()
    XCTAssertTrue(
      stats.waitForNonExistence(timeout: 10), "A second Info tap left the inspector open.")
    assertSidebarShown(in: app, state: "collapsed again")
    assertAllSixHittable(in: app, state: "collapsed after the round trip")
  }

  /// (a), second half, EXPANDED with the toolbar search minimised: every one of the six is
  /// REACHABLE — hittable on the bar, or hittable inside the bar's overflow menu. Nothing is
  /// dropped (the chrome-twin rule).
  ///
  /// The plan's stronger target is "all six hittable in BOTH states"; the expanded half of that
  /// is IMGMGR-427's budget gap and is recorded by the census this test prints, not asserted
  /// here. What IS asserted is the floor that must never break: a control the OS folded is
  /// still one tap into the overflow away. The sidebar is asserted in both states (plan: "the
  /// sidebar is still shown throughout"); the relaxation covers the six controls only.
  func testA2Regular3ExpandedKeepsAllSixReachableDirectlyOrThroughOverflow() throws {
    let app = launch(orientation: .landscapeLeft)
    try require(.regular3, in: app, context: "(a2)")

    assertSidebarShown(in: app, state: "Regular-3 collapsed at launch")
    assertAllSixHittable(in: app, state: "Regular-3 collapsed at launch")
    let labels = hostChromeLabels(in: app, state: "collapsed at launch")
    infoControl(app).tap()
    XCTAssertTrue(
      app.buttons["Stats"].waitForExistence(timeout: 10), "Info did not open the inspector.")
    XCTAssertFalse(
      app.searchFields.firstMatch.exists,
      "The toolbar search is expanded; this case reads the bar with search minimised.")
    assertSidebarShown(in: app, state: "Regular-3 expanded")
    recordChromeCensus(in: app, state: "regular3 expanded")
    attach(app, named: "IMGMGR-450-a-regular3-expanded-bar")
    // Ruling R6 (orchestrator, IMGMGR-450): at Regular-3 EXPANDED the six need only be
    // REACHABLE — P2's gate measured the grid column at ~465/2000 px with four controls folded
    // into the overflow (IMGMGR-427 owns closing that gap).
    assertAllSixReachable(in: app, labels: labels, state: "Regular-3 expanded", ruling: "R6")
  }

  // MARK: - (b) Regular-2

  /// (b): with the inspector CLOSED all six are directly hittable (no overflow allowance); open →
  /// tap a Stats row → the grid responds → a grid cell is hittable while the inspector is open,
  /// every control reachable (ruling R6b) → Info closes it and all six are hittable again.
  /// The known unknown: if the system column overlays the grid or renders non-interactive here,
  /// the tile assertion fails, and AC4's Regular-2 clause is reported UNRESOLVED rather than
  /// satisfied by the retired overlay.
  func testBRegular2InspectorOpensBesideAHittableGridAndAStatsRowFilters() throws {
    let app = launch(orientation: .portrait)
    try require(.regular2, in: app, context: "(b)")

    let stats = app.buttons["Stats"]
    XCTAssertFalse(stats.exists, "Regular-2 launched with the inspector open.")
    assertAllSixHittable(in: app, state: "Regular-2 collapsed")
    let labels = hostChromeLabels(in: app, state: "Regular-2 collapsed")

    let info = infoControl(app)
    info.tap()
    XCTAssertTrue(stats.waitForExistence(timeout: 10), "Info did not open the inspector.")
    attach(app, named: "IMGMGR-450-b-regular2-expanded")
    applyTheStubsPickFacet(in: app, info: info)

    XCTAssertNotNil(
      firstHittableTile(in: app),
      "No grid cell is hittable while the Regular-2 inspector is open — the system column "
        + "overlays or disables the grid (AC4 Regular-2 clause: report UNRESOLVED, never restore "
        + "the old overlay).")
    XCTAssertTrue(
      app.buttons["Dislike"].isHittable,
      "The grid's action bar stopped taking taps beside the open inspector.")
    // The census logs how many of the six are DIRECTLY hittable here and whether the sidebar is
    // shown — evidence of the true number; neither is asserted in this state.
    recordChromeCensus(in: app, state: "regular2 expanded")
    // Ruling R6b (orchestrator, IMGMGR-450, extending R6): with the inspector OPEN at Regular-2
    // the six need only be REACHABLE. P2 measured the Regular-3 expanded grid column at
    // ~465/2000 px with four controls folded; the Regular-2 grid column beside the inspector is
    // narrower still, so the same fold is expected here.
    assertAllSixReachable(in: app, labels: labels, state: "Regular-2 inspector open", ruling: "R6b")

    info.tap()
    XCTAssertTrue(
      stats.waitForNonExistence(timeout: 10), "A second Info tap left the inspector open.")
    assertAllSixHittable(in: app, state: "Regular-2 closed after the round trip")
  }

  // MARK: - (c) Compact

  /// (c): Info presents the inspector as a (modal) sheet, a Stats row is hittable in it, and the
  /// sheet's own drag dismisses it.
  func testCCompactInfoPresentsTheInspectorAsASheetWithAHittableStatsRow() throws {
    let app = launch(orientation: .portrait)
    try require(.compact, in: app, context: "(c)")

    let stats = app.buttons["Stats"]
    let dislike = app.buttons["Dislike"]
    XCTAssertFalse(stats.exists, "Compact launched with the inspector up.")
    infoControl(app).tap()
    XCTAssertTrue(stats.waitForExistence(timeout: 10), "Info did not present the inspector.")
    XCTAssertFalse(
      dislike.isHittable, "At Compact the inspector is a sheet over the grid, not beside it.")

    stats.tap()
    let markRow = pickFacetRow(in: app)
    XCTAssertTrue(
      markRow.waitForExistence(timeout: 10), "The sheet's Stats section has no 'pick' row.")
    XCTAssertTrue(markRow.isHittable, "The Stats row is in the sheet but cannot be tapped.")
    attach(app, named: "IMGMGR-450-c-compact-sheet")

    // The sheet's own dismissal: a drag from just above the segment control to the bottom edge.
    let start = stats.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .withOffset(CGVector(dx: 0, dy: -40))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
    start.press(forDuration: 0.1, thenDragTo: end)
    XCTAssertTrue(
      stats.waitForNonExistence(timeout: 10), "Dragging the sheet down did not dismiss it.")
    XCTAssertTrue(dislike.waitForExistence(timeout: 5) && dislike.isHittable)
  }

  // MARK: - (d) and (e) Summary

  /// (d): the title shows the fixture folder's name, its menu row opens a sheet narrower than the
  /// window and centred in it (form sizing), with the server's counts.
  func testDSummaryOnRegularIsACentredFormSheetWithTheServerCounts() throws {
    let app = launch(orientation: .landscapeLeft)
    let layout = self.layout(of: app)
    guard layout != .compact else {
      throw XCTSkip(
        "IMGMGR-450 (d): window=\(app.windows.firstMatch.frame.size) resolves to compact; "
          + "(d) is Regular.")
    }

    let sheetBar = openShootSummary(in: app, titleNames: [Self.folderOneName])
    let window = app.windows.firstMatch.frame
    let sheet = sheetBar.frame
    print("IMGMGR-450-SUMMARY-FORM \(layout.rawValue): window=\(window) sheetBar=\(sheet)")
    attach(app, named: "IMGMGR-450-d-summary-form-sheet")
    XCTAssertLessThan(
      sheet.width, window.width * 0.9,
      "The Summary sheet spans the window; form sizing presents it narrower and centred.")
    XCTAssertEqual(
      sheet.midX, window.midX, accuracy: window.width * 0.02,
      "The Summary sheet is not centred in the window.")
    assertCounts(in: app, total: "40", picked: "10", disliked: "2", unmarked: "28")
    closeShootSummary(in: app, sheetBar: sheetBar)
  }

  /// (e): on the pinned-portrait iPhone the sheet rests at the medium detent — 40-60 % of the
  /// window's height — with the same counts.
  func testESummaryOnCompactIsAMediumDetentSheetWithTheServerCounts() throws {
    let app = launch(orientation: .portrait)
    try require(.compact, in: app, context: "(e)")

    let sheetBar = openShootSummary(
      in: app, titleNames: [Self.folderOneName, Self.folderOneSummaryName])
    let window = app.windows.firstMatch.frame
    let height = window.maxY - sheetBar.frame.minY
    let fraction = height / window.height
    print("IMGMGR-450-SUMMARY-DETENT: window=\(window) sheetBar=\(sheetBar.frame) f=\(fraction)")
    attach(app, named: "IMGMGR-450-e-summary-medium-detent")
    XCTAssertGreaterThanOrEqual(fraction, 0.4, "The Summary sheet is shorter than medium.")
    XCTAssertLessThanOrEqual(fraction, 0.6, "The Summary sheet is taller than medium.")
    assertCounts(in: app, total: "40", picked: "10", disliked: "2", unmarked: "28")
    closeShootSummary(in: app, sheetBar: sheetBar)
  }

  // MARK: - (f) The banner and the no-summary case

  /// (f), folder 1: the server says `nothing_left_unmarked == false`, so no banner.
  func testF1SummaryShowsNoBannerWhenTheServerSaysPhotosAreLeftUnmarked() throws {
    let app = launch(orientation: .portrait)
    let sheetBar = openShootSummary(in: app, titleNames: titleNames(folderOne: app))
    // Positive control: the counts rendered, so the absent banner is a reading, not a blank.
    assertCounts(in: app, total: "40", picked: "10", disliked: "2", unmarked: "28")
    XCTAssertFalse(
      app.descendants(matching: .any)["shootSummaryBanner"].exists,
      "The banner shows for a folder whose server summary says photos are left unmarked.")
    closeShootSummary(in: app, sheetBar: sheetBar)
  }

  /// (f), folder 3: the server says `nothing_left_unmarked == true` (while it still reports 7
  /// unmarked — the fixture's deliberate contradiction), so the banner shows: the flag is the
  /// server's word, never recomputed here.
  func testF2SummaryShowsTheBannerWhenTheServerSaysNothingIsLeftUnmarked() throws {
    let app = launch(orientation: .portrait, extraArguments: ["-UITestSelectFolder", "3"])
    let names = ["2026-09-14 — Wandern", "2026-09-14-wandern"]
    let sheetBar = openShootSummary(in: app, titleNames: names)
    XCTAssertTrue(
      app.descendants(matching: .any)["shootSummaryBanner"].waitForExistence(timeout: 10),
      "No banner for a folder whose server summary says nothing is left unmarked.")
    assertCounts(in: app, total: "12", picked: "4", disliked: "1", unmarked: "7")
    closeShootSummary(in: app, sheetBar: sheetBar)
  }

  /// (f), folder 4 (`template`): no `FolderSummary` exists, so "Counts unavailable", no counts and
  /// no banner.
  ///
  /// At Compact the folder is opened the way a user reaches it — through the Library tree. The
  /// DEBUG auto-select pushes the grid over the Library root before that root ever mounts, so the
  /// tree never loads; with no summary either, `WorkspaceTitle` has no name, the bar has no title
  /// and so no title menu (gate on 0d2d057, iPhone dump: the bar holds only `BackButton` and
  /// `inspectorChromeButton`). A summary-less folder is reachable at Compact only from the
  /// Library or Search tabs, both of which load the tree first.
  func testF3SummaryShowsCountsUnavailableForAFolderWithoutAServerSummary() throws {
    let app = launch(orientation: .portrait, extraArguments: ["-UITestSelectFolder", "4"])
    if layout(of: app) == .compact {
      reopenTheTemplateFolderThroughTheLibraryTree(in: app)
    }
    let sheetBar = openShootSummary(in: app, titleNames: ["template"])
    XCTAssertTrue(
      app.descendants(matching: .any)["shootSummaryCountsUnavailable"]
        .waitForExistence(timeout: 10),
      "A folder with no server summary does not say \"Counts unavailable\".")
    XCTAssertFalse(
      app.descendants(matching: .any)["shootSummary.total"].exists,
      "Counts are shown for a folder the server has no summary for.")
    XCTAssertFalse(
      app.descendants(matching: .any)["shootSummaryBanner"].exists,
      "The banner shows without a server summary.")
    closeShootSummary(in: app, sheetBar: sheetBar)
  }

  /// Back to the Library root, which mounts the tree and loads it, then a tap on the fixture's
  /// `template` leaf (id 4, handle `folderContainer-4`). No disclosure taps: the grid already
  /// has folder 4 open, so the tree's IMGMGR-405 reveal (`FolderTreeSection
  /// .revealHighlightedFolder`) has expanded the Incoming tier and every ancestor row. A walk
  /// that taps them toggles them CLOSED — gate on b47aeac, iPhone dump: after the Incoming tap
  /// only the three tier rows remained and `folderDisclose-2` matched nothing.
  private func reopenTheTemplateFolderThroughTheLibraryTree(in app: XCUIApplication) {
    let back = app.navigationBars.buttons["BackButton"].firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 10), "The pushed grid has no Back button.")
    back.tap()
    let incoming = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(reveal(incoming, in: app), "The Library root's tree never loaded.")
    let template = app.descendants(matching: .any)["folderContainer-4"].firstMatch
    XCTAssertTrue(
      reveal(template, in: app),
      "The Library tree did not reveal the open `template` folder (IMGMGR-405 rule 6).")
    template.tap()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Tapping the `template` row did not reopen its grid.")
  }

  /// Scrolls until `element` is hittable, in both directions — `TierHomeUITests.reveal`, copied
  /// for the reason that suite gives (extracting it would edit a shipped suite for no fix of its).
  private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 8) -> Bool {
    if element.waitForExistence(timeout: 15), element.isHittable { return true }
    let firstList = app.collectionViews.firstMatch
    let scroller: XCUIElement = firstList.exists ? firstList : app
    for _ in 0..<swipes {
      scroller.swipeUp()
      if element.exists, element.isHittable { return true }
    }
    for _ in 0..<(swipes * 2) {
      scroller.swipeDown()
      if element.exists, element.isHittable { return true }
    }
    return element.exists && element.isHittable
  }

  // MARK: - Launch and layout

  private func launch(
    orientation: UIDeviceOrientation, extraArguments: [String] = []
  ) -> XCUIApplication {
    XCUIDevice.shared.orientation = orientation
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"] + extraArguments
    app.launch()
    // Again after launch — the sequence known to take on these destinations.
    XCUIDevice.shared.orientation = orientation
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike) never appeared within 30s — expected the fixture's populated grid.")
    // The rotation's layout pass, then the resolver's `.onGeometryChange` reaction to it.
    Thread.sleep(forTimeInterval: 2.0)
    return app
  }

  /// Width FIRST, the sidebar second — the P10 probe's classification
  /// (`InspectorSlideOverUITests.assertInspectorContract`). Below the Regular-3 pin the width
  /// alone cannot separate Compact from Regular-2: the landscape iPhone is 874 pt wide, above
  /// `compactShellWidthCeiling` (which is meant for portrait), yet the app resolves it Compact
  /// (gate on 0d2d057: `P10-PROBE landscape: window=(874.0, 402.0) … resolvedLayout=compact`,
  /// and (d) ran there instead of skipping). Only Regular-2 shows the sidebar beside the grid.
  private func layout(of app: XCUIApplication) -> Layout {
    let width = app.windows.firstMatch.frame.width
    if width >= Self.regular3WidthThreshold { return .regular3 }
    if width < Self.compactShellWidthCeiling { return .compact }
    let sidebar = sidebarRow(app)
    let sidebarShown = sidebar.waitForExistence(timeout: 10) && sidebar.isHittable
    let besideTheGrid = sidebarShown && app.buttons["Dislike"].isHittable
    return besideTheGrid ? .regular2 : .compact
  }

  private func require(_ expected: Layout, in app: XCUIApplication, context: String) throws {
    let actual = layout(of: app)
    guard actual == expected else {
      throw XCTSkip(
        "IMGMGR-450 \(context): window=\(app.windows.firstMatch.frame.size) resolves to "
          + "\(actual.rawValue), not \(expected.rawValue).")
    }
  }

  // MARK: - Inspector helpers

  /// The Info control on the grid's bar. By identifier OR label: on iOS 26.5 some toolbar items
  /// do not carry their SwiftUI identifier (WP28 P1/P2 gate finding), and the label always
  /// starts with "Info" — "Info", or the filtered "Info, 1 filter active".
  private func infoControl(_ app: XCUIApplication) -> XCUIElement {
    let control = app.navigationBars.buttons
      .matching(
        NSPredicate(
          format: "identifier == 'inspectorChromeButton' OR label BEGINSWITH 'Info'")
      )
      .firstMatch
    XCTAssertTrue(control.waitForExistence(timeout: 10), "No Info control on the grid's bar.")
    return control
  }

  /// The stub's one mark facet row (value "pick", count 3). Case-sensitive and excluding the
  /// action bar's "Pick" button — see `InspectorSlideOverUITests` for the gate run that needed it.
  private func pickFacetRow(in app: XCUIApplication) -> XCUIElement {
    app.buttons
      .matching(
        NSPredicate(
          format: "label BEGINSWITH 'pick' AND label != 'Pick' AND NOT (label CONTAINS 'photos')")
      )
      .firstMatch
  }

  /// Taps the Stats segment and the stub's pick facet row, then proves the grid's filter state
  /// changed where the reader sees it: the Clear row appears and the Info control announces one
  /// active filter.
  private func applyTheStubsPickFacet(in app: XCUIApplication, info: XCUIElement) {
    app.buttons["Stats"].tap()
    let markRow = pickFacetRow(in: app)
    XCTAssertTrue(markRow.waitForExistence(timeout: 10), "Stats offers no 'pick' facet row.")
    XCTAssertTrue(markRow.isHittable, "The Stats facet row exists but cannot be tapped.")
    markRow.tap()
    XCTAssertTrue(
      app.buttons["inspectorClearFilters"].waitForExistence(timeout: 10),
      "Tapping the facet row did not filter the grid.")
    let filteredInfo = app.navigationBars.buttons
      .matching(NSPredicate(format: "label == 'Info, 1 filter active'")).firstMatch
    XCTAssertTrue(
      filteredInfo.waitForExistence(timeout: 10),
      "The Info control does not report the filter the Stats row applied (label "
        + "\(info.exists ? info.label : "<gone>")).")
  }

  private func sidebarRow(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
  }

  private func assertSidebarShown(in app: XCUIApplication, state: String) {
    let row = sidebarRow(app)
    XCTAssertTrue(
      row.waitForExistence(timeout: 10) && row.isHittable,
      "The sidebar is not shown beside the grid while \(state) (IMGMGR-390).")
  }

  private func firstHittableTile(in app: XCUIApplication) -> XCUIElement? {
    for id in 1...12 {
      let tile = app.descendants(matching: .any)["gridTile-\(id)"].firstMatch
      if tile.exists && tile.isHittable { return tile }
    }
    return nil
  }

  // MARK: - Chrome helpers

  private func assertAllSixHittable(in app: XCUIApplication, state: String) {
    for identifier in Self.hostChromeIdentifiers {
      let control = app.descendants(matching: .any)[identifier].firstMatch
      XCTAssertTrue(
        control.waitForExistence(timeout: 10), "`\(identifier)` is not on the bar while \(state).")
      XCTAssertTrue(
        control.isHittable,
        "`\(identifier)` exists but is not directly hittable while \(state) — folded into the "
          + "overflow, which this state's contract does not allow.")
    }
  }

  /// Each control's label, read while it is directly on the bar, so a folded one can be found
  /// in the overflow menu by the same words.
  private func hostChromeLabels(in app: XCUIApplication, state: String) -> [String: String] {
    var labels: [String: String] = [:]
    for identifier in Self.hostChromeIdentifiers {
      let control = app.descendants(matching: .any)[identifier].firstMatch
      XCTAssertTrue(
        control.waitForExistence(timeout: 10), "`\(identifier)` is not on the bar while \(state).")
      labels[identifier] = control.label
    }
    return labels
  }

  /// Evidence, not a verdict: what the bar shows directly in this state, the title included —
  /// the title is new in WP28 P3 and shares the bar (IMGMGR-427 owns the expanded budget).
  private func recordChromeCensus(in app: XCUIApplication, state: String) {
    var census = Self.hostChromeIdentifiers.map { identifier -> String in
      "\(identifier)=\(reading(of: app.descendants(matching: .any)[identifier].firstMatch))"
    }
    let names = [Self.folderOneName, Self.folderOneSummaryName]
    let title = titleElement(in: app.navigationBars.descendants(matching: .any), names: names)
    census.append("title=\(reading(of: title))")
    census.append("toolbarSearch=\(reading(of: regularToolbarSearchButton(app)))")
    let overflow = overflowButton(app)
    census.append("overflow=\(overflow.exists)")
    let direct = Self.hostChromeIdentifiers.filter { identifier in
      let control = app.descendants(matching: .any)[identifier].firstMatch
      return control.exists && control.isHittable
    }
    census.append("directlyHittable=\(direct.count)/\(Self.hostChromeIdentifiers.count)")
    census.append("sidebar=\(reading(of: sidebarRow(app)))")
    let bar = app.navigationBars.buttons.allElementsBoundByIndex.map { $0.label }
    print(
      "IMGMGR-450-CENSUS \(state): window=\(app.frame.size) "
        + census.joined(separator: " ") + " navBarButtons=\(bar)")
  }

  private func reading(of element: XCUIElement) -> String {
    element.exists ? (element.isHittable ? "hittable" : "folded") : "absent"
  }

  /// The system overflow ("More") on the navigation bars — never the grid action bar's own More
  /// menu (`gridMoreMenu`), which lives on the bottom bar.
  private func overflowButton(_ app: XCUIApplication) -> XCUIElement {
    app.navigationBars.buttons
      .matching(NSPredicate(format: "label ==[c] 'More' AND identifier != 'gridMoreMenu'"))
      .firstMatch
  }

  /// Every one of the six is hittable on the bar, or — folded — hittable inside the overflow.
  /// Used ONLY where an orchestrator ruling relaxes all-six-hittable; `ruling` names it (R6:
  /// Regular-3 expanded; R6b: Regular-2 inspector open) in every failure and in the log line.
  private func assertAllSixReachable(
    in app: XCUIApplication, labels: [String: String], state: String, ruling: String
  ) {
    var reach: [String] = []
    for identifier in Self.hostChromeIdentifiers {
      let control = app.descendants(matching: .any)[identifier].firstMatch
      if control.exists && control.isHittable {
        reach.append("\(identifier)=direct")
        continue
      }
      let label = labels[identifier] ?? identifier
      let viaOverflow = reachableThroughOverflow(in: app, identifier: identifier, label: label)
      reach.append("\(identifier)=\(viaOverflow ? "overflow" : "UNREACHABLE")")
      XCTAssertTrue(
        viaOverflow,
        "`\(identifier)` (\"\(label)\") is neither hittable on the bar nor reachable through the "
          + "overflow while \(state) — a shipped control lost its home. Relaxed to REACHABLE by "
          + "ruling \(ruling) only; nothing may be dropped.")
    }
    print("IMGMGR-450-REACH \(state) [ruling \(ruling)]: " + reach.joined(separator: " "))
  }

  /// Opens the overflow and looks for a hittable element carrying the control's identifier or
  /// label. The folded bar item itself may still be in the hierarchy (not hittable), so the
  /// presentation is detected by one MORE match appearing than before the tap.
  private func reachableThroughOverflow(
    in app: XCUIApplication, identifier: String, label: String
  ) -> Bool {
    let overflow = overflowButton(app)
    guard overflow.waitForExistence(timeout: 5) else { return false }
    let matches = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, label))
    let before = matches.count
    let opened = openPresentation(
      overflow, revealing: matches.element(boundBy: before), timeout: 15)
    guard opened else { return false }
    attach(app, named: "IMGMGR-450-overflow-\(identifier)")
    let reachable = matches.allElementsBoundByIndex.contains { $0.isHittable }
    // Close the menu with a tap on the status bar strip, which carries no control.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).tap()
    _ = matches.element(boundBy: before).waitForNonExistence(timeout: 5)
    return reachable
  }

  // MARK: - Summary helpers

  /// Folder 1's accepted title names: the tree name at Regular, either name at Compact.
  private func titleNames(folderOne app: XCUIApplication) -> [String] {
    layout(of: app) == .compact
      ? [Self.folderOneName, Self.folderOneSummaryName] : [Self.folderOneName]
  }

  /// The grid's title, matched by LABEL — the title-menu trigger is system chrome and carries no
  /// SwiftUI identifier. Exactly the title on the Regular bar (iPad gate on 0d2d057: `Tap
  /// "2026-08-27 — Stub Shoot" Button`); on the iOS 26.5 Compact pushed bar the same trigger is
  /// labelled "<title>, Actions Menu" (iPhone hierarchy dump, same gate: `Button {{170.0, 73.7},
  /// {36.0, 20.7}}, label: 'stub, Actions Menu'`). Both forms are matched EXACTLY — any other
  /// suffix is not the title-menu trigger.
  ///
  /// A fresh predicate per query, as every other UI test builds them: `matching(_:)` takes the
  /// non-Sendable `NSPredicate` as a `sending` argument (gate on 45e2dfc).
  private func titleElement(in elements: XCUIElementQuery, names: [String]) -> XCUIElement {
    let labels = names.flatMap { [$0, "\($0), Actions Menu"] }
    return elements.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
  }

  /// Finds the grid's title (asserting it shows one of `titleNames`), opens its title menu with
  /// the IMGMGR-404 helper, taps "Shoot Summary", and returns the sheet's navigation bar.
  private func openShootSummary(
    in app: XCUIApplication, titleNames: [String]
  ) -> XCUIElement {
    var title = titleElement(in: app.navigationBars.buttons, names: titleNames)
    if !title.waitForExistence(timeout: 15) {
      title = titleElement(in: app.navigationBars.staticTexts, names: titleNames)
    }
    XCTAssertTrue(
      title.waitForExistence(timeout: 5),
      "The grid's title does not show the fixture folder's name (\(titleNames)). Bars: "
        + "\(app.navigationBars.allElementsBoundByIndex.map { $0.identifier })")
    let row = app.buttons
      .matching(
        NSPredicate(format: "identifier == 'shootSummaryTitleMenuRow' OR label == 'Shoot Summary'")
      )
      .firstMatch
    XCTAssertTrue(
      openPresentation(title, revealing: row, timeout: 20),
      "The title menu did not offer \"Shoot Summary\".")
    row.tap()
    let sheetBar = app.navigationBars["Shoot Summary"]
    XCTAssertTrue(
      sheetBar.waitForExistence(timeout: 10), "\"Shoot Summary\" did not present the sheet.")
    return sheetBar
  }

  private func assertCounts(
    in app: XCUIApplication, total: String, picked: String, disliked: String, unmarked: String
  ) {
    let expected = [
      ("total", total), ("picked", picked), ("disliked", disliked), ("unmarked", unmarked),
    ]
    for (id, value) in expected {
      let text = app.staticTexts["shootSummary.\(id)"]
      XCTAssertTrue(text.waitForExistence(timeout: 10), "The Summary shows no \(id) count.")
      XCTAssertEqual(text.label, value, "The Summary's \(id) is not the server's count.")
    }
  }

  /// "Done" dismisses. By identifier OR label, for the same toolbar-identifier reason as Info.
  private func closeShootSummary(in app: XCUIApplication, sheetBar: XCUIElement) {
    let done = sheetBar.buttons
      .matching(NSPredicate(format: "identifier == 'shootSummaryDone' OR label == 'Done'"))
      .firstMatch
    XCTAssertTrue(done.waitForExistence(timeout: 5), "The Summary sheet has no Done.")
    done.tap()
    XCTAssertTrue(sheetBar.waitForNonExistence(timeout: 10), "Done did not dismiss the Summary.")
  }

  private func attach(_ app: XCUIApplication, named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
