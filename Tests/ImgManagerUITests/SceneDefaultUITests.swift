import XCTest

/// IMGMGR-557 acceptance on the real surface, on both destinations (the iPhone run is Compact,
/// the iPad run Regular): a folder opens grouped by Scene when it has scenes, and Flat when it
/// has none, with Arrange › Group showing the mode in force. A manual switch lasts for that
/// folder visit only (owner ruling on open decision 1).
///
/// Fixture: `-UITestStubGrid` serves its folders as loose photographs; `-UITestFolderHasScenes`
/// adds scene 5000 to them. The second flag enters Scene through NOTHING but the folder open —
/// unlike `-UITestEnterSceneMode`, which also calls `setDisplayMode(.scene)` — so these tests
/// see the default itself.
final class SceneDefaultUITests: OrientationPinnedUITestCase {

  private static let sceneHandle = "sceneHandle-5000"

  func testAFolderWithScenesOpensInSceneWithGroupShowingScene() throws {
    let app = launched(["-UITestStubGrid", "-UITestFolderHasScenes"])
    XCTAssertTrue(
      element(app, Self.sceneHandle).waitForExistence(timeout: 20),
      "A folder with a scene did not open in Scene: no scene card in the stream.")
    assertGroup(app, current: "arrange.group.scene", not: "arrange.group.none")
    attach("folder-with-scenes-opens-in-scene")
  }

  func testAFolderWithoutScenesOpensFlatWithGroupShowingNone() throws {
    let app = launched(["-UITestStubGrid"])
    // Positive control first: the grid is populated, so "no scene card" cannot pass on a blank
    // screen.
    XCTAssertTrue(
      element(app, "gridTile-1").waitForExistence(timeout: 20), "The flat grid is empty.")
    XCTAssertEqual(
      count(app, Self.sceneHandle), 0, "A folder without scenes shows a scene card.")
    assertGroup(app, current: "arrange.group.none", not: "arrange.group.scene")
    attach("folder-without-scenes-opens-flat")
  }

  func testAManualFlatLastsForThatFolderVisitOnly() throws {
    let app = launched(["-UITestStubGrid", "-UITestStubSkipAutoSelect", "-UITestFolderHasScenes"])
    showLibraryIfCompact(app)
    let incoming = element(app, "folderTreeTier-Incoming")
    XCTAssertTrue(revealInList(incoming, in: app), "The Incoming tier never appeared.")
    let first = element(app, "folderRow-1")
    openTreeTier(incoming, showing: first)
    XCTAssertTrue(revealInList(first, in: app), "Folder 1's row never appeared.")
    first.tap()
    XCTAssertTrue(
      element(app, Self.sceneHandle).waitForExistence(timeout: 30),
      "Precondition: folder 1 has scenes, so it opens in Scene.")

    // The reader switches this visit to Flat.
    openArrange(app, revealing: "arrange.group.none")
    choose("arrange.group.none", in: app)
    closeArrange(app)
    XCTAssertTrue(
      element(app, Self.sceneHandle).waitForNonExistence(timeout: 15),
      "Group › None did not leave Scene.")

    // A different folder opens on its own default, not on the last choice.
    returnToTheTree(app, row: first)
    let year = element(app, "folderDisclose-2")
    XCTAssertTrue(revealInList(year, in: app), "The 2026 container's expand control is missing.")
    year.tap()
    let month = element(app, "folderDisclose-2-2026-09")
    XCTAssertTrue(revealInList(month, in: app), "The 2026-09 month fold is missing.")
    month.tap()
    let second = element(app, "folderRow-3")
    XCTAssertTrue(revealInList(second, in: app), "Folder 3's row never appeared.")
    second.tap()
    XCTAssertTrue(
      element(app, Self.sceneHandle).waitForExistence(timeout: 30),
      "The next folder opened Flat: the manual switch outlived its folder visit.")
    assertGroup(app, current: "arrange.group.scene", not: "arrange.group.none")
    attach("next-folder-opens-on-its-own-default")
  }

  // MARK: - Helpers

  private func launched(_ arguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = arguments
    app.launch()
    return app
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  private func count(_ app: XCUIApplication, _ identifier: String) -> Int {
    app.descendants(matching: .any).matching(identifier: identifier).count
  }

  private func openArrange(_ app: XCUIApplication, revealing row: String) {
    let control = element(app, "gridArrangeControl")
    XCTAssertTrue(control.waitForExistence(timeout: 20), "No 'gridArrangeControl' in the chrome.")
    XCTAssertTrue(
      openPresentation(control, revealing: element(app, row), timeout: 10),
      "The Arrange popover did not open on '\(row)'.")
  }

  private func closeArrange(_ app: XCUIApplication) {
    let done = element(app, "arrangeDone")
    XCTAssertTrue(revealInArrange(done, in: app), "The Arrange popover's Done is not reachable.")
    done.tap()
    XCTAssertTrue(
      element(app, "arrange.group.none").waitForNonExistence(timeout: 5),
      "Done did not close the Arrange popover.")
  }

  /// Taps a row and waits for it to read "Checked": the tap went through the store's setter.
  private func choose(_ identifier: String, in app: XCUIApplication) {
    let row = element(app, identifier)
    XCTAssertTrue(revealInArrange(row, in: app), "'\(identifier)' is not reachable.")
    row.tap()
    let checked = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Checked"), object: element(app, identifier))
    XCTAssertEqual(
      XCTWaiter().wait(for: [checked], timeout: 10), .completed,
      "'\(identifier)' did not read Checked after it was tapped.")
  }

  /// Arrange › Group, as the popover renders it: `current` checked and `other` not.
  private func assertGroup(_ app: XCUIApplication, current: String, not other: String) {
    openArrange(app, revealing: current)
    for (identifier, expected) in [(current, "Checked"), (other, "Unchecked")] {
      let row = element(app, identifier)
      XCTAssertTrue(revealInArrange(row, in: app), "'\(identifier)' is not reachable.")
      XCTAssertEqual(
        row.value as? String, expected, "Arrange › Group: '\(identifier)' reads the wrong state.")
    }
    closeArrange(app)
  }

  /// Back to the tree if opening a grid took it away: on Compact the grid is pushed over the
  /// home, on Regular the sidebar stays (`FolderTreeHierarchyUITests.returnToTheTree`).
  private func returnToTheTree(_ app: XCUIApplication, row: XCUIElement) {
    if row.exists && row.isHittable { return }
    let back = app.navigationBars.buttons.firstMatch
    if back.exists && back.isHittable { back.tap() }
  }

  /// Scrolls the home list both ways until `element` is hittable
  /// (`FolderTreeHierarchyUITests.reveal`).
  private func revealInList(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
    if element.waitForExistence(timeout: 15), element.isHittable { return true }
    let firstList = app.collectionViews.firstMatch
    let scroller: XCUIElement = firstList.exists ? firstList : app
    for _ in 0..<8 {
      scroller.swipeUp()
      if element.exists, element.isHittable { return true }
    }
    for _ in 0..<16 {
      scroller.swipeDown()
      if element.exists, element.isHittable { return true }
    }
    return element.exists && element.isHittable
  }

  private func attach(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
