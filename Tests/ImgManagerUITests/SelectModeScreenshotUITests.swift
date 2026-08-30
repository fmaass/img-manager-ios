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

    // Enter Select by LONG-PRESSING a tile rather than through the More menu: the long press is
    // the entry every idiom shares, while the menu's own item does not surface identically on
    // both (on Regular-3 the popover's command is not addressable the way Compact's is — noted
    // for P5a, which owns that menu). Long-press enters Select WITH that tile selected.
    firstTile.press(forDuration: 1.0)

    let caption = app.staticTexts["selectModeCaption"]
    XCTAssertTrue(
      caption.waitForExistence(timeout: 10),
      "Select mode is active but no mode row is on screen — the only way out would be the "
        + "More menu, which is the discoverability defect this phase closes.")
    XCTAssertEqual(caption.label, "1 selected", "A long press enters Select with that tile chosen.")

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
