import XCTest

/// WP13 P5b (IMGMGR-221 part 2) acceptance, on the real thing. The ticket's own AC is "the grid
/// sort menu offers the web's sort keys and the group-by dimensions … nothing gesture-only", and
/// the phase's verification asks for two screenshots: the Sort menu OPEN, and a grouped grid with
/// visible section headers — on both layouts the gate runs.
///
/// Makes NO device-idiom decision (plan invariant (i)): every step keys off an observed element,
/// so the same test runs on Compact's options row and on Regular's `.primaryAction` toolbar.
///
/// WP29 P2 (IMGMGR-453): the Sort and Group menus became sections of the Arrange popover
/// (`gridArrangeControl`), so every step opens Arrange and names its rows by identifier —
/// "Camera" is both a sort key and a grouping there.
final class SortGroupScreenshotUITests: OrientationPinnedUITestCase {

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else (sign-in screen, blank screen, or a "
        + "failed stub composition).")
    return app
  }

  func testSortRowsAreOneArrangeTapAwayOnAPrimarySurface() throws {
    let app = launchedApp()

    let arrange = arrangeControl(app)
    XCTAssertTrue(
      arrange.waitForExistence(timeout: 10),
      "The Arrange control is not on a primary surface — nothing named 'gridArrangeControl' is "
        + "in the hierarchy without opening an overflow menu.")
    XCTAssertTrue(arrange.isHittable, "The Arrange control exists but cannot be tapped.")

    // "Did anything get pushed into the overflow" — with a positive control (LSN-0033).
    XCTAssertTrue(
      app.buttons["Dislike"].exists,
      "Positive control failed: the Dislike button is gone, so the 0-hit overflow check below "
        + "would pass vacuously.")
    XCTAssertFalse(
      app.buttons["OverflowBarButtonItem"].exists,
      "A toolbar overflow chevron appeared — a view-option control is reachable only behind it, "
        + "which is exactly the state IMGMGR-221 exists to end.")

    // The six offered keys plus both directions, by identifier and by the words on the row.
    let keys = [
      ("date_taken", "Date"), ("filename", "Filename"), ("rating", "Rating"), ("iso", "ISO"),
      ("camera", "Camera"), ("lens", "Lens"),
    ]
    let first = row(app, "arrange.sort.date_taken")
    XCTAssertTrue(
      openPresentation(arrange, revealing: first, timeout: 5),
      "The open Arrange popover has no 'Date' sort row.")
    for (raw, title) in keys {
      let element = row(app, "arrange.sort.\(raw)")
      XCTAssertTrue(element.waitForExistence(timeout: 5), "No sort row for '\(title)'.")
      XCTAssertEqual(element.label, title, "The '\(raw)' sort row reads '\(element.label)'.")
    }
    XCTAssertTrue(row(app, "arrange.direction.asc").exists, "Arrange offers no Ascending row.")
    XCTAssertTrue(row(app, "arrange.direction.desc").exists, "Arrange offers no Descending row.")

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "sort-menu-open"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testGroupingByCameraRendersServerVouchedSectionHeaders() throws {
    let app = launchedApp()
    chooseCameraGrouping(in: app)

    // The headers the SERVER vouched for. The fixture's `/api/image-groups` answer carries the
    // live endpoint's own counts (36,568 · 280 · 213) against a page of twelve photographs, so
    // a client-side tally would print 4 and this assertion would fail — which is the whole
    // reason those numbers are the ones the fixture serves.
    let headers = app.descendants(matching: .any).matching(identifier: "gridSectionHeader")
    XCTAssertTrue(
      headers.firstMatch.waitForExistence(timeout: 15),
      "Grouping by Camera rendered no section headers at all — the grid is showing re-ordered "
        + "photographs, which is precisely the failure this phase exists to prevent.")

    let labels = headers.allElementsBoundByIndex.map { $0.label }
    XCTAssertGreaterThanOrEqual(
      labels.count, 2,
      "Only \(labels.count) section header(s) rendered: \(labels). The fixture serves three "
        + "camera buckets, so at least two boundaries must be visible.")
    // Digits only: the rendered count carries the simulator locale's grouping separator
    // (observed "36'568" on the Swiss locale the gate legs run under), so a literal comparison
    // asserts the separator rather than the number.
    let digitsPerLabel = labels.map { $0.filter(\.isNumber) }
    XCTAssertTrue(
      digitsPerLabel.contains { $0.contains("36568") },
      "No header carries the server's own count. Headers read: \(labels). A page-derived tally "
        + "would say 4.")
    XCTAssertTrue(
      labels.contains { $0.contains("SONY ILCE-7RM5") },
      "No header carries the server's own label. Headers read: \(labels).")

    // WP29 P2: the chosen dimension reads back as Arrange's arrangement signal; the checked row
    // itself is asserted in `chooseCameraGrouping` and on reopen in `ArrangePopoverUITests`.
    XCTAssertEqual(
      arrangeControl(app).value as? String, "Active",
      "Arrange does not report the Camera grouping as an arrangement in force.")

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "grouped-grid-section-headers"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTContext.runActivity(
      named: "Headers: \(labels) · captured \(screenshot.image.size)"
    ) { _ in }
  }

  /// IMGMGR-256 (folded into WP13 P11): the Scene-view caption row is gone, and the arrangement
  /// control itself carries the "you are in an arrangement" state — the Group control until WP29
  /// P2, the Arrange control since. Runs on both destinations.
  ///
  /// The load-bearing proof that Scene adds no banner row is `GridChromeRowsTests`, which drives
  /// a real Scene page; the fixture transport here serves no `/api/browse/stacks`, so this test
  /// takes the reachable arrangement (a dimension) and asserts the caption identifier is absent
  /// with a positive control beside it.
  func testArrangeHighlightsWhileAnArrangementIsInForceAndNoSceneBannerExists() throws {
    let app = launchedApp()

    let arrange = arrangeControl(app)
    XCTAssertTrue(
      arrange.waitForExistence(timeout: 10),
      "Nothing named 'gridArrangeControl' is on a primary surface.")
    XCTAssertEqual(
      arrange.value as? String, "Off",
      "The Arrange control reports itself active under Group: None.")

    let before = XCUIScreen.main.screenshot()
    let beforeAttachment = XCTAttachment(screenshot: before)
    beforeAttachment.name = "group-control-plain-under-none"
    beforeAttachment.lifetime = .keepAlways
    add(beforeAttachment)

    chooseCameraGrouping(in: app)

    let active = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Active"), object: arrangeControl(app))
    XCTAssertEqual(
      XCTWaiter().wait(for: [active], timeout: 10), .completed,
      "The Arrange control does not report itself active while grouping by Camera.")

    // Positive control for the 0-hit assertion below (LSN-0033): the grid really is on screen,
    // so "no caption row" cannot pass vacuously on a blank or crashed screen.
    XCTAssertTrue(
      app.buttons["Dislike"].exists,
      "Positive control failed: the action bar is gone, so the caption check below would pass "
        + "vacuously.")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "sceneModeCaption").count, 0,
      "A Scene-view caption row is still in the hierarchy — IMGMGR-256 removed it.")

    let after = XCUIScreen.main.screenshot()
    let afterAttachment = XCTAttachment(screenshot: after)
    afterAttachment.name = "group-control-highlighted-under-camera"
    afterAttachment.lifetime = .keepAlways
    add(afterAttachment)
  }

  // MARK: - Arrange

  private func arrangeControl(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["gridArrangeControl"].firstMatch
  }

  private func row(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  /// Opens Arrange, chooses Group Camera, waits for the row to read Checked, and closes the
  /// popover with Done, so what follows reads the grid rather than the popover or sheet.
  private func chooseCameraGrouping(in app: XCUIApplication) {
    let arrange = arrangeControl(app)
    XCTAssertTrue(
      arrange.waitForExistence(timeout: 10),
      "Nothing named 'gridArrangeControl' is on a primary surface.")
    let camera = row(app, "arrange.group.camera")
    XCTAssertTrue(
      openPresentation(arrange, revealing: camera, timeout: 5),
      "The Arrange popover offers no Group Camera row — the group-by half of IMGMGR-221 is "
        + "missing.")
    XCTAssertTrue(reveal(camera, in: app), "The Group Camera row is not reachable.")
    camera.tap()
    let checked = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Checked"),
      object: row(app, "arrange.group.camera"))
    XCTAssertEqual(
      XCTWaiter().wait(for: [checked], timeout: 10), .completed,
      "Group Camera did not read Checked after it was tapped.")
    let done = row(app, "arrangeDone")
    XCTAssertTrue(reveal(done, in: app), "The Arrange popover's Done is not reachable.")
    done.tap()
    XCTAssertTrue(camera.waitForNonExistence(timeout: 5), "Done did not close Arrange.")
  }

  /// Scrolls the popover's own scroll view until `element` is hittable, down then up.
  private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
    if element.exists && element.isHittable { return true }
    let scrollers = app.scrollViews.containing(.any, identifier: "arrange.sort.date_taken")
    let scroller = scrollers.firstMatch
    guard scroller.exists else { return false }
    for _ in 0..<5 where !(element.exists && element.isHittable) {
      scroller.swipeUp()
    }
    for _ in 0..<5 where !(element.exists && element.isHittable) {
      scroller.swipeDown()
    }
    return element.exists && element.isHittable
  }
}
