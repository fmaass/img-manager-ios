import XCTest

/// IMGMGR-551 (R3-7) on the DEBUG stub fixture, both destinations: Arrange › Layout › Square lays
/// the grid out in square cells with 1-pt gutters at the 120 step, and every way of marking a
/// photograph still writes exactly ONE mark request in that layout.
///
/// Fixture facts (`DebugStubTransport.swift`, `fixtureImages`): photographs 2, 3 and 4 are
/// unmarked (1 is a pick); photograph 4 is a 3.5:1 panorama; the fixture launches on the 200 step
/// in the justified layout. Every fixture proxy is `ok` and no photograph is tombstoned, so there
/// is no placeholder or tombstone cell to measure here — that geometry is the unit suite's
/// (`SquareGridLayoutTests.placeholdersKeepTheirReasonAndTheRowItsEdge`); this suite measures the
/// drawn cells. Mark writes are read from `debugProbe.gridMarks` (the fixture transport's count).
final class SquareLayoutUITests: OrientationPinnedUITestCase {

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
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// Polls `element`'s value until `predicate` holds.
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

  /// The MARK part of a spoken value. `QuickPickCorner.accessibilityValue` appends the photograph's
  /// other statuses ("Not picked, Edited" — the fixture edits every third photograph), so only the
  /// first comma-separated part is the mark, compared whole: "Picked" never matches "Not picked".
  private func mark(_ value: String) -> String {
    String(value.split(separator: ",").first ?? "").trimmingCharacters(in: .whitespaces)
  }

  private func mark(of element: XCUIElement) -> String {
    mark((element.value as? String) ?? "")
  }

  /// Polls until `element`'s mark reads `expected`; returns the mark it last read.
  private func waitForMark(_ element: XCUIElement, _ expected: String) -> String {
    mark(waitForValue(element) { mark($0) == expected })
  }

  /// The fixture transport's mark-write count (`markWrites=<n>`).
  private func markWrites(_ app: XCUIApplication) throws -> Int {
    let probe = element(app, "debugProbe.gridMarks")
    XCTAssertTrue(probe.waitForExistence(timeout: 10), "The grid has no 'debugProbe.gridMarks'.")
    let value = (probe.value as? String) ?? ""
    return try XCTUnwrap(
      Int(value.replacingOccurrences(of: "markWrites=", with: "")),
      "'debugProbe.gridMarks' is unreadable: \(value).")
  }

  /// Exactly one write after `before`: waits for `before + 1`, then holds for two seconds so a
  /// second write still in flight is seen rather than missed.
  private func assertOneWrite(_ app: XCUIApplication, after before: Int, _ action: String) throws {
    let probe = element(app, "debugProbe.gridMarks")
    let expected = "markWrites=\(before + 1)"
    XCTAssertEqual(
      waitForValue(probe) { $0 == expected }, expected, "\(action) did not write one mark.")
    Thread.sleep(forTimeInterval: 2)
    XCTAssertEqual(try markWrites(app), before + 1, "\(action) wrote more than one mark.")
  }

  /// Arrange › Layout › Square, then Thumbnail size › 120, then Done — the popover rows
  /// `GridChromeWiringUITests` drives, through the shared opener and reveal.
  private func chooseSquareAt120(_ app: XCUIApplication) {
    let control = element(app, "gridArrangeControl")
    XCTAssertTrue(control.waitForExistence(timeout: 10), "No 'gridArrangeControl' in the chrome.")
    let square = element(app, "arrange.layout.square")
    XCTAssertTrue(
      openPresentation(control, revealing: square, timeout: 10),
      "The Arrange popover did not open.")
    for identifier in ["arrange.layout.square", "arrange.size.120"] {
      let row = element(app, identifier)
      XCTAssertTrue(revealInArrange(row, in: app), "'\(identifier)' is not reachable.")
      row.tap()
      XCTAssertEqual(
        waitForValue(row) { $0 == "Checked" }, "Checked", "'\(identifier)' did not check.")
    }
    let done = element(app, "arrangeDone")
    XCTAssertTrue(revealInArrange(done, in: app), "The Arrange popover's Done is not reachable.")
    done.tap()
    XCTAssertTrue(square.waitForNonExistence(timeout: 5), "Done did not close the Arrange popover.")

    let probe = element(app, "debugProbe.gridChrome")
    let value = waitForValue(probe) { $0.hasPrefix("gutter=1;") && $0.hasSuffix(";layout=square") }
    XCTAssertTrue(value.hasPrefix("gutter=1;"), "The probe reads \(value), not the 120 gutter.")
    XCTAssertTrue(value.hasSuffix(";layout=square"), "The probe reads \(value), not Square.")
  }

  func testSquareDrawsEqualSquareCellsWithOnePointGutters() throws {
    let app = launchedApp()
    let probe = element(app, "debugProbe.gridChrome")
    XCTAssertTrue(
      waitForValue(probe) { $0.hasSuffix(";layout=justified") }.hasSuffix(";layout=justified"),
      "The fixture does not launch in the justified layout.")
    chooseSquareAt120(app)

    let tiles = (1...4).map { element(app, "gridTile-\($0)") }
    for (index, tile) in tiles.enumerated() {
      XCTAssertTrue(tile.waitForExistence(timeout: 15), "Fixture tile \(index + 1) is missing.")
    }
    // The probe flips before the repack settles: poll until tile 1 is square, bounded.
    for _ in 0..<10 where abs(tiles[0].frame.width - tiles[0].frame.height) > 0.5 {
      Thread.sleep(forTimeInterval: 0.5)
    }
    let edge = tiles[0].frame.width
    XCTAssertGreaterThan(edge, 88, "A square cell this small carries no quick-pick corner.")
    for (index, tile) in tiles.enumerated() {
      // Landscape (1), square (2), portrait (3) and the 3.5:1 panorama (4): one square edge.
      XCTAssertEqual(tile.frame.width, edge, accuracy: 0.5, "Tile \(index + 1): \(tile.frame)")
      XCTAssertEqual(tile.frame.height, edge, accuracy: 0.5, "Tile \(index + 1): \(tile.frame)")
    }
    XCTAssertEqual(tiles[0].frame.midY, tiles[1].frame.midY, accuracy: 1, "1 and 2 share a row.")
    XCTAssertEqual(
      tiles[1].frame.minX - tiles[0].frame.maxX, 1, accuracy: 0.5,
      "The rendered gutter in Square at 120 is not 1 pt.")
  }

  func testEveryMarkGestureWritesExactlyOneMarkInSquare() throws {
    let app = launchedApp()
    chooseSquareAt120(app)
    let close = app.buttons["loupeBack"]

    // (a) Tap to Pick latched, then a tile tap — photograph 2, unpicked.
    let toggle = app.buttons["gridTapToPickToggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10), "No Tap to Pick toggle on the bar.")
    let corner2 = element(app, "tileMarkCorner-2")
    XCTAssertTrue(corner2.waitForExistence(timeout: 15), "Photograph 2 carries no corner.")
    XCTAssertEqual(mark(of: corner2), "Not picked")
    toggle.tap()
    XCTAssertTrue(
      app.staticTexts["lockModeCaption"].waitForExistence(timeout: 10),
      "Tap to Pick did not latch the Pick Lock.")
    var before = try markWrites(app)
    element(app, "gridTile-2").tap()
    XCTAssertEqual(waitForMark(corner2, "Picked"), "Picked", "The latched tap missed.")
    XCTAssertFalse(close.exists, "A latched tap opened the loupe.")
    try assertOneWrite(app, after: before, "A latched tile tap")
    toggle.tap()
    XCTAssertTrue(
      app.staticTexts["lockModeCaption"].waitForNonExistence(timeout: 10),
      "A second press on Tap to Pick did not exit the lock.")

    // (b) The quick-pick corner one-shot — photograph 3, unpicked.
    let corner3 = element(app, "tileMarkCorner-3")
    XCTAssertTrue(corner3.waitForExistence(timeout: 15), "Photograph 3 carries no corner.")
    XCTAssertEqual(mark(of: corner3), "Not picked")
    before = try markWrites(app)
    corner3.tap()
    XCTAssertEqual(waitForMark(corner3, "Picked"), "Picked", "The corner tap missed.")
    XCTAssertFalse(close.exists, "The corner tap opened the loupe.")
    try assertOneWrite(app, after: before, "A corner tap")

    // (c) Hardware `p` on the focused tile — photograph 4, unpicked. A tap on an unfocused tile
    // focuses it; should a destination open the loupe instead, it is closed again.
    let corner4 = element(app, "tileMarkCorner-4")
    XCTAssertTrue(corner4.waitForExistence(timeout: 15), "Photograph 4 carries no corner.")
    XCTAssertEqual(mark(of: corner4), "Not picked")
    element(app, "gridTile-4").tap()
    if close.waitForExistence(timeout: 2) { close.tap() }
    let pick = app.buttons["gridPickButton"]
    XCTAssertEqual(waitForMark(pick, "Not picked"), "Not picked", "Photograph 4 is not focused.")
    before = try markWrites(app)
    // A press that never arrived wrote nothing, so it is pressed again only while the count has
    // not moved (the `SilentKeysUITests` retry: the first press can precede key registration).
    var presses = 0
    while presses < 3, try markWrites(app) == before {
      app.typeKey("p", modifierFlags: [])
      presses += 1
      _ = waitForValue(element(app, "debugProbe.gridMarks"), timeout: 3) {
        $0 != "markWrites=\(before)"
      }
    }
    XCTAssertEqual(waitForMark(corner4, "Picked"), "Picked", "`p` did not pick 4.")
    try assertOneWrite(app, after: before, "Hardware p")
  }
}
