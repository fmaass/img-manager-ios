import XCTest

/// WP13 P3 (IMGMGR-213) retained visual evidence AND the causal coverage no unit test can give:
/// the unit suites drive the zoom handlers through a substituted spy, so they stay green even if
/// `LoupeZoomControls.live` attaches nothing at all (diff-gate round 1, blocker 1). These tests
/// drive the REAL gestures — a real double-tap, a real pinch, a real drag — against the running
/// app and read the state back from accessibility, so deleting the live `MagnifyGesture` or
/// `DragGesture` attachment turns this leg RED.
///
/// The zoom assertions are geometry-derived, never idiom-derived: the DEBUG fixture serves a
/// 1600x1067 proxy (production `preview` geometry), which on both gate destinations fits well
/// below 1600 device pixels, so 1:1 sits above fit and the control must be enabled on both. If a
/// future destination fits the proxy at or above its own pixel count, this assertion is the thing
/// that tells us — which is the honest outcome, not a hidden branch.
final class LoupeZoomScreenshotUITests: XCTestCase {

  // MARK: - The chrome twin, the double-tap, and the retained screenshots

  func testLoupeZoomFitAndOneToOne() throws {
    let app = launchAndOpenLoupe()
    let zoomToggle = app.buttons["loupeZoomToggle"]
    XCTAssertTrue(
      zoomToggle.waitForExistence(timeout: 10),
      "The zoom chrome twin is missing — zoom must never be gesture-only.")

    attach(name: "loupe-fit")

    XCTAssertTrue(
      zoomToggle.isEnabled,
      "Zoom reported unavailable against a 1600x1067 fixture proxy: the fitted extent must be "
        + "wider than 1600 device pixels on this destination for that to be correct.")
    XCTAssertEqual(zoomToggle.value as? String, "100 %")

    zoomToggle.tap()
    Thread.sleep(forTimeInterval: 1.0)
    XCTAssertEqual(
      zoomToggle.value as? String, "Fit",
      "Tapping the chrome twin did not change the zoom state — the live control is not wired.")
    attach(name: "loupe-zoomed-via-chrome")

    zoomToggle.tap()
    Thread.sleep(forTimeInterval: 0.6)
    XCTAssertEqual(zoomToggle.value as? String, "100 %")

    let image = loupeImage(app)
    XCTAssertTrue(image.waitForExistence(timeout: 10))
    XCTContext.runActivity(named: "loupeImage frame: \(image.frame)") { _ in }
    // Coordinate-based so the double-tap does not depend on the container element being
    // reported hittable by the accessibility tree.
    image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
    Thread.sleep(forTimeInterval: 1.0)
    XCTAssertEqual(
      zoomToggle.value as? String, "Fit",
      "A double-tap did not produce the SAME state the chrome control does — the two surfaces "
        + "have drifted apart, or the live gesture is not attached.")
    attach(name: "loupe-zoomed-via-double-tap")
  }

  // MARK: - The production MagnifyGesture

  func testPinchZoomsAndClampsBetweenFitAndOneToOne() throws {
    let app = launchAndOpenLoupe()
    let zoomToggle = app.buttons["loupeZoomToggle"]
    XCTAssertTrue(zoomToggle.waitForExistence(timeout: 10))
    XCTAssertEqual(zoomToggle.value as? String, "100 %", "the loupe must open at fit")

    let image = loupeImage(app)
    XCTAssertTrue(image.waitForExistence(timeout: 10))
    XCTAssertEqual(image.value as? String, "zoom fit, pan 0, 0")

    image.pinch(withScale: 3, velocity: 3)
    Thread.sleep(forTimeInterval: 1.0)
    XCTAssertEqual(
      zoomToggle.value as? String, "Fit",
      "A real pinch did not zoom the photograph — LoupeZoomControls.live is not attaching "
        + "MagnifyGesture.")
    let zoomed = image.value as? String ?? ""
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
      zoomToggle.value as? String, "100 %",
      "Pinching back in did not return the photograph to fit.")
    XCTAssertEqual(
      image.value as? String, "zoom fit, pan 0, 0",
      "Pinching below fit was not clamped to fit.")
  }

  // MARK: - The production DragGesture, while zoomed

  func testDragPansTheZoomedPhotograph() throws {
    let app = launchAndOpenLoupe()
    let zoomToggle = app.buttons["loupeZoomToggle"]
    XCTAssertTrue(zoomToggle.waitForExistence(timeout: 10))
    let image = loupeImage(app)
    XCTAssertTrue(image.waitForExistence(timeout: 10))

    zoomToggle.tap()
    Thread.sleep(forTimeInterval: 1.0)
    let centred = image.value as? String ?? ""
    XCTAssertEqual(
      centred, "zoom 100 %, pan 0, 0",
      "the chrome twin should put the photograph at 1:1, centred (\(centred))")

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
    XCTAssertEqual(
      zoomToggle.value as? String, "Fit",
      "The drag must PAN while zoomed, never drop the magnification.")
    attach(name: "loupe-panned")
  }

  // MARK: - Shared

  private func loupeImage(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "loupeImage").firstMatch
  }

  /// Launches the DEBUG fixture composition and opens the loupe on a tile.
  ///
  /// A tile carries no accessibility identifier, so the loupe is opened by probing the content
  /// area with taps. The probe is a GRID of points rather than a handful, because the pane the
  /// tiles occupy differs by layout mode (full width on Compact, the middle pane of three on a
  /// large iPad) and this test must not encode which — no idiom branching, and no guess about
  /// pane widths that would silently rot.
  private func launchAndOpenLoupe() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    let dislike = app.buttons["Dislike"]
    XCTAssertTrue(
      dislike.waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared — expected the DEBUG fixture composition's "
        + "populated grid, got something else (sign-in screen, blank screen, failed stub).")

    let close = app.buttons["loupeClose"]
    let columns: [CGFloat] = [0.5, 0.4, 0.6, 0.7, 0.3, 0.8, 0.25, 0.85]
    let rows: [CGFloat] = [0.35, 0.45, 0.55, 0.28]
    for dy in rows {
      for dx in columns where !close.exists {
        app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
        _ = close.waitForExistence(timeout: 1)
      }
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
