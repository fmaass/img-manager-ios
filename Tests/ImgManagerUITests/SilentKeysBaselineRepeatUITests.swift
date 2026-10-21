import XCTest

/// DIAG (P10 fix round 2, baseline on main c78ba98) — never merged. The exact steps of
/// `SilentKeysUITests.testSpaceOpensTheLoupeOnTheFocusedPhotograph`, repeated, with the fixture's
/// auto-selected folder changed to 11 (DebugStubTransport) so the sidebar selection is a
/// Library-only row. Prints the selected elements so membership is self-evident.
final class SilentKeysBaselineRepeatUITests: OrientationPinnedUITestCase {
  func testRepeat01() throws { try run("r01") }
  func testRepeat02() throws { try run("r02") }
  func testRepeat03() throws { try run("r03") }
  func testRepeat04() throws { try run("r04") }
  func testRepeat05() throws { try run("r05") }
  func testRepeat06() throws { try run("r06") }
  func testRepeat07() throws { try run("r07") }
  func testRepeat08() throws { try run("r08") }

  private func run(_ name: String) throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    XCTAssertTrue(app.buttons["Dislike"].waitForExistence(timeout: 30))
    let tile = app.descendants(matching: .any).matching(identifier: "gridTile-1").firstMatch
    XCTAssertTrue(tile.waitForExistence(timeout: 15))
    let before = app.descendants(matching: .any).matching(NSPredicate(format: "selected == true"))
      .allElementsBoundByIndex.map { $0.identifier }
    let back = app.buttons["loupeBack"]
    XCTAssertFalse(back.exists)
    app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [])
    let opened = back.waitForExistence(timeout: 10)
    let after = app.descendants(matching: .any).matching(NSPredicate(format: "selected == true"))
      .allElementsBoundByIndex.map { $0.identifier }
    print("BASELINE \(name) opened=\(opened) before=\(before) after=\(after)")
    XCTAssertTrue(opened, "→ then Space did not open the loupe")
  }
}
