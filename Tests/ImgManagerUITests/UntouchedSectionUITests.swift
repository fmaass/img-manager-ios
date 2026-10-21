import XCTest

/// IMGMGR-549 acceptance (design R3-1/R3-2): the Untouched section and the hollow ring.
///
/// - The section lists the fixture's untouched Incoming shoots newest first — 23, 5, 3 — and
///   never the archive's untouched shoot 21 or the undated root shoot 1.
/// - The TREE's rows carry the ring on every untouched shoot, the archive included (ruling b),
///   on the image inside the row's own cell, and no row states readiness any more.
/// - Nine untouched shoots show eight rows and "1 more ›", which opens a grid of all nine; a tile
///   opens its shoot and records exactly one Recent row.
/// - Settings › "Show Untouched" off removes the section.
/// - Nothing untouched (`-UITestNoUntouched`) renders no section, header or overflow row, on
///   both shells — read only after a summary-backed Recent row proved the served summaries were
///   applied.
///
/// Driven through the production composition on both destinations: at Regular the section sits
/// in the sidebar above the tree, at Compact on the Shoots tab (the launch tab) while the tree is
/// the Library tab's.
///
/// Launch fixture: `-UITestStubGrid` plus `-UITestStubSkipAutoSelect`, so the app stops at the
/// home; the fixture's clock is 2026-10-18, so the default horizon is 1 January 2026.
final class UntouchedSectionUITests: OrientationPinnedUITestCase {

  func testTheSectionListsUntouchedIncomingShootsNewestFirst() throws {
    let app = launch()

    let header = element(app, "untouchedSection")
    XCTAssertTrue(header.waitForExistence(timeout: 30), "The home has no Untouched section.")
    let rows = [23, 5, 3].map { element(app, "untouchedRow-\($0)") }
    for (index, row) in rows.enumerated() {
      XCTAssertTrue(
        row.waitForExistence(timeout: 15), "Untouched member #\(index + 1) has no row.")
    }
    XCTAssertLessThan(header.frame.minY, rows[0].frame.minY, "The header is not above its rows.")
    XCTAssertLessThan(rows[0].frame.minY, rows[1].frame.minY, "23 (10-03) is not above 5.")
    XCTAssertLessThan(rows[1].frame.minY, rows[2].frame.minY, "5 (09-27) is not above 3.")

    // The exclusions, asserted after the members were found.
    XCTAssertFalse(
      element(app, "untouchedRow-21").exists,
      "The archive's untouched shoot is listed — Untouched never lists the archive.")
    XCTAssertFalse(element(app, "untouchedRow-1").exists, "The undated root shoot is listed.")
    XCTAssertFalse(element(app, Self.moreIdentifier).exists, "Three members show an overflow row.")

    // The ring sits on the member's own row.
    let cell = app.cells.containing(.any, identifier: "untouchedRow-5").firstMatch
    XCTAssertTrue(
      cell.descendants(matching: .any)["untouchedRing-untouched-5"].firstMatch.exists,
      "Untouched row 5 carries no hollow ring inside its own cell.")
    attach(named: "IMGMGR-549-untouched-section")
  }

  func testTreeRowsCarryTheRingInEveryTierAndStateNoReadiness() throws {
    let app = launch()
    showLibraryIfCompact(app)

    let incoming = element(app, "folderTreeTier-Incoming")
    XCTAssertTrue(reveal(incoming, in: app), "The Incoming tier row never appeared.")
    // IMGMGR-462: Compact launches with Incoming open; a bare tap would close it.
    openTreeTier(incoming, showing: element(app, "folderRow-1"))
    XCTAssertTrue(reveal(element(app, "folderRow-1"), in: app), "folderRow-1 never appeared.")

    // Folder 1 is touched: its cell has no ring. Asserted on a row that is there.
    let rootCell = app.cells.containing(.any, identifier: "folderRow-1").firstMatch
    XCTAssertFalse(
      rootCell.descendants(matching: .any)["folderUntouched-1"].firstMatch.exists,
      "A touched shoot's tree row carries the untouched ring.")

    // 5 sits in the 2026 › September fold.
    openFold(app, container: 2, month: "2026-09", showing: "folderRow-5")
    let cell = app.cells.containing(.any, identifier: "folderRow-5").firstMatch
    XCTAssertTrue(
      cell.descendants(matching: .any)["folderUntouched-5"].firstMatch.waitForExistence(
        timeout: 10),
      "Tree row 5 carries no hollow ring inside its own cell.")
    XCTAssertEqual(
      cell.descendants(matching: .any)["folderUntouched-5"].firstMatch.label, "Untouched")

    // Ruling b: the archive's untouched shoot carries the ring too.
    let archive = element(app, "folderTreeTier-Archive")
    XCTAssertTrue(reveal(archive, in: app), "The Archive tier row never appeared.")
    if !element(app, "folderContainer-20").exists { archive.tap() }
    openFold(app, container: 20, month: "2025-12", showing: "folderRow-21")
    let archiveCell = app.cells.containing(.any, identifier: "folderRow-21").firstMatch
    XCTAssertTrue(
      archiveCell.descendants(matching: .any)["folderUntouched-21"].firstMatch.waitForExistence(
        timeout: 10),
      "The archive's untouched shoot carries no ring in the tree (ruling b: everywhere).")

    // R3-1: the readiness caption is gone from every row.
    let readiness = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "folderReadiness-"))
    XCTAssertEqual(readiness.count, 0, "A tree row still states its readiness.")
    attach(named: "IMGMGR-549-tree-rings")
  }

  /// `-UITestPerFolderGrid` names every grid tile by its folder (`gridTile-<folderID * 1000 + n>`),
  /// so `gridTile-31001` is folder 31's own grid and no other.
  func testNineUntouchedOverflowIntoAGridWhoseTileOpensTheShoot() throws {
    let app = launch(extraArguments: ["-UITestManyUntouched", "-UITestPerFolderGrid"])

    let more = element(app, Self.moreIdentifier)
    XCTAssertTrue(more.waitForExistence(timeout: 30), "Nine members show no overflow row.")
    XCTAssertEqual(more.label, "1 more ›")
    let rows = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "untouchedRow-"))
    XCTAssertEqual(rows.count, 8, "The section does not show exactly eight rows.")
    XCTAssertFalse(element(app, "untouchedRow-31").exists, "The ninth (oldest) shoot has a row.")
    XCTAssertFalse(element(app, "recentRow-31").exists, "Recent lists 31 before it was opened.")

    let sheet = element(app, Self.allSheetIdentifier)
    XCTAssertTrue(
      openPresentation(more, revealing: sheet, timeout: 20), "\"1 more ›\" opened no grid.")
    // The grid is lazy: every member is looked for while scrolling, not in one read.
    let members = [23, 5, 3, 36, 35, 34, 33, 32, 31].map { "untouchedTile-\($0)" }
    XCTAssertEqual(
      overflowTilesSeen(in: app, expecting: members.count), Set(members),
      "The overflow grid does not list exactly the nine members.")
    attach(named: "IMGMGR-549-untouched-all")

    let tile = element(app, "untouchedTile-31")
    XCTAssertTrue(scrollOverflow(in: app, untilHittable: tile), "Tile 31 is never hittable.")
    tile.tap()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 15), "A tile tap did not dismiss the grid.")
    XCTAssertTrue(
      element(app, "gridTile-31001").waitForExistence(timeout: 30),
      "Tile 31 did not open folder 31's own grid.")

    // Visible history, not a call count (the recorder-seam unit test
    // `oneTileSelectionRecordsOnce` counts the calls): the opened shoot is listed under Recent.
    returnToHome(app)
    // Scrolled to, not waited for: on the iPhone, Recent sits below eight rows and "1 more ›",
    // past the fold of a lazy list that never builds an off-screen row.
    let recent = element(app, "recentRow-31")
    XCTAssertTrue(reveal(recent, in: app), "The opened shoot is not under Recent.")
    let recentRows = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "recentRow-"))
    XCTAssertEqual(recentRows.count, 1, "Recent lists more than the one shoot opened.")
  }

  /// `-UITestNoUntouched` serves every fixture shoot as touched. The positive control is
  /// RENDERED summary data, not a request count: folder 1 is opened from the tree and its Recent
  /// row — drawn only by joining the recorded open with a loaded summary — must appear. Only then
  /// are the Untouched section, its rows and its overflow row asserted absent. At Compact the tree
  /// is the Library tab's and Recent the Shoots tab's; at Regular both are in the sidebar.
  func testNothingUntouchedRendersNoSectionOnEitherShell() throws {
    let app = launch(extraArguments: ["-UITestNoUntouched"])
    let compact = rendersCompactShell(app)
    showLibraryIfCompact(app)

    let incoming = element(app, "folderTreeTier-Incoming")
    XCTAssertTrue(reveal(incoming, in: app), "The Incoming tier row never appeared.")
    // IMGMGR-462: Compact launches with Incoming open; a bare tap would close it.
    openTreeTier(incoming, showing: element(app, "folderRow-1"))
    let shoot = element(app, "folderRow-1")
    XCTAssertTrue(reveal(shoot, in: app), "folderRow-1 never appeared.")
    shoot.tap()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30), "Tree row 1 did not open its shoot.")

    if compact { selectCompactTab(app, title: "Shoots") }
    let recent = element(app, "recentRow-1")
    XCTAssertTrue(
      recent.waitForExistence(timeout: 15),
      "No summary-backed Recent row for folder 1, so the summaries were never applied and the "
        + "absence below would prove nothing.")
    attach(named: "IMGMGR-549-nothing-untouched")

    XCTAssertFalse(
      element(app, "untouchedSection").exists,
      "The Untouched section renders with no untouched shoot — an empty section renders nothing.")
    let rows = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "untouchedRow-"))
    XCTAssertEqual(rows.count, 0, "An Untouched row renders with every shoot touched.")
    XCTAssertFalse(element(app, Self.moreIdentifier).exists, "An empty section shows \"more\".")
    if !compact {
      XCTAssertTrue(
        element(app, "sidebarSectionLibrary").exists,
        "The sidebar's \"Library\" header is missing, so the absence above proves nothing.")
    }
  }

  func testTurningUntouchedOffInSettingsRemovesTheSection() throws {
    let app = launch()
    let header = element(app, "untouchedSection")
    XCTAssertTrue(header.waitForExistence(timeout: 30), "The section never rendered at first.")

    let entry = rendersCompactShell(app) ? "accountToolbarButton" : "settingsGearButton"
    let opener = element(app, entry)
    XCTAssertTrue(opener.waitForExistence(timeout: 15), "No Settings entry point on the home.")
    XCTAssertTrue(
      openPresentation(opener, revealing: app.navigationBars["Settings"], timeout: 15),
      "The Settings sheet did not open.")
    var toggle = app.switches["settingsShowUntouchedToggle"].firstMatch
    if !toggle.waitForExistence(timeout: 10) {
      toggle = element(app, "settingsShowUntouchedToggle")
    }
    XCTAssertTrue(toggle.exists, "Settings has no Show Untouched toggle.")
    let before = toggle.value as? String
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 0.5))
      .withOffset(CGVector(dx: -30, dy: 0))
      .tap()
    let flipped = NSPredicate(format: "value != %@", before ?? "")
    _ = XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: flipped, object: toggle)], timeout: 5)
    XCTAssertNotEqual(toggle.value as? String, before, "The toggle did not flip.")
    app.navigationBars["Settings"].buttons["Done"].tap()
    XCTAssertTrue(
      app.navigationBars["Settings"].waitForNonExistence(timeout: 10), "Settings stayed open.")

    XCTAssertTrue(
      header.waitForNonExistence(timeout: 10),
      "The Untouched section still renders with Show Untouched off.")
    XCTAssertFalse(element(app, "untouchedRow-5").exists, "An Untouched row survived the toggle.")
  }

  // MARK: - Shared

  private static let moreIdentifier = "untouchedMore"
  private static let allSheetIdentifier = "untouchedAllSheet"

  /// Computed, not stored: `NSPredicate` is not `Sendable`, so a stored static is refused.
  private static var tilePredicate: NSPredicate {
    NSPredicate(format: "identifier BEGINSWITH %@", "untouchedTile-")
  }

  /// The overflow sheet's scroll view: the one holding a tile, whichever tiles are loaded.
  private func overflowScroller(in app: XCUIApplication) -> XCUIElement {
    app.scrollViews.containing(Self.tilePredicate).firstMatch
  }

  /// Every tile identifier the lazy grid shows while it is scrolled to its end. Only UPWARD
  /// swipes: a downward one at the top would drag the sheet away.
  private func overflowTilesSeen(in app: XCUIApplication, expecting count: Int) -> Set<String> {
    let tiles = app.descendants(matching: .any).matching(Self.tilePredicate)
    var seen = Set<String>()
    for _ in 0..<8 {
      // An explicit closure, never `map(\.identifier)` (main-actor isolation under Swift 6).
      seen.formUnion(tiles.allElementsBoundByIndex.map { $0.identifier })
      if seen.count >= count { break }
      overflowScroller(in: app).swipeUp()
    }
    return seen
  }

  private func scrollOverflow(in app: XCUIApplication, untilHittable tile: XCUIElement) -> Bool {
    for _ in 0..<4 {
      if tile.exists, tile.isHittable { return true }
      overflowScroller(in: app).swipeUp()
    }
    return tile.exists && tile.isHittable
  }

  private func launch(extraArguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"] + extraArguments
    app.launch()
    return app
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  /// Opens container `container`'s `month` fold until `row` is on screen; every step is skipped
  /// when its target is already open.
  private func openFold(
    _ app: XCUIApplication, container: Int, month: String, showing row: String
  ) {
    if element(app, row).exists, element(app, row).isHittable { return }
    let fold = element(app, "folderTreeMonth-\(container)-\(month)")
    if !fold.exists {
      let containerRow = element(app, "folderContainer-\(container)")
      XCTAssertTrue(reveal(containerRow, in: app), "Container \(container) never appeared.")
      element(app, "folderDisclose-\(container)").tap()
    }
    XCTAssertTrue(reveal(fold, in: app), "The \(month) fold never appeared.")
    if !element(app, row).exists {
      element(app, "folderDisclose-\(container)-\(month)").tap()
    }
    XCTAssertTrue(reveal(element(app, row), in: app), "\(row) never appeared.")
  }

  /// Back to the home after a grid opened: at Compact the grid is pushed over the Shoots root, at
  /// Regular the sidebar stays beside it.
  private func returnToHome(_ app: XCUIApplication) {
    guard rendersCompactShell(app) else { return }
    let back = app.navigationBars.buttons.firstMatch
    if back.waitForExistence(timeout: 10), back.isHittable { back.tap() }
    _ = element(app, "untouchedSection").waitForExistence(timeout: 15)
  }

  /// Scrolls the home until `element` is on screen, in BOTH directions — the same helper the
  /// sibling folder-tree suites carry.
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

  private func attach(named name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let size = screenshot.image.size
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(name)-\(Int(size.width))x\(Int(size.height))"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
