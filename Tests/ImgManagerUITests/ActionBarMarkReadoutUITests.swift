import XCTest

/// IMGMGR-474 (owner report, iPad, build 19): "if you select Pick it should show that it is
/// selected". Drives the shipped path on the DEBUG fixture — focus a tile, press the bar's Pick —
/// and reads the RENDERED control's selected trait and value, not a re-derivation of them. The
/// same UI target runs on the iPad and iPhone destinations; Pick and Dislike never fold into the
/// More menu at any tier, so both controls exist on both.
final class ActionBarMarkReadoutUITests: OrientationPinnedUITestCase {

  func testBarPickShowsTheFocusedPhotographIsPicked() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    let pick = app.buttons["gridPickButton"]
    let dislike = app.buttons["gridDislikeButton"]
    XCTAssertTrue(
      pick.waitForExistence(timeout: 30),
      "Action bar (gridPickButton) never appeared — expected the DEBUG fixture composition's "
        + "populated grid, got something else (sign-in screen, blank screen, failed stub).")

    // Fixture photograph 2 (`DebugStubTransport.fixtureImages`, index 1) is UNMARKED. Addressed
    // by its own identifier, never by coordinates. The first tap moves focus; if focus already
    // sat there the tap opened the loupe instead, which Close leaves with focus kept.
    let tile = app.descendants(matching: .any).matching(identifier: "gridTile-2").firstMatch
    XCTAssertTrue(tile.waitForExistence(timeout: 15), "Fixture tile `gridTile-2` never appeared.")
    tile.tap()
    let close = app.buttons["loupeBack"]
    if close.waitForExistence(timeout: 2) { close.tap() }
    XCTAssertTrue(pick.waitForExistence(timeout: 10), "The bar is gone after focusing a tile.")

    XCTAssertFalse(pick.isSelected, "An unmarked focused photograph must not light Pick.")
    XCTAssertEqual(pick.value as? String, "Not picked")

    pick.tap()

    let selected = expectation(
      for: NSPredicate(format: "isSelected == true"), evaluatedWith: pick)
    wait(for: [selected], timeout: 10)
    attach(name: "bar-pick-readout")
    XCTAssertEqual(
      pick.value as? String, "Picked", "The bar must SAY the focused photograph is picked.")
    XCTAssertFalse(dislike.isSelected, "Only the carried mark's control is selected.")
    // A readout, not a latch: one press never draws the lock's mode row.
    XCTAssertFalse(
      app.staticTexts["lockModeCaption"].exists,
      "One Pick press must not latch — the selected state here is the mark, not a mode.")
  }

  private func attach(name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
