import XCTest

/// WP31 P1 (IMGMGR-460) acceptance: the iPhone Triage screen. Each swipe direction has a visible
/// chrome twin; Skip writes nothing to the server; Pick and Dislike write once and the grid shows
/// the mark; Undo steps back.
///
/// Launch fixture: `-UITestStubGrid`. The fixture's folder opens on its own; photograph 1 is
/// picked and 2 is unmarked, so Triage starts on photograph 2 (plan decision 2). Server writes are
/// read off `debugProbe.marks` — an element INSIDE the Triage cover, because the grid's own probes
/// are under it (`DebugProbe.markWrites`, counted by the fixture transport for every
/// `POST /api/marks/state`).
///
/// Compact only: on the iPad destination the Regular split renders and Triage has no entry, so
/// every test skips there with that reason.
final class TriageUITests: OrientationPinnedUITestCase {

  // MARK: - (1) the three twins

  func testEachSwipeDirectionHasAVisibleTwin() throws {
    let app = try launchedCompactGrid()
    openTriage(app)
    for identifier in ["triageDislike", "triageSkip", "triagePick"] {
      let control = element(app, identifier)
      XCTAssertTrue(
        control.waitForExistence(timeout: 10), "Triage carries no '\(identifier)' control.")
      XCTAssertTrue(control.isHittable, "'\(identifier)' is not hittable while Triage is open.")
    }
    XCTAssertTrue(element(app, "triageUndo").exists, "Triage carries no Undo control.")
    attach(name: "IMGMGR-460-triage-open")
  }

  // MARK: - (2) Skip, by swipe and by twin, writes nothing

  func testSkipBySwipeAndByTwinAdvancesWithoutAWrite() throws {
    let app = try launchedCompactGrid()
    openTriage(app)
    let start = try XCTUnwrap(position(app), "Triage shows no 'i of N' position.")
    let writes = try settledMarkWrites(app)

    waitForShownPhotograph(app)
    element(app, "triagePhoto").swipeUp()
    XCTAssertTrue(
      waitForPosition(app, start + 1), "swipeUp did not advance from \(start) (Skip by swipe).")
    tapWhenShown(app, "triageSkip")
    XCTAssertTrue(
      waitForPosition(app, start + 2), "The Skip button did not advance from \(start + 1).")

    XCTAssertEqual(try settledMarkWrites(app), writes, "Skip wrote to the server.")
  }

  // MARK: - (3) swipe right picks, (4) swipe left dislikes

  func testSwipeRightPicksWithOneWrite() throws {
    try assertSwipe(right: true, shows: "Picked")
  }

  func testSwipeLeftDislikesWithOneWrite() throws {
    try assertSwipe(right: false, shows: "Disliked")
  }

  // MARK: - (5) Undo

  func testUndoStepsBackAfterASkipAndAfterAPick() throws {
    let app = try launchedCompactGrid()
    openTriage(app)
    let start = try XCTUnwrap(position(app), "Triage shows no 'i of N' position.")
    let imageID = try XCTUnwrap(photographID(app), "The Triage photograph names no file.")
    let writes = try settledMarkWrites(app)
    let undo = element(app, "triageUndo")

    // After a Skip: back to the start, and no write.
    tapWhenShown(app, "triageSkip")
    XCTAssertTrue(waitForPosition(app, start + 1), "Skip did not advance from \(start).")
    undo.tap()
    XCTAssertTrue(waitForPosition(app, start), "Undo after a Skip did not step back.")
    XCTAssertEqual(try settledMarkWrites(app), writes, "Undo after a Skip wrote to the server.")

    // After a Pick: one write for the Pick, ONE more for the Undo, and back to the start.
    tapWhenShown(app, "triagePick")
    XCTAssertTrue(waitForPosition(app, start + 1), "Pick did not advance from \(start).")
    XCTAssertTrue(waitForMarkWrites(app, writes + 1), "Pick did not write exactly once.")
    XCTAssertTrue(
      waitFor("isEnabled == true", undo), "Undo is not enabled after a Pick in this pass.")
    undo.tap()
    XCTAssertTrue(waitForPosition(app, start), "Undo after a Pick did not step back.")
    XCTAssertTrue(waitForMarkWrites(app, writes + 2), "Undo after a Pick did not write once.")
    XCTAssertEqual(try settledMarkWrites(app), writes + 2)

    closeTriage(app)
    let corner = element(app, "tileMarkCorner-\(imageID)")
    XCTAssertTrue(corner.waitForExistence(timeout: 15), "No corner on photograph \(imageID).")
    XCTAssertTrue(
      waitFor("value BEGINSWITH 'Not picked'", corner),
      "Undo did not clear the Pick; the corner reads \(String(describing: corner.value)).")
  }

  // MARK: - Shared

  private func assertSwipe(right: Bool, shows expected: String) throws {
    let app = try launchedCompactGrid()
    openTriage(app)
    let start = try XCTUnwrap(position(app), "Triage shows no 'i of N' position.")
    let imageID = try XCTUnwrap(photographID(app), "The Triage photograph names no file.")
    let writes = try settledMarkWrites(app)

    let photo = element(app, "triagePhoto")
    waitForShownPhotograph(app)
    if right {
      photo.swipeRight()
    } else {
      photo.swipeLeft()
    }
    XCTAssertTrue(
      waitForPosition(app, start + 1), "The swipe did not advance from \(start) (\(expected)).")
    XCTAssertTrue(
      waitForMarkWrites(app, writes + 1), "The swipe did not write once (\(expected)).")
    XCTAssertEqual(try settledMarkWrites(app), writes + 1, "The swipe wrote more than once.")

    closeTriage(app)
    let corner = element(app, "tileMarkCorner-\(imageID)")
    XCTAssertTrue(corner.waitForExistence(timeout: 15), "No corner on photograph \(imageID).")
    XCTAssertTrue(
      waitFor("value BEGINSWITH '\(expected)'", corner),
      "Photograph \(imageID) does not read \(expected) after closing Triage; the corner reads "
        + "\(String(describing: corner.value)).")
    attach(name: "IMGMGR-460-after-\(expected.lowercased())")
  }

  private func launchedCompactGrid() throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    XCTAssertTrue(
      app.buttons["gridPickButton"].waitForExistence(timeout: 30),
      "Action bar (gridPickButton) never appeared — expected the DEBUG fixture composition's "
        + "populated grid, got something else (sign-in screen, blank screen, failed stub).")
    guard rendersCompactShell(app) else {
      throw XCTSkip("Regular width: Triage is Compact-only; the iPad culls in the loupe.")
    }
    return app
  }

  private func openTriage(_ app: XCUIApplication) {
    // IMGMGR-462: Triage lives in the Compact options row, not the navigation bar.
    let entry = app.descendants(matching: .any)["gridTriageButton"].firstMatch
    XCTAssertTrue(
      entry.waitForExistence(timeout: 15), "No 'gridTriageButton' in the grid's options row.")
    XCTAssertTrue(waitFor("isEnabled == true", entry), "Triage is disabled on a populated grid.")
    entry.tap()
    XCTAssertTrue(
      element(app, "triagePosition").waitForExistence(timeout: 15), "Triage did not open.")
    waitForShownPhotograph(app)
  }

  /// Review B1: decisions are inert until the cursor's preview is the one on screen, so every
  /// decision waits for it — the photograph's value names its file only once it is shown.
  private func waitForShownPhotograph(_ app: XCUIApplication) {
    XCTAssertTrue(
      waitFor("isEnabled == true", element(app, "triageSkip"), timeout: 15),
      "The cursor's photograph was never shown, so no decision became possible.")
    XCTAssertTrue(
      waitFor("value BEGINSWITH 'STUB_'", element(app, "triagePhoto")),
      "The shown photograph names no file.")
  }

  private func tapWhenShown(_ app: XCUIApplication, _ identifier: String) {
    waitForShownPhotograph(app)
    element(app, identifier).tap()
  }

  private func closeTriage(_ app: XCUIApplication) {
    element(app, "triageBack").tap()
    XCTAssertTrue(
      waitFor("exists == false", element(app, "triagePosition")), "Back did not close Triage.")
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func waitFor(_ format: String, _ element: XCUIElement, timeout: TimeInterval = 10)
    -> Bool
  {
    let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
    return XCTWaiter.wait(for: [done], timeout: timeout) == .completed
  }

  /// The cursor's index, off "i of N".
  private func position(_ app: XCUIApplication) -> Int? {
    numbers(in: element(app, "triagePosition").label).first
  }

  private func waitForPosition(_ app: XCUIApplication, _ expected: Int) -> Bool {
    waitFor("label BEGINSWITH '\(expected) of '", element(app, "triagePosition"))
  }

  /// The photograph on screen, off its file name ("STUB_0002.jpg" is photograph 2).
  private func photographID(_ app: XCUIApplication) -> Int? {
    numbers(in: (element(app, "triagePhoto").value as? String) ?? "").first
  }

  private func markWrites(_ app: XCUIApplication) -> Int? {
    numbers(in: (element(app, "debugProbe.marks").value as? String) ?? "").first
  }

  private func readMarkWrites(_ app: XCUIApplication) throws -> Int {
    let value = element(app, "debugProbe.marks").value as? String
    return try XCTUnwrap(
      markWrites(app), "'debugProbe.marks' is unreadable: \(String(describing: value)).")
  }

  private func waitForMarkWrites(_ app: XCUIApplication, _ expected: Int) -> Bool {
    waitFor("value == 'markWrites=\(expected)'", element(app, "debugProbe.marks"))
  }

  /// The write count once it has not moved for two seconds — so a write still in flight is never
  /// mistaken for "no write". An unreadable probe THROWS (review A3): two unreadable readings
  /// must never compare equal and pass a no-write assertion vacuously.
  private func settledMarkWrites(_ app: XCUIApplication) throws -> Int {
    XCTAssertTrue(
      element(app, "debugProbe.marks").waitForExistence(timeout: 10),
      "No 'debugProbe.marks' inside the Triage cover.")
    let deadline = Date(timeIntervalSinceNow: 15)
    var last = try readMarkWrites(app)
    var stableSince = Date()
    while Date() < deadline {
      Thread.sleep(forTimeInterval: 0.5)
      let now = try readMarkWrites(app)
      if now != last {
        last = now
        stableSince = Date()
      } else if Date().timeIntervalSince(stableSince) >= 2 {
        break
      }
    }
    return last
  }

  private func numbers(in text: String) -> [Int] {
    text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
  }

  private func attach(name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
