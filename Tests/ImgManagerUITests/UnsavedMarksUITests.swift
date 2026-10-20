import XCTest

/// IMGMGR-586 (owner, 2026-10-20: picks made on one device never reached the server): a pick
/// whose write fails is never silent. The DEBUG fixture refuses the first mark write
/// (`-UITestFailMarkWrites 1`, a 503 as from a server that has gone away) and accepts the rest,
/// so the test reads what RENDERED — the banner, the corner's spoken status — and what reached
/// the wire (`debugProbe.markRequests`, where a refused write is logged `failed:`).
final class UnsavedMarksUITests: OrientationPinnedUITestCase {

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func waitFor(_ format: String, _ element: XCUIElement, timeout: TimeInterval = 10)
    -> Bool
  {
    let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
    return XCTWaiter.wait(for: [done], timeout: timeout) == .completed
  }

  private func attach(name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testAFailedPickIsNamedWithItsCountAndRetrySavesIt() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestFailMarkWrites", "1"]
    app.launch()

    let corner = element(app, "tileMarkCorner-2")
    XCTAssertTrue(
      corner.waitForExistence(timeout: 30),
      "Photograph 2 carries no quick-pick corner (`tileMarkCorner-2`) — expected the DEBUG "
        + "fixture's populated grid, got something else (sign-in screen, blank screen, "
        + "failed stub).")
    XCTAssertEqual(corner.value as? String, "Not picked", "Fixture photograph 2 starts unmarked.")
    let requests = element(app, "debugProbe.markRequests")

    corner.tap()

    // The write reached the wire and was refused...
    XCTAssertTrue(
      waitFor("value == 'markRequests=failed:pick:2'", requests),
      "The pick never reached the wire as one refused write; the log reads "
        + "\(String(describing: requests.value)).")
    // ...so the tile is back on server truth, and the reader is TOLD, with the count.
    let message = element(app, "unsavedMarksMessage")
    XCTAssertTrue(
      message.waitForExistence(timeout: 10),
      "A failed pick left no visible signal: no `unsavedMarksMessage` on screen.")
    XCTAssertTrue(
      waitFor("label CONTAINS \"1 pick didn't save\"", message),
      "The banner must name how many picks did not save; it reads '\(message.label)'.")
    XCTAssertTrue(
      waitFor("value == 'Not picked'", corner), "The refused pick was not rolled back.")
    attach(name: "IMGMGR-586-unsaved-pick")

    // The server is back: Retry re-sends the same write, it lands, and the banner goes.
    let retry = app.buttons["unsavedMarksRetry"]
    XCTAssertTrue(retry.waitForExistence(timeout: 5), "The banner offers no Retry.")
    retry.tap()
    XCTAssertTrue(
      waitFor("value == 'markRequests=failed:pick:2|pick:2'", requests),
      "Retry did not re-send the failed pick; the log reads "
        + "\(String(describing: requests.value)).")
    XCTAssertTrue(waitFor("value == 'Picked'", corner), "The retried pick does not show as saved.")
    XCTAssertTrue(
      waitFor("exists == false", message), "The banner outlived the write that saved the pick.")
    attach(name: "IMGMGR-586-retried-pick")
  }
}
