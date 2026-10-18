import XCTest

/// WP28 P1 (IMGMGR-448) acceptance: the Compact shell — three tabs, Shoots · Library · Search,
/// with the Needs-review badge on Shoots, one grid host across the tabs, search in the tab bar and
/// Account's one Compact home on the Shoots root.
///
/// Compact is a WIDTH, read off the screen (`rendersCompactShell`), never the device idiom. On the
/// iPad destination the Regular split renders instead: (a) asserts that no tab bar exists there,
/// and (b)-(f), whose subject only exists at Compact, skip with that reason.
///
/// Launch fixture: `-UITestStubGrid` plus `-UITestStubSkipAutoSelect`, so the app stops at the
/// Shoots root. Of the fixture's six summaries exactly two are Needs-review members (folders 1
/// and 21); `-UITestNoNeedsReview` serves all six as reviewed. `-UITestPerFolderGrid` makes every
/// grid tile's identifier name its folder (`gridTile-<folderID * 1000 + n>`).
final class CompactTabShellUITests: OrientationPinnedUITestCase {

  private static let tabTitles = ["Shoots", "Library", "Search"]

  /// (a) Exactly three tab buttons in the system tab bar — Shoots, Library, Search, in that order.
  /// Read by LABEL: the `tab.*` identifiers on the tab labels never reach the system tab button.
  func testTheCompactShellHasExactlyThreeTabs() throws {
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
      "The Compact tab bar is not exactly Shoots, Library and Search, in that order.")
  }

  /// (b) DIAGNOSTIC, not the badge: the Shoots tab's content root reports the Needs-review count,
  /// and it equals the rows listed under it.
  ///
  /// SwiftUI does not expose the tab-button badge to XCUITest: on iOS 26.5 (gate run on 08367cc)
  /// the Shoots tab button reads "Shoots" with no value, and the tab bar holds no badge text. The
  /// only number in the hierarchy is `value: 2` on the Shoots tab's content root, the element
  /// holding its navigation bar. This test checks THAT value — the count the badge is fed from —
  /// and not the rendered badge. The rendered badge is the named screenshot pair
  /// (IMGMGR-448-tab-bar-badge / -no-badge, kept always) and is left to the owner's visual check.
  func testTheShootsContentRootReportsTheNeedsReviewCount_diagnostic() throws {
    let app = launch()
    try skipUnlessCompact(app)

    XCTAssertTrue(
      element(app, "needsReviewRow-1").waitForExistence(timeout: 30),
      "The Shoots tab never listed the fixture's Needs-review shoots.")
    let rows = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "needsReviewRow-"))
    let rowCount = rows.count
    XCTAssertEqual(rowCount, 2, "The fixture has two Needs-review members (folders 1 and 21).")

    let shoots = compactTabButton(app, title: "Shoots")
    XCTAssertTrue(shoots.waitForExistence(timeout: 15), "There is no Shoots tab button.")
    let carried = waitForRootNumbers(app, toContain: rowCount)
    recordTree(shoots, named: "Shoots tab button")
    recordTree(app.tabBars.firstMatch, named: "tab bar")
    attachScreenshot(named: "IMGMGR-448-tab-bar-badge")
    XCTAssertTrue(
      carried.contains(rowCount),
      "The Shoots tab's content root does not report the Needs-review count \(rowCount) — the "
        + "number of Needs-review rows on the tab. Numbers found: \(carried).")
  }

  /// (c) DIAGNOSTIC, not the badge: nothing awaiting review, so the Shoots tab's content root
  /// reports no count. Like (b), this reads the count the badge is fed from; the rendered badge's
  /// absence is the IMGMGR-448-tab-bar-no-badge screenshot, left to the owner's visual check.
  func testNoNeedsReviewMeansNoCountOnTheShootsContentRoot_diagnostic() throws {
    let app = launch(extraArguments: ["-UITestNoNeedsReview"])
    try skipUnlessCompact(app)

    // The positive control: the summaries DID load (Recent lists the reviewed root shoot), so the
    // missing count below is an empty membership and not a home that never loaded.
    XCTAssertTrue(
      element(app, "recentRow-1").waitForExistence(timeout: 30),
      "-UITestNoNeedsReview did not reach the summaries: Recent never listed folder 1.")
    XCTAssertFalse(
      element(app, "needsReviewSection").exists,
      "The pinned section rendered with no shoot awaiting review.")

    let shoots = compactTabButton(app, title: "Shoots")
    XCTAssertTrue(shoots.waitForExistence(timeout: 15), "There is no Shoots tab button.")
    recordTree(shoots, named: "Shoots tab button")
    recordTree(app.tabBars.firstMatch, named: "tab bar")
    attachScreenshot(named: "IMGMGR-448-tab-bar-no-badge")
    let carried = contentRootNumbers(app)
    XCTAssertTrue(
      carried.isEmpty,
      "The Shoots tab's content root reports a count (\(carried)) with nothing to review.")
  }

  /// (d) A→B→return: a shoot opened in one tab is never left showing under another.
  func testAShootOpenedInOneTabNeverShowsUnderAnother() throws {
    let app = launch(extraArguments: ["-UITestPerFolderGrid"])
    try skipUnlessCompact(app)

    // A: folder 1, from the Shoots tab's Needs-review section.
    let rowA = element(app, "needsReviewRow-1")
    XCTAssertTrue(rowA.waitForExistence(timeout: 30), "Folder 1's Needs-review row never appeared.")
    rowA.tap()
    XCTAssertTrue(
      element(app, "gridTile-1001").waitForExistence(timeout: 30),
      "Opening folder 1 from Needs review did not show folder 1's grid.")

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
    XCTAssertTrue(
      element(app, "needsReviewSection").waitForExistence(timeout: 15),
      "Returning to Shoots did not land on its root.")
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

  /// (e) The Search tab filters the shared tree by the tab bar's field and opens the grid.
  func testTheSearchTabFiltersTheTreeAndOpensTheGrid() throws {
    let app = launch(extraArguments: ["-UITestPerFolderGrid"])
    try skipUnlessCompact(app)

    selectCompactTab(app, title: "Search")
    let field = app.searchFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 15), "The Search tab carries no search field.")
    XCTAssertFalse(
      app.textFields["folderTreeSearchField"].exists,
      "The inline folder search field rendered at Compact beside the Search tab's field.")
    let name = "The Search tab's field (`app.searchFields.firstMatch`)"
    guard focusForTyping(field, named: name) else { return }
    field.typeText("Wandern")

    let match = element(app, "folderRow-3")
    XCTAssertTrue(
      match.waitForExistence(timeout: 15), "The search kept no row for the matching folder.")
    XCTAssertTrue(
      element(app, "folderRow-1").waitForNonExistence(timeout: 10),
      "A folder whose name does not match stayed in the searched tree.")
    attachScreenshot(named: "IMGMGR-448-search-tab-filtered")

    match.tap()
    XCTAssertTrue(
      element(app, "gridTile-3001").waitForExistence(timeout: 30),
      "Tapping the search result did not open folder 3's grid.")
  }

  /// (f) Account is reachable from the Shoots root — and the Library root does not carry a second
  /// (g) Plan D3: the search field is drawn for the Search tab only. Shoots and Library render
  /// their content (each root's own row is the positive control) with no search field at all.
  func testOnlyTheSearchTabCarriesASearchField() throws {
    let app = launch()
    try skipUnlessCompact(app)

    XCTAssertTrue(
      element(app, "needsReviewRow-1").waitForExistence(timeout: 30),
      "The Shoots root never rendered, so the absence below would prove nothing.")
    XCTAssertEqual(app.searchFields.count, 0, "The Shoots tab draws a search field.")

    selectCompactTab(app, title: "Library")
    XCTAssertTrue(
      element(app, "folderTreeViewMenu").waitForExistence(timeout: 15),
      "The Library root never rendered, so the absence below would prove nothing.")
    XCTAssertEqual(app.searchFields.count, 0, "The Library tab draws a search field.")

    selectCompactTab(app, title: "Search")
    XCTAssertTrue(
      app.searchFields.firstMatch.waitForExistence(timeout: 15),
      "The Search tab carries no search field.")
  }

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
