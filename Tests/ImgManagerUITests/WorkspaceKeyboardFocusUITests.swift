import XCTest

/// IMGMGR-549 (P10 fix round 2): at Regular width the workspace claims the keyboard focus once,
/// at launch (`RootView.regularShell`). The claim must never take focus back from a text field.
/// The grid's tag sheet must keep every typed character, including ones typed after a pause.
/// After the sheet closes, a bare arrow must not move the sidebar's selection (Regular only).
final class WorkspaceKeyboardFocusUITests: OrientationPinnedUITestCase {

  func testTagFieldKeepsTypedTextAndTheSidebarSelectionSurvivesTheSheet() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared — expected the DEBUG fixture grid.")

    // One tap focuses a photograph, which is what enables the grid's Tag.
    let tile = element(app, "gridTile-2")
    XCTAssertTrue(tile.waitForExistence(timeout: 15), "The fixture's second tile is missing.")
    tile.tap()
    let gridTag = app.buttons["gridTagButton"]
    XCTAssertTrue(gridTag.waitForExistence(timeout: 10), "The grid's bar has no Tag.")
    waitFor("isEnabled == true", gridTag)
    gridTag.tap()
    let sheet = app.navigationBars["Add tag"]
    XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Tag did not present the tag entry sheet.")

    let field = app.textFields["Tag"]
    XCTAssertTrue(field.waitForExistence(timeout: 10), "The tag entry sheet has no Tag field.")
    field.tap()
    field.typeText("keep")
    // A pause, so that a focus claim arriving after the sheet opened would land between the
    // two halves.
    let settled = XCTestExpectation(description: "pause")
    _ = XCTWaiter.wait(for: [settled], timeout: 2)
    field.typeText("me")
    XCTAssertEqual(
      field.value as? String, "keepme",
      "The Tag field lost typed characters — something took the keyboard focus from it.")

    app.buttons["Cancel"].firstMatch.tap()
    waitFor("exists == false", sheet)

    // The sidebar half is the Regular split's. A Compact launch opens on the grid with no
    // sidebar beside it, so folder 1's Library row is absent there. As in
    // `InspectorSlideOverUITests`, the queue beside the grid is what tells the two apart, never
    // a device idiom (the gate's idiom-grep).
    // Folder 1 is the fixture's auto-selection, so its Library row is the sidebar's selection.
    let selectedRow = element(app, "folderRow-1")
    guard selectedRow.waitForExistence(timeout: 10) else { return }
    waitFor("isSelected == true", selectedRow)
    app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
    let jumped = app.descendants(matching: .any).matching(
      NSPredicate(format: "isSelected == true AND identifier BEGINSWITH 'untouchedRow-'"))
    XCTAssertEqual(
      jumped.count, 0,
      "→ after the sheet moved the sidebar's selection onto an Untouched row.")
    XCTAssertTrue(selectedRow.isSelected, "→ after the sheet moved the sidebar's selection.")
  }

  // MARK: - Helpers

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func waitFor(_ format: String, _ element: XCUIElement) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: format), object: element)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: 10), .completed,
      "\(element) never satisfied \(format).")
  }
}
