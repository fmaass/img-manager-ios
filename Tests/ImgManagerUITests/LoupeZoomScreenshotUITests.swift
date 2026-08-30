import XCTest

/// WP13 P3 (IMGMGR-213) retained visual evidence: the loupe at FIT and at 100 %, captured on both
/// gate destinations (the iPhone leg renders `.compact`, the iPad leg `.regular3`), plus the one
/// thing no unit test can prove — that the REAL gesture attachment and the REAL chrome button in
/// `LoupeZoomControls.live` are wired to the running app rather than merely compiled.
///
/// The zoom assertions are geometry-derived, never idiom-derived: the DEBUG fixture serves a
/// 1600x1067 proxy (production `preview` geometry), which on both destinations fits well below
/// 1600 device pixels, so 1:1 sits above fit and the control must be enabled on both. If a future
/// destination fits the proxy at or above its own pixel count, this assertion is the thing that
/// tells us — which is the honest outcome, not a hidden branch.
final class LoupeZoomScreenshotUITests: XCTestCase {
  func testLoupeZoomFitAndOneToOne() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    let dislike = app.buttons["Dislike"]
    XCTAssertTrue(
      dislike.waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared — expected the DEBUG fixture composition's "
        + "populated grid, got something else (sign-in screen, blank screen, failed stub).")

    let close = app.buttons["loupeClose"]
    let candidates: [(CGFloat, CGFloat)] = [
      (0.25, 0.35), (0.5, 0.35), (0.45, 0.45), (0.25, 0.55), (0.6, 0.5), (0.35, 0.62),
    ]
    for (dx, dy) in candidates where !close.exists {
      app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
      _ = close.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(
      close.exists,
      "The loupe never opened from a tile tap — no cell was hit by any probe point.")

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

    let image = app.descendants(matching: .any).matching(identifier: "loupeImage").firstMatch
    XCTAssertTrue(image.waitForExistence(timeout: 10))
    XCTContext.runActivity(named: "loupeImage frame: \(image.frame)") { _ in }
    image.doubleTap()
    Thread.sleep(forTimeInterval: 1.0)
    XCTAssertEqual(
      zoomToggle.value as? String, "Fit",
      "A double-tap did not produce the SAME state the chrome control does — the two surfaces "
        + "have drifted apart, or the live gesture is not attached.")
    attach(name: "loupe-zoomed-via-double-tap")
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
