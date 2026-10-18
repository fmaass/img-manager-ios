import XCTest

/// IMGMGR-539 wiring, on the DEBUG stub fixture: the gutter the grid RENDERS follows the size step
/// (R3-12: 1 pt at 120, 2 pt at 200 — measured between two adjacent tiles' real frames), and the
/// Tile overlays toggles change the badges a tile DRAWS (R3-5). A tile's badges merge into its
/// ONE `gridTile-<id>` element, so a fixture run reads them from that element's value
/// (`badges=<item>,<item>`, the same capped list the tile draws). `debugProbe.gridChrome` is
/// corroboration only.
///
/// Fixture facts (`DebugStubTransport.swift`, `fixtureImages`): tile 1 is a pick with an edit and
/// Lightroom rating 0; tile 4 has an edit, no mark and rating 3. Tiles 1 and 2 share the first
/// row at both steps on every destination. The fixture launches on the 200 step.
final class GridChromeWiringUITests: OrientationPinnedUITestCase {

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "The DEBUG fixture grid never rendered its action bar.")
    return app
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  /// Polls `element`'s value until `predicate` holds (frames and values are re-read per access).
  private func waitForValue(
    _ element: XCUIElement, timeout: TimeInterval = 10, _ predicate: (String) -> Bool
  ) -> String {
    let deadline = Date(timeIntervalSinceNow: timeout)
    var value = (element.value as? String) ?? ""
    while !predicate(value) && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.25)
      value = (element.value as? String) ?? ""
    }
    return value
  }

  /// The horizontal gap between tiles 1 and 2 as rendered.
  private func renderedGap(_ app: XCUIApplication) -> CGFloat {
    let first = element(app, "gridTile-1")
    let second = element(app, "gridTile-2")
    XCTAssertTrue(first.waitForExistence(timeout: 15), "The fixture's first tile is missing.")
    XCTAssertTrue(second.waitForExistence(timeout: 15), "The fixture's second tile is missing.")
    XCTAssertEqual(
      first.frame.midY, second.frame.midY, accuracy: 1,
      "Tiles 1 and 2 are not in one row: \(first.frame) vs \(second.frame).")
    return second.frame.minX - first.frame.maxX
  }

  func testGutterFollowsTheSizeStep() throws {
    let app = launchedApp()
    let probe = element(app, "debugProbe.gridChrome")

    // The 200 step (launch): 2 pt.
    XCTAssertEqual(renderedGap(app), 2, accuracy: 0.5, "The rendered gutter at 200 is not 2 pt.")
    XCTAssertTrue(waitForValue(probe) { $0.hasPrefix("gutter=2;") }.hasPrefix("gutter=2;"))

    // The 120 step, chosen through the Arrange popover: 1 pt.
    let control = element(app, "gridArrangeControl")
    XCTAssertTrue(control.waitForExistence(timeout: 10), "No 'gridArrangeControl' in the chrome.")
    let row = element(app, "arrange.size.120")
    XCTAssertTrue(
      openPresentation(control, revealing: row, timeout: 10), "The Arrange popover did not open.")
    XCTAssertTrue(revealInArrange(row, in: app), "'arrange.size.120' is not reachable.")
    row.tap()
    let done = element(app, "arrangeDone")
    XCTAssertTrue(revealInArrange(done, in: app), "The Arrange popover's Done is not reachable.")
    done.tap()
    XCTAssertTrue(row.waitForNonExistence(timeout: 5), "Done did not close the Arrange popover.")

    XCTAssertTrue(waitForValue(probe) { $0.hasPrefix("gutter=1;") }.hasPrefix("gutter=1;"))
    // The probe flips before the repack settles: poll the measured gap, bounded.
    var gap = renderedGap(app)
    for _ in 0..<10 where abs(gap - 1) > 0.5 {
      Thread.sleep(forTimeInterval: 0.5)
      gap = renderedGap(app)
    }
    XCTAssertEqual(gap, 1, accuracy: 0.5, "The rendered gutter at 120 is not 1 pt.")
  }

  func testTileOverlaysChangeTheDrawnBadges() throws {
    let app = launchedApp()
    let pickTile = element(app, "gridTile-1")
    let ratedTile = element(app, "gridTile-4")
    XCTAssertTrue(pickTile.waitForExistence(timeout: 15), "The fixture's tile 1 is missing.")

    // Defaults: Marks and Edited on.
    XCTAssertEqual(waitForValue(pickTile) { $0 == "badges=pick,edited" }, "badges=pick,edited")

    // Marks off: the pick badge is no longer drawn, Edited stays.
    let marks = element(app, "gridMoreMenu.more.overlayMarks")
    XCTAssertTrue(openTileOverlays(in: app, revealing: marks, timeout: 5), "No Marks overlay row.")
    marks.tap()
    XCTAssertEqual(waitForValue(pickTile) { $0 == "badges=edited" }, "badges=edited")

    // Marks back on: the pick badge returns.
    XCTAssertTrue(openTileOverlays(in: app, revealing: marks, timeout: 5))
    marks.tap()
    XCTAssertEqual(waitForValue(pickTile) { $0 == "badges=pick,edited" }, "badges=pick,edited")

    // Lightroom rating on: tile 4 draws ★3 beside its edit badge; tile 1 (rating 0) gains none.
    let rating = element(app, "gridMoreMenu.more.overlayLightroomRating")
    XCTAssertTrue(
      openTileOverlays(in: app, revealing: rating, timeout: 5), "No Lightroom rating overlay row.")
    rating.tap()
    XCTAssertTrue(ratedTile.waitForExistence(timeout: 15), "The fixture's tile 4 is missing.")
    let expected = "badges=edited,lightroomRating(★3)"
    XCTAssertEqual(waitForValue(ratedTile) { $0 == expected }, expected)
    XCTAssertEqual(pickTile.value as? String, "badges=pick,edited")

    let probe = element(app, "debugProbe.gridChrome")
    XCTAssertTrue(
      waitForValue(probe) { $0.hasSuffix("overlays=marks,edited,lightroomRating") }
        .hasSuffix("overlays=marks,edited,lightroomRating"))

    // Lightroom rating back off, as the Filename plates test restores its toggle: the choice is
    // stored in the simulator's defaults, and every later suite in the run would otherwise
    // launch with rated tiles.
    XCTAssertTrue(openTileOverlays(in: app, revealing: rating, timeout: 5))
    rating.tap()
    XCTAssertEqual(waitForValue(ratedTile) { $0 == "badges=edited" }, "badges=edited")
  }

  /// Scrolls the Arrange popover's own scroll view until `element` is hittable (the
  /// `ArrangePopoverUITests` reveal). Scrolling is not a tap: it chooses nothing.
  private func revealInArrange(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
    if element.exists && element.isHittable { return true }
    let scroller = app.scrollViews.containing(.any, identifier: "arrange.sort.date_taken")
      .firstMatch
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

extension XCTestCase {
  /// IMGMGR-539: More › View › Tile overlays ▸, opened through the shared opener twice — the
  /// More menu revealing the submenu row, then the submenu revealing `expected`.
  func openTileOverlays(
    in app: XCUIApplication, revealing expected: XCUIElement, timeout: TimeInterval
  ) -> Bool {
    let submenu = app.descendants(matching: .any)["gridMoreMenu.more.tileOverlays"]
    guard openMoreMenu(in: app, revealing: submenu, timeout: timeout) else { return false }
    return openPresentation(submenu, revealing: expected, timeout: timeout)
  }
}
