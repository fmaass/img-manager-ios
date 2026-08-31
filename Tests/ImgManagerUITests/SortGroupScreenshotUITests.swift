import XCTest

/// WP13 P5b (IMGMGR-221 part 2) acceptance, on the real thing. The ticket's own AC is "the grid
/// sort menu offers the web's sort keys and the group-by dimensions … nothing gesture-only", and
/// the phase's verification asks for two screenshots: the Sort menu OPEN, and a grouped grid with
/// visible section headers — on both layouts the gate runs.
///
/// Makes NO device-idiom decision (plan invariant (i)): every step keys off an observed element,
/// so the same test runs on Compact's options row and on Regular's `.primaryAction` toolbar.
final class SortGroupScreenshotUITests: XCTestCase {

  /// PORTRAIT, pinned on the way in AND restored on the way out — device orientation is
  /// simulator-global and survives across test classes (the lesson `ViewOptionsScreenshotUITests`
  /// records after a landscape sibling sorted before it).
  override func setUp() {
    super.setUp()
    XCUIDevice.shared.orientation = .portrait
  }

  override func tearDown() {
    XCUIDevice.shared.orientation = .portrait
    super.tearDown()
  }

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

  func testSortControlIsOnAPrimarySurfaceAndItsMenuOpens() throws {
    let app = launchedApp()

    let sort = app.descendants(matching: .any)["gridSortControl"]
    XCTAssertTrue(
      sort.waitForExistence(timeout: 10),
      "The Sort control is not on a primary surface — nothing named 'gridSortControl' is in the "
        + "hierarchy without opening an overflow menu.")
    XCTAssertTrue(sort.isHittable, "The Sort control exists but cannot be tapped where it is.")
    // Value-in-label: the current key and direction must be readable at rest, without opening
    // anything — the discoverability half of IMGMGR-221 (gap audit, owner feedback (c)).
    XCTAssertTrue(
      sort.label.contains("Sort:"),
      "Sort control label '\(sort.label)' does not carry its current value.")

    // The Sort control joined three others on the same primary surface, so "did anything get
    // pushed into the overflow" is a real question here rather than a formality. Positive
    // control in the same check (LSN-0033).
    XCTAssertTrue(
      app.buttons["Dislike"].exists,
      "Positive control failed: the Dislike button is gone, so the 0-hit overflow check below "
        + "would pass vacuously.")
    XCTAssertFalse(
      app.buttons["OverflowBarButtonItem"].exists,
      "A toolbar overflow chevron appeared once Sort joined the primary surface — one of the "
        + "view-option controls is now reachable only behind it, which is exactly the state "
        + "IMGMGR-221 exists to end.")

    sort.tap()

    // The six offered keys plus both directions, as menu rows a finger can reach. Names come
    // from `SortKey.title`/`SortDirection.title`; this test holds the only copy outside the app
    // on purpose — a renamed row that never reached the menu fails here.
    for title in ["Date", "Filename", "Rating", "ISO", "Camera", "Lens"] {
      XCTAssertTrue(
        app.buttons[title].waitForExistence(timeout: 5),
        "The open Sort menu has no row named '\(title)'.")
    }
    XCTAssertTrue(app.buttons["Ascending"].exists, "The Sort menu offers no direction rows.")
    XCTAssertTrue(app.buttons["Descending"].exists, "The Sort menu offers no Descending row.")

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "sort-menu-open"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTContext.runActivity(
      named: "Sort label: '\(sort.label)' · captured \(screenshot.image.size)"
    ) { _ in }
  }

  func testGroupingByCameraRendersServerVouchedSectionHeaders() throws {
    let app = launchedApp()

    let group = app.descendants(matching: .any)["gridGroupControl"]
    XCTAssertTrue(
      group.waitForExistence(timeout: 10),
      "Nothing named 'gridGroupControl' is on a primary surface.")
    group.tap()

    let camera = app.buttons["Camera"]
    XCTAssertTrue(
      camera.waitForExistence(timeout: 5),
      "The Group menu offers no 'Camera' dimension — the group-by half of IMGMGR-221 is missing.")
    camera.tap()

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

    // The Group control's own label reports the value back, so the state is readable at rest.
    XCTAssertTrue(
      group.label.contains("Camera"),
      "Group control label '\(group.label)' does not report the chosen dimension.")

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "grouped-grid-section-headers"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTContext.runActivity(
      named: "Headers: \(labels) · Group label: '\(group.label)' · captured "
        + "\(screenshot.image.size)"
    ) { _ in }
  }

  /// IMGMGR-256 (folded into WP13 P11): the Scene-view caption row is gone, and the Group control
  /// itself carries the "you are in an arrangement" state. Runs on both idioms the gate gates —
  /// Compact's options row and Regular's `.primaryAction` toolbar — because the control is one
  /// definition rendered in two places and the state must read the same in both.
  ///
  /// The load-bearing proof that Scene adds no banner row is `GridChromeRowsTests`, which drives
  /// a real Scene page; the fixture transport here serves no `/api/browse/stacks`, so this test
  /// takes the reachable arrangement (a dimension) and asserts the caption identifier is absent
  /// with a positive control beside it.
  func testGroupControlHighlightsWhileAnArrangementIsInForceAndNoSceneBannerExists() throws {
    let app = launchedApp()

    let group = app.descendants(matching: .any)["gridGroupControl"]
    XCTAssertTrue(
      group.waitForExistence(timeout: 10),
      "Nothing named 'gridGroupControl' is on a primary surface.")

    XCTAssertEqual(
      group.value as? String, "Off",
      "The Group control reports itself active under Group: None (label '\(group.label)').")

    let before = XCUIScreen.main.screenshot()
    let beforeAttachment = XCTAttachment(screenshot: before)
    beforeAttachment.name = "group-control-plain-under-none"
    beforeAttachment.lifetime = .keepAlways
    add(beforeAttachment)

    group.tap()
    let camera = app.buttons["Camera"]
    XCTAssertTrue(camera.waitForExistence(timeout: 5), "The Group menu offers no 'Camera' row.")
    camera.tap()

    let grouped = app.descendants(matching: .any)["gridGroupControl"]
    XCTAssertTrue(grouped.waitForExistence(timeout: 10))
    XCTAssertEqual(
      grouped.value as? String, "Active",
      "The Group control does not report itself active while grouping by Camera "
        + "(label '\(grouped.label)').")

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
    XCTContext.runActivity(
      named: "Group control: '\(grouped.label)' value='\(grouped.value as? String ?? "")' · "
        + "captured \(after.image.size)"
    ) { _ in }
  }
}
