import XCTest

/// WP29 P2 (IMGMGR-453) acceptance, on the real surface and on both destinations: one Arrange
/// control whose popover holds every sort, direction, grouping and thumbnail-size choice one tap
/// deep, and whose state is the store's own state.
///
/// - (a) one tap on `gridArrangeControl` reaches all 24 row identifiers, with no further tap
///   (scrolling inside the popover only).
/// - (b) Group Camera and size 320 pt, then Done and reopen: both rows are checked, the grid shows
///   server section headers, and the control reads "Active".
/// - (c) the Sort, Group and Zoom controls are gone.
///
/// Makes no device-idiom decision: the control is on Regular's grid bar and on Compact's options
/// row, and the popover adapts to a sheet at Compact by the system's own rule.
final class ArrangePopoverUITests: OrientationPinnedUITestCase {

  /// `ArrangeModel.rows`, spelled out: a UI-test bundle drives the app rather than linking it.
  private static let rowIdentifiers = [
    "arrange.sort.date_taken", "arrange.sort.filename", "arrange.sort.rating",
    "arrange.sort.iso", "arrange.sort.camera", "arrange.sort.lens",
    "arrange.direction.asc", "arrange.direction.desc",
    "arrange.group.none", "arrange.group.scene", "arrange.group.day", "arrange.group.month",
    "arrange.group.camera", "arrange.group.lens", "arrange.group.iso", "arrange.group.location",
    "arrange.layout.justified", "arrange.layout.square",
    "arrange.size.120", "arrange.size.160", "arrange.size.200", "arrange.size.260",
    "arrange.size.320", "arrange.size.400",
  ]

  func testOneTapReachesEveryArrangeRowAndTheOldControlsAreGone() throws {
    let app = launchedApp()
    let control = arrangeControl(app)
    XCTAssertTrue(control.waitForExistence(timeout: 10), "No 'gridArrangeControl' in the chrome.")
    XCTAssertTrue(control.isHittable, "The Arrange control exists but cannot be tapped.")

    // (c), with the Arrange control above as its positive control.
    for removed in ["gridSortControl", "gridGroupControl", "gridZoomControl"] {
      XCTAssertEqual(
        app.descendants(matching: .any).matching(identifier: removed).count, 0,
        "'\(removed)' is still in the chrome; Arrange replaces it.")
    }

    // (a) ONE tap. Everything after it is a read or a scroll inside the popover.
    XCTAssertTrue(
      openPresentation(control, revealing: row(app, Self.rowIdentifiers[0]), timeout: 10),
      "One tap on Arrange did not present its first row.")
    var unreachable: [String] = []
    for identifier in Self.rowIdentifiers {
      let element = row(app, identifier)
      if !(element.waitForExistence(timeout: 2) && reveal(element, in: app)) {
        unreachable.append(identifier)
      }
    }
    XCTAssertEqual(
      unreachable, [], "These Arrange rows are not reachable after one tap: \(unreachable)")
    attach("arrange-popover-open")
  }

  func testGroupAndSizeSurviveDismissAndReopen() throws {
    let app = launchedApp()
    let control = arrangeControl(app)
    XCTAssertTrue(control.waitForExistence(timeout: 10), "No 'gridArrangeControl' in the chrome.")
    XCTAssertEqual(
      control.value as? String, "Off", "Arrange reports an arrangement in force at launch.")

    XCTAssertTrue(
      openPresentation(control, revealing: row(app, "arrange.group.camera"), timeout: 10),
      "The Arrange popover has no Group Camera row.")
    choose("arrange.group.camera", in: app)
    choose("arrange.size.320", in: app)

    let done = app.descendants(matching: .any)["arrangeDone"].firstMatch
    XCTAssertTrue(reveal(done, in: app), "The Arrange popover's Done is not reachable.")
    done.tap()
    XCTAssertTrue(
      row(app, "arrange.size.320").waitForNonExistence(timeout: 5),
      "Done did not close the Arrange popover.")

    let headers = app.descendants(matching: .any).matching(identifier: "gridSectionHeader")
    XCTAssertTrue(
      headers.firstMatch.waitForExistence(timeout: 15),
      "Grouping by Camera from Arrange rendered no section headers.")
    let active = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Active"), object: arrangeControl(app))
    XCTAssertEqual(
      XCTWaiter().wait(for: [active], timeout: 10), .completed,
      "Arrange does not report itself active while grouping by Camera.")
    attach("arrange-grouped-by-camera")

    // Reopen: the rows read the store, so both choices are checked and their siblings are not.
    let reopen = arrangeControl(app)
    let camera = row(app, "arrange.group.camera")
    XCTAssertTrue(
      openPresentation(reopen, revealing: camera, timeout: 10),
      "The Arrange popover did not reopen.")
    let expectations = [
      ("arrange.group.camera", "Checked"), ("arrange.group.none", "Unchecked"),
      ("arrange.size.320", "Checked"), ("arrange.size.200", "Unchecked"),
    ]
    for (identifier, expected) in expectations {
      let element = row(app, identifier)
      XCTAssertTrue(reveal(element, in: app), "'\(identifier)' is not reachable on reopen.")
      XCTAssertEqual(
        element.value as? String, expected, "'\(identifier)' reads the wrong state on reopen.")
    }
    attach("arrange-popover-reopened")
  }

  // MARK: - Helpers

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid.")
    return app
  }

  private func arrangeControl(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["gridArrangeControl"].firstMatch
  }

  private func row(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  /// Taps a row and waits for it to read "Checked": the tap went through the store's setter.
  private func choose(_ identifier: String, in app: XCUIApplication) {
    let element = row(app, identifier)
    XCTAssertTrue(reveal(element, in: app), "'\(identifier)' is not reachable.")
    element.tap()
    let checked = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Checked"), object: row(app, identifier))
    XCTAssertEqual(
      XCTWaiter().wait(for: [checked], timeout: 10), .completed,
      "'\(identifier)' did not read Checked after it was tapped.")
  }

  /// Scrolls the popover's own scroll view until `element` is hittable. Scrolling is not a tap:
  /// it opens nothing and chooses nothing.
  ///
  /// IMGMGR-551: the shared, directed reveal (`revealInArrange`) — see its note for why the blind
  /// swipes that lived here dismissed the iPad popover once the list grew to 24 rows.
  private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
    revealInArrange(element, in: app)
  }

  private func attach(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
