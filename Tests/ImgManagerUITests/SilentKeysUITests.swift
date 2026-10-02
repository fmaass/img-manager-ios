import XCTest

/// IMGMGR-463 (p4128 D10): the secondary keys no longer draw menu rows — `?` and Space are bound
/// by `SilentKeyCommandHost`, mounted in the scene, rather than by `AppCommands`. The unit tests
/// prove the declarations; THIS proves the host is mounted and its bindings register, by pressing
/// the real key and reading the effect back. Remove the host's mounts and both tests go red.
///
/// KEY REACHABILITY. Unlike ⌘ key equivalents (`CompactSelectUITests`' own note), bare keys DO
/// reach the gate's simulators — `CompareUITests` drives `typeKey("p")` and asserts on it — so
/// there is no skip path here: a key that does not arrive is a FAILURE.
final class SilentKeysUITests: OrientationPinnedUITestCase {

  /// (a) Bare `?` — the silent twin of the View menu's "Keyboard Shortcuts" (⌘/) — raises the
  /// shortcut help sheet on the grid.
  func testBareQuestionMarkOpensTheKeyboardShortcutsSheet() throws {
    let app = launchTheStubGrid()
    let helpBar = app.navigationBars["Keyboard shortcuts"]
    XCTAssertFalse(helpBar.exists, "The help sheet was already up before any key was pressed.")

    app.typeKey("?", modifierFlags: [])
    XCTAssertTrue(
      helpBar.waitForExistence(timeout: 10),
      "Bare ? did not open the Keyboard Shortcuts sheet — the silent binding is not registered.")
  }

  /// (b) Space — the silent twin of the Grid menu's "Open" (Return) — opens the loupe on the
  /// focused photograph.
  ///
  /// Focus is set with a bare arrow key, NOT a tile tap: the store launches with no focused image,
  /// `moveFocus` focuses the first actionable one, and the arrow is a menu row this phase leaves
  /// alone. A tap would also work as a focus step, but it could leave the tile as a focused
  /// control that Space merely presses, which would open the loupe without the silent binding.
  func testSpaceOpensTheLoupeOnTheFocusedPhotograph() throws {
    let app = launchTheStubGrid()
    let back = app.buttons["loupeBack"]
    XCTAssertFalse(back.exists, "The loupe was already open before any key was pressed.")

    app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [])
    XCTAssertTrue(
      back.waitForExistence(timeout: 10),
      "→ then Space did not open the loupe — the silent Space binding is not registered (or the "
        + "arrow did not focus a photograph).")
  }

  // MARK: - Shared

  /// The launch every keyboard UI test here uses (`CompactSelectUITests`,
  /// `ViewerZoomKeyUITests`): the DEBUG fixture grid, waited for through its action bar.
  private func launchTheStubGrid() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid.")
    let tile = app.descendants(matching: .any).matching(identifier: "gridTile-1").firstMatch
    XCTAssertTrue(tile.waitForExistence(timeout: 15), "The fixture's first tile is missing.")
    return app
  }
}
