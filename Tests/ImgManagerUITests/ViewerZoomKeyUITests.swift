import XCTest

/// IMGMGR-495 (owner ruling, comment 10230): "⌘0 alone toggles Fit/100% in the loupe and in
/// Compare; ⌘1 stays the grid's first zoom step; no second key." Each leg presses the real key
/// and reads the state back through accessibility the app already publishes:
/// - grid: ⌘1 → the Arrange popover's `arrange.size.120` row reads "Checked";
/// - loupe: ⌘0 → `loupeImage`'s value goes "zoom fit" → "zoom 100 %" → "zoom fit";
/// - Compare (iPad only): ⌘0 → both panes' labels go "zoom fit" → "zoom 100 %" → "zoom fit".
///
/// KEY REACHABILITY. `ViewOptionsScreenshotUITests` records a gate run where a ⌘ key equivalent
/// never reached the app on the iPad simulator. So the loupe and Compare legs open with a
/// POSITIVE CONTROL on the same mechanism: ⌘1 on the grid, a binding this phase does not touch,
/// must visibly shrink a tile. If it does not, ⌘ keys do not reach the app on this destination
/// and the leg is SKIPPED with that reason (the dispatch itself is unit-proven in
/// `ViewerZoomCommandTests`); if it does, ⌘0 MUST work and a miss is a failure.
final class ViewerZoomKeyUITests: OrientationPinnedUITestCase {
  private let firstStepRow = "arrange.size.120"
  private let leftID = 3

  // MARK: - Grid: ⌘1 is still the first zoom step

  func testCommandOneStillSelectsTheGridsFirstZoomStep() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "The DEBUG fixture grid never rendered its action bar.")
    let tile = element(app, "gridTile-1")
    XCTAssertTrue(tile.waitForExistence(timeout: 15), "The fixture's first tile is missing.")
    try requireCommandKeys(app, shrinking: tile)

    let control = element(app, "gridArrangeControl")
    XCTAssertTrue(control.waitForExistence(timeout: 10), "No 'gridArrangeControl' in the chrome.")
    let row = element(app, firstStepRow)
    XCTAssertTrue(
      openPresentation(control, revealing: row, timeout: 10), "The Arrange popover did not open.")
    let checked = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Checked"), object: row)
    XCTAssertEqual(
      XCTWaiter.wait(for: [checked], timeout: 10), .completed,
      "⌘1 did not select the grid's first zoom step (\(firstStepRow) is not Checked).")
  }

  // MARK: - Loupe: ⌘0 toggles Fit ⟷ 100 %

  func testCommandZeroTogglesTheLoupeBetweenFitAndOneToOne() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "The DEBUG fixture grid never rendered its action bar.")
    let tile = element(app, "gridTile-1")
    XCTAssertTrue(tile.waitForExistence(timeout: 15), "The fixture's first tile is missing.")
    try requireCommandKeys(app, shrinking: tile)
    openLoupe(app, on: "gridTile-1")

    let image = element(app, "loupeImage")
    XCTAssertTrue(image.waitForExistence(timeout: 10), "The loupe has no 'loupeImage'.")
    XCTAssertTrue(
      waitFor(image, "value BEGINSWITH %@", "zoom fit"), "The loupe did not open at fit.")

    app.typeKey("0", modifierFlags: .command)
    XCTAssertTrue(
      waitFor(image, "value BEGINSWITH %@", "zoom 100 %"),
      "⌘0 did not put the loupe at 100 % (\(image.value as? String ?? "nil")).")
    app.typeKey("0", modifierFlags: .command)
    XCTAssertTrue(
      waitFor(image, "value BEGINSWITH %@", "zoom fit"),
      "A second ⌘0 did not return the loupe to fit (\(image.value as? String ?? "nil")).")
  }

  // MARK: - Compare (iPad): ⌘0 toggles both panes

  func testCommandZeroTogglesBothComparePanes() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestEnterSceneMode", "-UITestStubNoAutoAdvance"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "The Scene-mode stub grid never rendered its action bar.")
    let handle = element(app, "sceneHandle-5000")
    XCTAssertTrue(handle.waitForExistence(timeout: 15), "The fixture scene's handle is missing.")
    handle.tap()
    let member = element(app, "gridTile-\(leftID)")
    XCTAssertTrue(member.waitForExistence(timeout: 20), "Opening the scene showed no members.")
    try requireCommandKeys(app, shrinking: member)

    // CompareUITests' path into the scene (WP442 P12): the loupe on the pushed scene's first
    // member (3), where Compare opens on 3 | 4.
    openLoupe(app, on: "gridTile-\(leftID)")
    let strip = element(app, "loupeFilmstrip")
    _ = strip.waitForExistence(timeout: 10)
    // Compare is an iPad verb: at Compact the proof is the control's absence (CompareUITests).
    if rendersCompactShell(app) {
      XCTAssertFalse(
        element(app, "loupeCompareButton").exists, "The phone's loupe carries a Compare control.")
      return
    }
    let compare = element(app, "loupeCompareButton")
    XCTAssertTrue(strip.exists, "The member's loupe drew no strip.")
    XCTAssertTrue(compare.waitForExistence(timeout: 10), "The Regular loupe has no Compare.")
    compare.tap()
    XCTAssertTrue(app.buttons["compareBack"].waitForExistence(timeout: 10), "Compare did not open.")

    let panes = [element(app, "compareLeftPane"), element(app, "compareRightPane")]
    for pane in panes {
      XCTAssertTrue(waitFor(pane, "label ENDSWITH %@", "zoom fit"), "A pane did not open at fit.")
    }
    app.typeKey("0", modifierFlags: .command)
    for pane in panes {
      XCTAssertTrue(
        waitFor(pane, "label ENDSWITH %@", "zoom 100 %"),
        "⌘0 did not put \(pane.identifier) at 100 % (\(pane.label)).")
    }
    app.typeKey("0", modifierFlags: .command)
    for pane in panes {
      XCTAssertTrue(
        waitFor(pane, "label ENDSWITH %@", "zoom fit"),
        "A second ⌘0 did not return \(pane.identifier) to fit (\(pane.label)).")
    }
  }

  // MARK: - Shared

  /// The positive control: ⌘1 (the grid's first, smallest zoom step; the fixture launches on a
  /// larger one) must shrink `tile`. A miss means ⌘ keys do not reach the app here — a SKIP with
  /// that reason, never a pass.
  private func requireCommandKeys(_ app: XCUIApplication, shrinking tile: XCUIElement) throws {
    let before = tile.frame.height
    app.typeKey("1", modifierFlags: .command)
    // Polled on the condition itself rather than one blind sleep: frames are re-read per access.
    let deadline = Date(timeIntervalSinceNow: 5)
    while Date() < deadline {
      if tile.exists && tile.frame.height < before - 1 { return }
      Thread.sleep(forTimeInterval: 0.25)
    }
    throw XCTSkip(
      "⌘1 did not shrink the grid's tiles, so ⌘ key equivalents do not reach the app on this "
        + "destination; ⌘0's dispatch is ViewerZoomCommandTests.")
  }

  /// Two taps, as `LoupeZoomScreenshotUITests` does: the first may only move focus.
  private func openLoupe(_ app: XCUIApplication, on tileID: String) {
    let back = app.buttons["loupeBack"]
    for _ in 0..<3 where !back.exists {
      let tile = element(app, tileID)
      guard tile.exists else { break }
      tile.tap()
      _ = back.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(back.exists, "Tapping \(tileID) never opened the loupe.")
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func waitFor(_ element: XCUIElement, _ format: String, _ value: String) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: format, value), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }
}
