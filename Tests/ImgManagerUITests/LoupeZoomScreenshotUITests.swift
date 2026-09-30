import XCTest

/// WP13 P3 (IMGMGR-213) retained visual evidence AND the causal coverage no unit test can give:
/// the unit suites drive the zoom handlers through a substituted spy, so they stay green even if
/// `LoupeZoomControls.live` attaches nothing at all (diff-gate round 1, blocker 1). These tests
/// drive the REAL gestures — a real double-tap, a real pinch, a real drag — against the running
/// app and read the state back from accessibility, so deleting the live `MagnifyGesture` or
/// `DragGesture` attachment turns this leg RED.
///
/// IMGMGR-348 (owner device pass 2026-09-02) removed the loupe's "100 %" chrome twin, so the
/// zoom state is read where it still lives: `loupeImage`'s own accessibility value, the surface
/// the photograph has always spoken it through. The chrome-twin test that led this file went
/// with the control; the gesture coverage below is now the ONLY coverage zoom has, which is
/// exactly why it stays.
///
/// The zoom assertions are geometry-derived, never idiom-derived: the DEBUG fixture serves a
/// 1600x1067 proxy (production `preview` geometry), which on both gate destinations fits well
/// below 1600 device pixels, so 1:1 sits above fit and the control must be enabled on both. If a
/// future destination fits the proxy at or above its own pixel count, this assertion is the thing
/// that tells us — which is the honest outcome, not a hidden branch.
final class LoupeZoomScreenshotUITests: OrientationPinnedUITestCase {

  // MARK: - The double-tap, and the retained screenshots

  func testDoubleTapZoomsAndReturnsToFit() throws {
    let app = launchAndOpenLoupe()
    let image = loupeImage(app)
    XCTAssertTrue(image.waitForExistence(timeout: 10))
    XCTAssertEqual(image.value as? String, "zoom fit, pan 0, 0", "the loupe must open at fit")
    attach(name: "loupe-fit")

    // Coordinate-based so the double-tap does not depend on the container element being
    // reported hittable by the accessibility tree.
    image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
    Thread.sleep(forTimeInterval: 1.0)
    let zoomed = image.value as? String ?? ""
    XCTAssertTrue(
      zoomed.hasPrefix("zoom 100 %"),
      "A double-tap did not put the photograph at 1:1 (\(zoomed)) — the live gesture is not "
        + "attached, and with the chrome twin gone there is no other way to zoom.")
    attach(name: "loupe-zoomed-via-double-tap")

    image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
    Thread.sleep(forTimeInterval: 1.0)
    XCTAssertEqual(
      image.value as? String, "zoom fit, pan 0, 0",
      "A second double-tap did not return the photograph to fit.")
  }

  // MARK: - The production MagnifyGesture

  func testPinchZoomsAndClampsBetweenFitAndOneToOne() throws {
    let app = launchAndOpenLoupe()
    let image = loupeImage(app)
    XCTAssertTrue(image.waitForExistence(timeout: 10))
    XCTAssertEqual(image.value as? String, "zoom fit, pan 0, 0", "the loupe must open at fit")

    image.pinch(withScale: 3, velocity: 3)
    Thread.sleep(forTimeInterval: 1.0)
    let zoomed = image.value as? String ?? ""
    XCTAssertFalse(
      zoomed.hasPrefix("zoom fit"),
      "A real pinch did not zoom the photograph — LoupeZoomControls.live is not attaching "
        + "MagnifyGesture.")
    XCTAssertFalse(
      zoomed.hasPrefix("zoom fit"),
      "The pinch left the magnification at fit (\(zoomed)).")
    // A 3x pinch far exceeds every ceiling this fixture can produce (1.14x-1.33x), so it must
    // land ON 1:1 against the proxy — the same "100 %" the chrome control names.
    XCTAssertTrue(
      zoomed.hasPrefix("zoom 100 %"),
      "The pinch did not reach 1:1 against the proxy (\(zoomed)).")
    XCTContext.runActivity(named: "after pinch out: \(zoomed)") { _ in }
    attach(name: "loupe-pinched-out")

    // Pinching back past fit must CLAMP at fit, never below it — the band is 1.0...oneToOne.
    image.pinch(withScale: 0.1, velocity: -3)
    Thread.sleep(forTimeInterval: 1.0)
    XCTAssertEqual(
      image.value as? String, "zoom fit, pan 0, 0",
      "Pinching below fit was not clamped to fit.")
  }

  // MARK: - The production DragGesture, while zoomed

  func testDragPansTheZoomedPhotograph() throws {
    let app = launchAndOpenLoupe()
    let image = loupeImage(app)
    XCTAssertTrue(image.waitForExistence(timeout: 10))

    image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
    Thread.sleep(forTimeInterval: 1.0)
    let centred = image.value as? String ?? ""
    XCTAssertEqual(
      centred, "zoom 100 %, pan 0, 0",
      "the double-tap should put the photograph at 1:1, centred (\(centred))")

    let start = image.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.5))
    let end = image.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.5))
    start.press(forDuration: 0.15, thenDragTo: end)
    Thread.sleep(forTimeInterval: 1.0)

    let panned = image.value as? String ?? ""
    XCTContext.runActivity(named: "after drag: \(panned)") { _ in }
    XCTAssertNotEqual(
      panned, centred,
      "A real drag did not pan the zoomed photograph — LoupeZoomControls.live is not attaching "
        + "DragGesture, or the drag was arbitrated as a frame advance while zoomed.")
    XCTAssertFalse(panned.hasSuffix("pan 0, 0"), "the pan did not move off centre (\(panned))")
    XCTAssertTrue(
      panned.hasPrefix("zoom 100 %"),
      "The drag must PAN while zoomed, never drop the magnification (\(panned)).")
    attach(name: "loupe-panned")
  }

  // MARK: - Shared

  private func loupeImage(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "loupeImage").firstMatch
  }

  /// Launches the DEBUG fixture composition and opens the loupe on the fixture's FIRST tile,
  /// addressed by that tile's own identifier (`DebugStubTransport` serves ids 1...12).
  ///
  /// BY IDENTIFIER, never by normalized screen coordinates (IMGMGR-336): a coordinate probe is a
  /// statement about pane geometry, and the geometry is decided by the device orientation — the
  /// simulator-global state no class owns. The probe grid this replaces (dx 0.25...0.85) missed
  /// the grid entirely on a landscape iPad, where the content column is the ~209 pt middle pane
  /// of three, and the whole class failed on "the loupe never opened from a tile tap". An
  /// identifier encodes no pane width, so there is nothing left here to rot.
  private func launchAndOpenLoupe() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    let dislike = app.buttons["Dislike"]
    XCTAssertTrue(
      dislike.waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared — expected the DEBUG fixture composition's "
        + "populated grid, got something else (sign-in screen, blank screen, failed stub).")

    let close = app.buttons["loupeBack"]
    let tile = app.descendants(matching: .any).matching(identifier: "gridTile-1").firstMatch
    XCTAssertTrue(
      tile.waitForExistence(timeout: 15),
      "The fixture's first tile (`gridTile-1`) never appeared — the grid this test opens the "
        + "loupe from is not on screen.")
    // TWO taps, because that is the shipped way in: `GridStore.tapTile` moves focus on a tap on
    // an unfocused tile and opens the loupe on a tap on the focused one (spec 3220 §2.2), and
    // which of the two the first tap is depends on where focus already sits.
    tile.tap()
    if !close.waitForExistence(timeout: 2) {
      tile.tap()
      _ = close.waitForExistence(timeout: 5)
    }
    if !close.exists {
      // Retained so a failure here is diagnosable from the log alone instead of costing another
      // gate cycle to find out what was actually on screen.
      XCTContext.runActivity(named: "element tree when no tile was hit") { activity in
        activity.add(XCTAttachment(string: app.debugDescription))
      }
      attach(name: "loupe-never-opened")
    }
    XCTAssertTrue(
      close.exists,
      "The loupe never opened from a tile tap — no cell was hit by any probe point.")
    return app
  }

  private func attach(name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTContext.runActivity(named: "\(name) size \(screenshot.image.size)") { _ in }
  }
}
