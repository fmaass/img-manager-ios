import XCTest

/// WP13 P1 (IMGMGR-212, and the shipped defect IMGMGR-223): the retained visual evidence the
/// phase's Verification asks for — the Select mode row at ZERO and at a non-zero count, the four
/// selection-consuming controls refusing then live, and every control of the six-control bar
/// still reachable at the narrowest Compact width. One test class, both gate destinations, so
/// the `.compact` (iPhone) and `.regular3` (iPad) captures both come out of a normal gate run.
///
/// Select is entered through the DEBUG `-UITestEnterSelectMode` launch hook rather than a
/// gesture: on Regular-3 the tile long press never arrives (the grid's own pointer-drag
/// recognizer claims it) and the More menu's popover items are not addressable from XCUITest by
/// label or by identifier — three gate runs established both. The hook calls the very same
/// `GridStore.enterSelectExplicitly()` the More menu's command calls, so what is captured is the
/// shipped state reached through the shipped entry point, not a test-only mode.
final class SelectModeScreenshotUITests: XCTestCase {

  private func launchInSelectMode() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestEnterSelectMode"]
    app.launch()
    return app
  }

  private func tile(_ imageID: Int, in app: XCUIApplication) -> XCUIElement {
    // Addressed by the fixture's own ids (`DebugStubTransport` serves 1...12), never by bound
    // index: one tile surfaces as several accessibility elements, so an index-addressed pair can
    // be the same photograph twice — selecting it and then deselecting it.
    app.descendants(matching: .any).matching(identifier: "gridTile-\(imageID)").firstMatch
  }

  func testSelectModeRowCountsAndGatesTheMarkControls() throws {
    let app = launchInSelectMode()

    let caption = app.staticTexts["selectModeCaption"]
    XCTAssertTrue(
      caption.waitForExistence(timeout: 30),
      "Select mode is active but no mode row is on screen — the only way out would be the More "
        + "menu, which is the discoverability defect this phase closes.")

    let pick = app.buttons["gridPickButton"]
    let dislike = app.buttons["gridDislikeButton"]
    let clear = app.buttons["gridClearButton"]
    let undo = app.buttons["gridUndoButton"]
    let tag = app.buttons["gridTagButton"]
    let more = app.buttons["gridMoreMenu"]
    for control in [pick, dislike, clear, undo, tag, more] {
      XCTAssertTrue(
        control.waitForExistence(timeout: 10), "A control is missing from the six-control bar.")
    }

    // ZERO selected: the row states the count rather than hiding it behind an instruction, and
    // every selection-consuming control refuses. This is IMGMGR-223's UI half.
    XCTAssertEqual(caption.label, "0 selected", "An explicit Select entry starts empty.")
    XCTAssertFalse(pick.isEnabled, "Pick must refuse an empty selection.")
    XCTAssertFalse(dislike.isEnabled, "Dislike must refuse an empty selection.")
    XCTAssertFalse(clear.isEnabled, "Clear must refuse an empty selection.")
    XCTAssertFalse(tag.isEnabled, "Tag must refuse an empty selection.")

    let emptyCapture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    emptyCapture.name = "Select-mode-row-zero-selected"
    emptyCapture.lifetime = .keepAlways
    add(emptyCapture)

    let firstTile = tile(1, in: app)
    let secondTile = tile(2, in: app)
    XCTAssertTrue(firstTile.waitForExistence(timeout: 10), "No grid tiles to select.")
    firstTile.tap()
    XCTAssertEqual(caption.label, "1 selected", "Tapping a tile in Select mode must select it.")
    XCTAssertTrue(secondTile.waitForExistence(timeout: 5), "The second fixture tile is missing.")
    secondTile.tap()

    // Attached BEFORE the assertions below, so the run keeps its visual evidence whatever the
    // verdict is — a failing capture is the more interesting one.
    let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    capture.name = "Select-mode-row-two-selected"
    capture.lifetime = .keepAlways
    add(capture)

    XCTAssertEqual(
      caption.label, "2 selected",
      "The mode row must state the count of what the next mark would write to.")
    XCTAssertTrue(
      pick.isEnabled,
      "Pick must be live in Select mode — it is the whole point of the phase; only Pick LOCK "
        + "entry stays disabled there.")
    XCTAssertTrue(dislike.isEnabled, "Dislike must be live on a non-empty selection.")
    XCTAssertTrue(clear.isEnabled, "Clear must be live on a non-empty selection.")
    XCTAssertTrue(tag.isEnabled, "Tag must be live on a non-empty selection.")

    // Reachability, not just presence: the bar's own arithmetic (`ActionBarMetrics`) claims six
    // 44-pt controls fit the narrowest Compact width, and this is that claim at the rendered
    // level. Undo is excluded here only because it is legitimately disabled until a mark
    // commits — the Clear-wiring test below reaches it in its enabled state.
    for control in [pick, dislike, clear, tag, more] {
      XCTAssertTrue(control.isHittable, "A bar control has no reachable hit region at this width.")
    }
  }

  /// The Clear control's WIRING, through the production button rather than the store: pressing
  /// the bar's Clear must actually drive the shipped mutation lane. Undo is the observable — it
  /// is disabled until a mark commits, so a Clear button that is missing, inert, or wired to
  /// nothing leaves Undo disabled and turns this red. WHICH state Clear writes is pinned where
  /// it cannot drift instead: the button and `clearAppliesToTheSelectionFromTheGridBar` both
  /// read `ActionBarMarkControl.clear.state`, so there is no second declaration to disagree.
  func testClearControlInTheGridBarDrivesTheMarkLane() throws {
    let app = launchInSelectMode()

    let caption = app.staticTexts["selectModeCaption"]
    XCTAssertTrue(caption.waitForExistence(timeout: 30), "No Select mode row.")

    let clear = app.buttons["gridClearButton"]
    let undo = app.buttons["gridUndoButton"]
    XCTAssertTrue(clear.waitForExistence(timeout: 10), "The grid bar has no Clear control.")
    XCTAssertTrue(undo.waitForExistence(timeout: 10), "The grid bar has no Undo control.")
    XCTAssertFalse(undo.isEnabled, "Nothing has been written yet, so there is nothing to undo.")

    let firstTile = tile(1, in: app)
    XCTAssertTrue(firstTile.waitForExistence(timeout: 10), "No grid tiles to select.")
    firstTile.tap()
    XCTAssertEqual(caption.label, "1 selected", "Tapping a tile in Select mode must select it.")
    XCTAssertTrue(clear.isEnabled, "Clear must be live on a non-empty selection.")

    clear.tap()

    // `XCTWaiter` rather than `waitForExpectations(timeout:handler:)`: that handler closure
    // captures the test case itself, which Swift 6 refuses to send across the waiter's
    // isolation boundary (non-Sendable `XCTestCase`). Waiting for a result value instead needs
    // no closure at all, and the diagnostic message survives.
    let undoBecameAvailable = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: undo)
    let outcome = XCTWaiter().wait(for: [undoBecameAvailable], timeout: 15)
    XCTAssertEqual(
      outcome, .completed,
      "Tapping the bar's Clear committed nothing: Undo never became available, so that control "
        + "is not wired to the mark lane.")
    XCTAssertTrue(undo.isHittable, "Undo has no reachable hit region once it is enabled.")
  }
}
