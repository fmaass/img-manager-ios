import XCTest

/// WP28 P1 (IMGMGR-448) acceptance: the Compact shell — two tabs, Shoots · Library (R3-18,
/// IMGMGR-550, removed the Search tab), with the Untouched badge on Shoots (IMGMGR-549), one grid
/// host across the tabs and Account's one Compact home on the Shoots root.
///
/// Compact is a WIDTH, read off the screen (`rendersCompactShell`), never the device idiom. On the
/// iPad destination the Regular split renders instead: (a) asserts that no tab bar exists there,
/// and (b)-(f), whose subject only exists at Compact, skip with that reason.
///
/// Launch fixture: `-UITestStubGrid` plus `-UITestStubSkipAutoSelect`, so the app stops at the
/// Shoots root. Of the fixture's summaries exactly three are Untouched members (folders 23, 5 and
/// 3; 21 is untouched but archive); `-UITestNoUntouched` serves every shoot as touched.
/// `-UITestPerFolderGrid` makes every grid tile's identifier name its folder
/// (`gridTile-<folderID * 1000 + n>`).
final class CompactTabShellUITests: OrientationPinnedUITestCase {

  private static let tabTitles = ["Shoots", "Library"]

  /// (a) Exactly two tab buttons in the system tab bar — Shoots, Library, in that order (R3-18).
  /// Read by LABEL: the `tab.*` identifiers on the tab labels never reach the system tab button.
  func testTheCompactShellHasExactlyTwoTabs() throws {
    let app = launch()
    let tabBar = app.tabBars.firstMatch

    guard rendersCompactShell(app) else {
      // Regular: the split's sidebar renders (its View menu is the positive control) and no tab
      // bar exists at all — P1 leaves the Regular shell as it was.
      XCTAssertTrue(
        element(app, "folderTreeViewMenu").waitForExistence(timeout: 30),
        "The Regular sidebar never rendered, so the absence below would prove nothing.")
      XCTAssertFalse(tabBar.exists, "A tab bar rendered at a Regular width.")
      return
    }

    XCTAssertTrue(tabBar.waitForExistence(timeout: 30), "The Compact shell rendered no tab bar.")
    let buttons = tabBar.buttons.allElementsBoundByIndex
    let ordered = buttons.sorted { $0.frame.minX < $1.frame.minX }.map { $0.label }
    if ordered != Self.tabTitles { recordTree(tabBar, named: "tab bar") }
    XCTAssertEqual(
      ordered, Self.tabTitles,
      "The Compact tab bar is not exactly Shoots and Library, in that order.")
  }

  /// (b) DIAGNOSTIC, not the badge: the Shoots tab's content root reports the Untouched count,
  /// and it equals the rows listed under it (IMGMGR-549 ruling d).
  ///
  /// SwiftUI does not expose the tab-button badge to XCUITest: on iOS 26.5 (gate run on 08367cc)
  /// the Shoots tab button reads "Shoots" with no value, and the tab bar holds no badge text. The
  /// only number in the hierarchy is the value on the Shoots tab's content root, the element
  /// holding its navigation bar. This test checks THAT value — the count the badge is fed from —
  /// and not the rendered badge. The rendered badge is the named screenshot pair
  /// (IMGMGR-448-tab-bar-badge / -no-badge, kept always) and is left to the owner's visual check.
  func testTheShootsContentRootReportsTheUntouchedCount_diagnostic() throws {
    let app = launch()
    try skipUnlessCompact(app)

    XCTAssertTrue(
      element(app, "untouchedRow-23").waitForExistence(timeout: 30),
      "The Shoots tab never listed the fixture's Untouched shoots.")
    let rows = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "untouchedRow-"))
    let rowCount = rows.count
    XCTAssertEqual(rowCount, 3, "The fixture has three Untouched members (folders 23, 5 and 3).")

    let shoots = compactTabButton(app, title: "Shoots")
    XCTAssertTrue(shoots.waitForExistence(timeout: 15), "There is no Shoots tab button.")
    let carried = waitForRootNumbers(app, toContain: rowCount)
    recordTree(shoots, named: "Shoots tab button")
    recordTree(app.tabBars.firstMatch, named: "tab bar")
    attachScreenshot(named: "IMGMGR-448-tab-bar-badge")
    XCTAssertTrue(
      carried.contains(rowCount),
      "The Shoots tab's content root does not report the Untouched count \(rowCount) — the "
        + "number of Untouched rows on the tab. Numbers found: \(carried).")
  }

  /// (c) DIAGNOSTIC, not the badge: nothing untouched, so the Shoots tab's content root reports
  /// no count. Like (b), this reads the count the badge is fed from; the rendered badge's absence
  /// is the IMGMGR-448-tab-bar-no-badge screenshot, left to the owner's visual check.
  func testNoUntouchedMeansNoCountOnTheShootsContentRoot_diagnostic() throws {
    let app = launch(extraArguments: ["-UITestNoUntouched"])
    try skipUnlessCompact(app)

    // The positive control is RENDERED summary data: folder 1, opened from the Library tree,
    // must come back as a Recent row on the Shoots root — a row drawn only by joining the
    // recorded open with a loaded summary. Only then are the missing section and count an empty
    // membership rather than a home whose summaries never arrived. (The section's absence on
    // both shells is `UntouchedSectionUITests.testNothingUntouchedRendersNoSectionOnEitherShell`.)
    selectCompactTab(app, title: "Library")
    let shoot = element(app, "folderRow-1")
    if !shoot.waitForExistence(timeout: 30) {
      element(app, "folderTreeTier-Incoming").tap()
    }
    XCTAssertTrue(shoot.waitForExistence(timeout: 15), "Tree row 1 never appeared.")
    shoot.tap()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30), "Tree row 1 did not open its shoot.")
    selectCompactTab(app, title: "Shoots")
    XCTAssertTrue(
      element(app, "recentRow-1").waitForExistence(timeout: 15),
      "No summary-backed Recent row for folder 1: the summaries were never applied, so the "
        + "absence below would prove nothing.")
    XCTAssertFalse(
      element(app, "untouchedSection").exists,
      "The Untouched section rendered with no untouched shoot.")

    let shoots = compactTabButton(app, title: "Shoots")
    XCTAssertTrue(shoots.waitForExistence(timeout: 15), "There is no Shoots tab button.")
    recordTree(shoots, named: "Shoots tab button")
    recordTree(app.tabBars.firstMatch, named: "tab bar")
    attachScreenshot(named: "IMGMGR-448-tab-bar-no-badge")
    let carried = contentRootNumbers(app)
    XCTAssertTrue(
      carried.isEmpty,
      "The Shoots tab's content root reports a count (\(carried)) with nothing untouched.")
  }

  /// (d) A→B→return: a shoot opened in one tab is never left showing under another.
  func testAShootOpenedInOneTabNeverShowsUnderAnother() throws {
    let app = launch(extraArguments: ["-UITestPerFolderGrid"])
    try skipUnlessCompact(app)

    // A: folder 5, from the Shoots tab's Untouched section.
    let rowA = element(app, "untouchedRow-5")
    XCTAssertTrue(rowA.waitForExistence(timeout: 30), "Folder 5's Untouched row never appeared.")
    rowA.tap()
    XCTAssertTrue(
      element(app, "gridTile-5001").waitForExistence(timeout: 30),
      "Opening folder 5 from Untouched did not show folder 5's grid.")

    // B: folder 2 (the Incoming year container), from the Library tab's tree. Opening A already
    // revealed Incoming (IMGMGR-405 rule 6); it is opened here only if it is still closed.
    selectCompactTab(app, title: "Library")
    let rowB = element(app, "folderContainer-2")
    if !rowB.waitForExistence(timeout: 10) {
      element(app, "folderTreeTier-Incoming").tap()
    }
    XCTAssertTrue(rowB.waitForExistence(timeout: 15), "Folder 2's tree row never appeared.")
    rowB.tap()
    XCTAssertTrue(
      element(app, "gridTile-2001").waitForExistence(timeout: 30),
      "Opening folder 2 from the Library tree did not show folder 2's grid.")

    // Back to Shoots: its stack was cleared when B opened, so it is at its root with no grid.
    selectCompactTab(app, title: "Shoots")
    let untouchedHeader = element(app, "untouchedSection")
    XCTAssertTrue(
      untouchedHeader.waitForExistence(timeout: 15),
      "Returning to Shoots did not land on its root.")
    // IMGMGR-549 (R3-14): Untouched above Recent, and Recent is this device's shoot opens —
    // folder 5, which A opened. B's folder 2 is a year container: it opened a grid but is not a
    // shoot, so the recorder refused it and Recent holds folder 5 alone.
    let recentHeader = element(app, "recentSection")
    XCTAssertTrue(
      element(app, "recentRow-5").waitForExistence(timeout: 15),
      "Recent does not list folder 5 after it was opened from the Shoots tab.")
    XCTAssertTrue(recentHeader.exists, "Recent rows render without their header.")
    let recentRows = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "recentRow-"))
    XCTAssertEqual(recentRows.count, 1, "Recent lists more than the one shoot opened.")
    XCTAssertLessThan(
      untouchedHeader.frame.minY, recentHeader.frame.minY, "Untouched is not above Recent.")
    XCTAssertFalse(app.buttons["Dislike"].exists, "The Shoots tab still shows a grid.")
    XCTAssertTrue(
      gridTileIdentifiers(in: app).isEmpty,
      "The Shoots tab still shows grid tiles after another tab opened a shoot.")

    // Library holds B's grid — and only B's photographs.
    selectCompactTab(app, title: "Library")
    XCTAssertTrue(
      element(app, "gridTile-2001").waitForExistence(timeout: 15),
      "Library no longer shows folder 2's grid after the tab switch.")
    let tiles = gridTileIdentifiers(in: app)
    let firstTileID = tiles.compactMap { Int($0.dropFirst("gridTile-".count)) }.min()
    XCTAssertEqual(firstTileID, 2001, "The Library grid's first image is not folder 2's (2001).")
    XCTAssertTrue(
      tiles.allSatisfy { $0.hasPrefix("gridTile-20") },
      "The Library grid shows photographs of another folder: \(tiles.sorted()).")
  }

  /// (g) R3-18 (IMGMGR-550): no tab carries a search field and the tab bar has no Search button.
  /// Shoots and Library render their content first (each root's own row is the positive
  /// control), so the absences cannot be a shell that never built.
  func testNoCompactTabCarriesASearchField() throws {
    let app = launch()
    try skipUnlessCompact(app)

    XCTAssertTrue(
      element(app, "untouchedRow-5").waitForExistence(timeout: 30),
      "The Shoots root never rendered, so the absence below would prove nothing.")
    XCTAssertEqual(app.searchFields.count, 0, "The Shoots tab draws a search field.")
    XCTAssertFalse(
      app.tabBars.firstMatch.buttons["Search"].exists, "The tab bar still has a Search tab.")

    selectCompactTab(app, title: "Library")
    XCTAssertTrue(
      element(app, "folderTreeViewMenu").waitForExistence(timeout: 15),
      "The Library root never rendered, so the absence below would prove nothing.")
    XCTAssertEqual(app.searchFields.count, 0, "The Library tab draws a search field.")
  }

  /// (f) Account is reachable from the Shoots root — and the Library root does not carry a second
  /// one: the Shoots root is its ONE Compact home.
  func testAccountIsReachableFromTheShootsRoot() throws {
    let app = launch()
    try skipUnlessCompact(app)

    let account = element(app, "accountToolbarButton")
    XCTAssertTrue(
      account.waitForExistence(timeout: 30), "The Shoots root carries no Account toolbar item.")
    account.tap()
    XCTAssertTrue(
      app.navigationBars["Settings"].waitForExistence(timeout: 10),
      "Tapping Account on the Shoots root did not present the Settings sheet.")
    app.buttons["Done"].firstMatch.tap()

    selectCompactTab(app, title: "Library")
    XCTAssertTrue(
      element(app, "folderTreeViewMenu").waitForExistence(timeout: 15),
      "The Library root's bar never rendered, so the absence below would prove nothing.")
    XCTAssertFalse(
      element(app, "accountToolbarButton").exists,
      "The Library root carries Account too — Compact has one Account home, the Shoots root.")
  }

  /// Final audit F2: the Shoots title menu's Refresh row — the visible twin of the root's
  /// pull-to-refresh — exists, is hittable, and really re-reads the queue: the fixture's served
  /// `/api/folder-summaries` count (`debugProbe.summaries`) grows when it is tapped. The count is
  /// read only once it has held still, so the first load cannot pass for the refresh.
  func testTheShootsTitleMenuRefreshRowRereadsTheQueue() throws {
    let app = launch()
    try skipUnlessCompact(app)

    let probe = element(app, "debugProbe.summaries")
    XCTAssertTrue(
      probe.waitForExistence(timeout: 30), "The Shoots root carries no summaries-request probe.")
    let before = settledSummariesRequests(probe)
    XCTAssertGreaterThan(before, 0, "The Shoots root never loaded its queue.")

    let title = app.navigationBars.buttons
      .matching(NSPredicate(format: "label IN %@", ["Shoots", "Shoots, Actions Menu"]))
      .firstMatch
    XCTAssertTrue(title.waitForExistence(timeout: 15), "The Shoots root's bar has no title.")
    let row = app.buttons
      .matching(NSPredicate(format: "identifier == 'shootsRefreshMenuRow' OR label == 'Refresh'"))
      .firstMatch
    XCTAssertTrue(
      openPresentation(title, revealing: row, timeout: 20),
      "The Shoots title menu did not offer \"Refresh\".")
    XCTAssertTrue(row.isHittable, "The Shoots title menu's Refresh row cannot be tapped.")
    row.tap()

    let deadline = Date(timeIntervalSinceNow: 15)
    var after = summariesRequests(probe)
    while after <= before && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.5)
      after = summariesRequests(probe)
    }
    XCTAssertGreaterThan(
      after, before, "Tapping Refresh did not re-fetch the queue's summaries (\(before) before).")
  }

  // MARK: - Shared

  private func launch(extraArguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"] + extraArguments
    app.launch()
    return app
  }

  private func skipUnlessCompact(_ app: XCUIApplication) throws {
    guard rendersCompactShell(app) else {
      throw XCTSkip("Regular width: the Compact tab shell does not render on this destination.")
    }
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  /// Every grid tile identifier currently in the hierarchy (`gridTile-<id>`).
  private func gridTileIdentifiers(in app: XCUIApplication) -> [String] {
    let tiles = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "gridTile-"))
    // An explicit closure, never `map(\.identifier)` (main-actor isolation under Swift 6).
    return tiles.allElementsBoundByIndex.map { $0.identifier }
  }

  /// The fixture's served summaries-request count, off `debugProbe.summaries`'s value.
  private func summariesRequests(_ probe: XCUIElement) -> Int {
    numbers(in: (probe.value as? String) ?? "").first ?? 0
  }

  /// The count once it is nonzero and has not moved for two seconds, or whatever it reads after
  /// thirty — so a load still in flight is never mistaken for the refresh under test.
  private func settledSummariesRequests(_ probe: XCUIElement) -> Int {
    let deadline = Date(timeIntervalSinceNow: 30)
    var last = summariesRequests(probe)
    var stableSince = Date()
    while Date() < deadline {
      Thread.sleep(forTimeInterval: 0.5)
      let now = summariesRequests(probe)
      if now != last {
        last = now
        stableSince = Date()
      } else if now > 0 && Date().timeIntervalSince(stableSince) >= 2 {
        break
      }
    }
    return last
  }

  private func numbers(in text: String) -> [Int] {
    text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
  }

  /// Every number the Shoots tab's content root reports as its value — the elements holding the
  /// "Shoots" navigation bar (see (b)). Never a count recomputed from the rows, and not the
  /// rendered badge, which XCUITest cannot see.
  private func contentRootNumbers(_ app: XCUIApplication) -> [Int] {
    var found: [Int] = []
    let contentRoots = app.otherElements.containing(.navigationBar, identifier: "Shoots")
    for root in contentRoots.allElementsBoundByIndex {
      found += numbers(in: (root.value as? String) ?? "")
    }
    return found
  }

  /// The count follows the summaries load, so it is polled for rather than read once.
  private func waitForRootNumbers(_ app: XCUIApplication, toContain expected: Int) -> [Int] {
    let deadline = Date(timeIntervalSinceNow: 10)
    var found = contentRootNumbers(app)
    while !found.contains(expected) && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.5)
      found = contentRootNumbers(app)
    }
    return found
  }

  /// The element's `debugDescription` (with its children), kept even when the test passes.
  private func recordTree(_ element: XCUIElement, named name: String) {
    XCTContext.runActivity(named: "element tree: \(name)") { activity in
      let attachment = XCTAttachment(string: element.debugDescription)
      attachment.name = "element tree: \(name)"
      attachment.lifetime = .keepAlways
      activity.add(attachment)
    }
  }

  private func attachScreenshot(named name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let size = screenshot.image.size
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(name)-\(Int(size.width))x\(Int(size.height))"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
