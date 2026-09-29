import XCTest

/// IMGMGR-475 (owner, 2026-09-29, options 1 + 2): picking a photograph takes ONE gesture and never
/// takes the second tap away from the loupe. Drives the DEBUG fixture (`DebugStubTransport`:
/// photographs 2 and 3 are unmarked) through the shipped surfaces and reads what RENDERED — the
/// corner's own spoken mark (it carries the badge's meaning, `QuickPickCorner`), the bar's Pick
/// readout (IMGMGR-474) and the lock's mode row — never a re-derivation of them.
final class QuickPickUITests: OrientationPinnedUITestCase {

  private func launchedGrid() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    return app
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

  func testMarkCornerPicksWithoutFocusingOrOpeningTheLoupe() throws {
    let app = launchedGrid()
    let pick = app.buttons["gridPickButton"]
    XCTAssertTrue(
      pick.waitForExistence(timeout: 30),
      "Action bar (gridPickButton) never appeared — expected the DEBUG fixture composition's "
        + "populated grid, got something else (sign-in screen, blank screen, failed stub).")
    let close = app.buttons["loupeClose"]

    // Focus photograph 3 (unmarked) first, so "focus did not move" is readable off the bar.
    let other = element(app, "gridTile-3")
    XCTAssertTrue(other.waitForExistence(timeout: 15), "Fixture tile `gridTile-3` never appeared.")
    other.tap()
    if close.waitForExistence(timeout: 2) { close.tap() }
    XCTAssertEqual(pick.value as? String, "Not picked", "Focused photograph 3 is unmarked.")

    let corner = element(app, "tileMarkCorner-2")
    XCTAssertTrue(
      corner.waitForExistence(timeout: 15),
      "Photograph 2 carries no quick-pick corner (`tileMarkCorner-2`).")
    XCTAssertEqual(corner.value as? String, "Not picked")

    corner.tap()

    XCTAssertTrue(
      waitFor("value == 'Picked'", corner),
      "One tap on the mark corner must pick photograph 2; the corner reads "
        + "\(String(describing: corner.value)).")
    attach(name: "IMGMGR-475-corner-picked")
    XCTAssertFalse(close.exists, "The corner tap opened the loupe — it must never open it.")
    XCTAssertEqual(
      pick.value as? String, "Not picked",
      "The corner tap moved focus: the bar now reads photograph 2 instead of the focused 3.")
    XCTAssertFalse(
      app.staticTexts["lockModeCaption"].exists, "A quick pick must never latch a lock.")

    // Focusing photograph 2 shows its new mark on the bar's Pick (IMGMGR-474's readout).
    element(app, "gridTile-2").tap()
    XCTAssertTrue(
      waitFor("isSelected == true", pick),
      "The bar's Pick must read the quick-picked photograph as picked once it is focused.")
    XCTAssertEqual(pick.value as? String, "Picked")
    XCTAssertFalse(close.exists, "One tap on an unfocused tile only focuses it.")

    // The FOCUSED tile's corner still toggles (pick -> none) and still leaves the loupe alone.
    corner.tap()
    XCTAssertTrue(
      waitFor("isSelected == false", pick),
      "A second corner tap must clear the pick, and the focused bar must say so.")
    XCTAssertEqual(corner.value as? String, "Not picked")
    XCTAssertFalse(close.exists, "The focused tile's corner opened the loupe.")
  }

  func testTapToPickToggleLatchesAndATilePicks() throws {
    let app = launchedGrid()
    let toggle = app.buttons["gridTapToPickToggle"]
    XCTAssertTrue(
      toggle.waitForExistence(timeout: 30),
      "The bar carries no Tap to Pick toggle (`gridTapToPickToggle`).")
    XCTAssertEqual(toggle.label, "Tap to Pick")
    XCTAssertFalse(toggle.isSelected, "Tap to Pick is on before anything latched it.")

    toggle.tap()

    let caption = app.staticTexts["lockModeCaption"]
    XCTAssertTrue(
      caption.waitForExistence(timeout: 10),
      "Tap to Pick did not bring up the Pick Lock mode row.")
    XCTAssertEqual(caption.label, "Pick Lock — tap photos to apply Pick")
    XCTAssertTrue(waitFor("isSelected == true", toggle), "The toggle must read ON while latched.")

    let corner = element(app, "tileMarkCorner-3")
    XCTAssertTrue(corner.waitForExistence(timeout: 15), "Photograph 3 carries no corner.")
    XCTAssertEqual(corner.value as? String, "Not picked")
    element(app, "gridTile-3").tap()
    XCTAssertTrue(
      waitFor("value == 'Picked'", corner),
      "With Tap to Pick on, one tap on a tile must pick it.")
    XCTAssertFalse(app.buttons["loupeClose"].exists, "A latched tap opened the loupe.")
    attach(name: "IMGMGR-475-tap-to-pick")

    toggle.tap()
    XCTAssertTrue(
      waitFor("exists == false", caption), "A second press on Tap to Pick must exit the lock.")
    XCTAssertTrue(waitFor("isSelected == false", toggle), "The toggle still reads ON.")
  }

  private func attach(name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
