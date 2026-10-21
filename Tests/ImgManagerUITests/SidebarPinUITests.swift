import XCTest

/// IMGMGR-549 acceptance: a row's context menu pins and unpins it, and the long press that opens
/// the menu neither navigates nor records a Recent entry — the menu's action calls only
/// `togglePin`, but the List's selection and the row's tap gesture also see the press, so this
/// is checked here rather than assumed.
///
/// Regular (the iPad's `List(selection:)` sidebar): the fixture auto-selects folder 1, so its grid
/// is open (`-UITestPerFolderGrid` names every tile by folder). Long-pressing Untouched row 5 and
/// choosing Pin adds `pinnedRow-5` between Untouched and Library — and the grid still shows
/// folder 1, and Recent stays empty: neither the menu nor the DEBUG auto-select is a user open.
/// Unpinning the same way removes the row.
///
/// Compact (the iPhone): Pinned is the Regular sidebar's (ruling c), so the pin is driven from the
/// Library tab's tree row and read back through the menu itself (Unpin is offered after Pin),
/// with the tab asserted still at its root — no grid was pushed — and the Shoots tab's Recent
/// asserted still empty afterwards: none of the three long presses was recorded as an open.
///
/// Menu presentation under load is the known IMGMGR-404 flake class: `openPresentation` retries a
/// lost press once, and a failure there is re-run, never weakened.
final class SidebarPinUITests: OrientationPinnedUITestCase {

  func testPinningAndUnpinningARow() throws {
    let probe = XCUIApplication()
    probe.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"]
    probe.launch()
    if rendersCompactShell(probe) {
      try assertCompactPinFromTheTree(probe)
    } else {
      probe.terminate()
      try assertRegularPinFromTheSidebar()
    }
  }

  // MARK: - Regular

  private func assertRegularPinFromTheSidebar() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestPerFolderGrid"]
    app.launch()

    XCTAssertTrue(
      element(app, "gridTile-1001").waitForExistence(timeout: 30),
      "The fixture's auto-selected folder 1 never showed its grid.")
    let row = element(app, "untouchedRow-5")
    XCTAssertTrue(row.waitForExistence(timeout: 15), "Untouched row 5 never appeared.")

    let pin = element(app, "rowMenuPin")
    XCTAssertTrue(
      openPresentation(row, revealing: pin, timeout: 20, gesture: .longPress),
      "A long press on Untouched row 5 did not offer Pin.")
    pin.tap()

    let pinned = element(app, "pinnedRow-5")
    XCTAssertTrue(pinned.waitForExistence(timeout: 15), "Pin did not add row 5 under Pinned.")
    assertGridUnchanged(app)
    let untouchedHeader = element(app, "untouchedSection")
    let pinnedHeader = element(app, "pinnedSection")
    let libraryHeader = element(app, "sidebarSectionLibrary")
    XCTAssertTrue(pinnedHeader.exists, "Pinned rows render without their header.")
    XCTAssertLessThan(
      untouchedHeader.frame.minY, pinnedHeader.frame.minY, "Pinned is not below Untouched.")
    XCTAssertLessThan(
      pinned.frame.minY, libraryHeader.frame.minY, "Pinned is not above Library.")
    attach(named: "IMGMGR-549-pinned-row")

    let unpin = element(app, "rowMenuUnpin")
    XCTAssertTrue(
      openPresentation(pinned, revealing: unpin, timeout: 20, gesture: .longPress),
      "A long press on the pinned row did not offer Unpin.")
    unpin.tap()
    XCTAssertTrue(pinned.waitForNonExistence(timeout: 15), "Unpin left row 5 under Pinned.")
    XCTAssertFalse(element(app, "pinnedSection").exists, "An empty Pinned section renders.")
    assertGridUnchanged(app)
  }

  /// The grid still shows folder 1 only, and nothing reached Recent.
  private func assertGridUnchanged(_ app: XCUIApplication) {
    XCTAssertTrue(
      element(app, "gridTile-1001").exists, "The long press moved the grid off folder 1.")
    XCTAssertFalse(element(app, "gridTile-5001").exists, "The long press opened folder 5.")
    let recent = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "recentRow-"))
    XCTAssertEqual(
      recent.count, 0, "A pin or the DEBUG auto-select was recorded as a user open in Recent.")
  }

  // MARK: - Compact

  private func assertCompactPinFromTheTree(_ app: XCUIApplication) throws {
    showLibraryIfCompact(app)
    let incoming = element(app, "folderTreeTier-Incoming")
    XCTAssertTrue(incoming.waitForExistence(timeout: 30), "The Incoming tier row never appeared.")
    openTreeTier(incoming, showing: element(app, "folderRow-1"))
    let row = element(app, "folderRow-1")
    XCTAssertTrue(row.waitForExistence(timeout: 15), "Tree row 1 never appeared.")

    let pin = element(app, "rowMenuPin")
    XCTAssertTrue(
      openPresentation(row, revealing: pin, timeout: 20, gesture: .longPress),
      "A long press on tree row 1 did not offer Pin.")
    pin.tap()
    assertLibraryAtItsRoot(app)

    let unpin = element(app, "rowMenuUnpin")
    XCTAssertTrue(
      openPresentation(row, revealing: unpin, timeout: 20, gesture: .longPress),
      "After Pin, the tree row's menu does not offer Unpin.")
    unpin.tap()
    assertLibraryAtItsRoot(app)

    XCTAssertTrue(
      openPresentation(row, revealing: pin, timeout: 20, gesture: .longPress),
      "After Unpin, the tree row's menu does not offer Pin again.")
    // Close the menu without choosing anything.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    XCTAssertTrue(pin.waitForNonExistence(timeout: 10), "The tree row's menu did not close.")

    // Recent lives on the Shoots tab at Compact. Its Untouched rows are the positive control
    // (the home rendered), then nothing of the three long presses may be listed under Recent.
    selectCompactTab(app, title: CompactTabTitle.shoots)
    XCTAssertTrue(
      element(app, "untouchedRow-5").waitForExistence(timeout: 15),
      "The Shoots root never rendered, so the empty Recent below would prove nothing.")
    let recent = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "recentRow-"))
    XCTAssertEqual(recent.count, 0, "A long press on tree row 1 was recorded in Recent.")
    XCTAssertFalse(element(app, "recentSection").exists, "Recent renders with nothing opened.")
  }

  private func assertLibraryAtItsRoot(_ app: XCUIApplication) {
    XCTAssertTrue(
      element(app, "folderTreeViewMenu").waitForExistence(timeout: 10),
      "The Library tab left its root after a menu action.")
    XCTAssertFalse(app.buttons["Dislike"].exists, "A menu action pushed a grid.")
  }

  // MARK: - Shared

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
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
