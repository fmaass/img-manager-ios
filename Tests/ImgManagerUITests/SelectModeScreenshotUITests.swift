import XCTest

/// WP13 P1 (IMGMGR-212): the retained visual evidence the phase's Verification asks for — the
/// Select mode row carrying a NON-ZERO count with the Pick control live. Runs on both gate
/// destinations, so one test yields the `.compact` (iPhone) and `.regular3` (iPad) captures.
///
/// It selects real tiles through their accessibility identifier rather than by screen
/// coordinate: a screenshot test that taps at fractions of the window proves nothing
/// reproducibly, and this file is the reason `TileView` carries a handle at all.
final class SelectModeScreenshotUITests: XCTestCase {
  func testSelectModeRowShowsANonZeroCountWithPickEnabled() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    let moreMenu = app.buttons["gridMoreMenu"]
    XCTAssertTrue(
      moreMenu.waitForExistence(timeout: 30),
      "The grid action bar never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else (sign-in, blank, or a failed stub).")
    // Two DIFFERENT photographs, addressed by the fixture's own ids (`DebugStubTransport`
    // serves ids 1...12) rather than by bound index: one tile surfaces as several
    // accessibility elements, so an index-addressed pair can be the same photograph twice.
    let firstTile = app.descendants(matching: .any).matching(identifier: "gridTile-1").firstMatch
    let secondTile = app.descendants(matching: .any).matching(identifier: "gridTile-2").firstMatch
    XCTAssertTrue(firstTile.waitForExistence(timeout: 10), "No grid tiles to select.")

    // Enter Select. The long press is the GESTURE and the More menu is its CHROME TWIN; the
    // phase's rule is that both exist, and this test takes whichever the idiom under test
    // actually delivers. Compact takes the long press. On Regular-3 it does not arrive — the
    // pointer-drag recognizer installed over the grid claims it — so the twin is used there,
    // which is exactly what a chrome twin is for.
    let caption = app.staticTexts["selectModeCaption"]
    firstTile.press(forDuration: 1.0)
    if !caption.waitForExistence(timeout: 5) {
      moreMenu.tap()
      let selectCommand = app.descendants(matching: .any)
        .matching(identifier: "gridSelectCommand").firstMatch
      guard selectCommand.waitForExistence(timeout: 10) else {
        // Regular-3 only, and a HARNESS limit rather than a product finding: the long press
        // does not arrive, and the More menu's popover content is not addressable from
        // XCUITest even with an identifier on the item (three gate runs: label query, then
        // identifier query, then both). The Compact leg below asserts the row in full, and the
        // store-level suite pins the same behaviour on both destinations. Skipping is honest
        // here; asserting nothing would be a test that passes with the feature removed.
        throw XCTSkip(
          "Select mode is not reachable from XCUITest on this destination "
            + "(long press swallowed, More-menu popover items not addressable). "
            + "Compact carries this capture; see the phase report's OPEN items.")
      }
      selectCommand.tap()
      XCTAssertTrue(
        caption.waitForExistence(timeout: 10),
        "Select mode is active but no mode row is on screen — the only way out would be the "
          + "More menu, which is the discoverability defect this phase closes.")
      // The menu entry starts EMPTY (unlike the long press, which selects what it pressed).
      XCTAssertEqual(caption.label, "0 selected", "An explicit Select entry starts empty.")
      firstTile.tap()
    }
    XCTAssertEqual(caption.label, "1 selected", "One photograph is chosen at this point.")

    XCTAssertTrue(secondTile.waitForExistence(timeout: 5), "The second fixture tile is missing.")
    secondTile.tap()

    // Attached BEFORE the assertions below, so the run keeps its visual evidence whatever the
    // verdict is — a failing capture is the more interesting one.
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "Select-mode-row-two-selected"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertEqual(
      caption.label, "2 selected",
      "The mode row must state the count of what the next mark would write to.")
    XCTAssertTrue(
      app.buttons["Pick"].isEnabled,
      "Pick must be live in Select mode — it is the whole point of the phase; only Pick LOCK "
        + "entry stays disabled there.")
  }
}
