import XCTest

/// WP13 P9 (IMGMGR-218): the retained visual evidence the phase's Verification names — the
/// Compact loupe WITH the thumb bar, at fit and zoomed — and the causal coverage no unit suite
/// can give.
///
/// The unit suite drives `LoupeView.body` through a substituted filmstrip surface, so it stays
/// green even if the live `FilmstripView` renders nothing at all. This test reads the SHIPPED
/// strip out of the running app's accessibility tree, so removing it turns the `test-iphone` leg
/// RED. It runs on both gate destinations deliberately: on the iPhone it is the phase's claim
/// (Compact now has a strip), on the iPad it is the regression pin (the phase ADDED a layout
/// mode, it did not move the strip out of the ones that had it).
///
/// It is also the phase's PIVOT PROBE. The known-unknown was whether header + strip + mark bar
/// leave a usable image area at 402 pt portrait — the gate's iPhone destination IS an
/// iPhone 17 Pro, so the numbers this test measures and attaches are the answer, and the floor
/// assertion below is what would trip the pre-decided collapsible-strip pivot.
final class CompactFilmstripScreenshotUITests: XCTestCase {

  func testLoupeShowsTheThumbBarAndKeepsAUsableImageArea() throws {
    let app = launchAndOpenLoupe()

    let strip = element(app, "loupeFilmstrip")
    XCTAssertTrue(
      strip.waitForExistence(timeout: 10),
      "The loupe thumb bar is missing — WP13 P9 renders the SAME filmstrip in every layout "
        + "mode, the phone included.")

    let image = element(app, "loupeImage")
    XCTAssertTrue(image.waitForExistence(timeout: 10))
    let markBar = element(app, "loupeMarkBar")
    XCTAssertTrue(markBar.waitForExistence(timeout: 10))

    // The measurement, retained whether the assertions pass or fail — this is the evidence the
    // phase's known-unknown is answered from, not an opinion about whether it "looks tight".
    let window = app.windows.firstMatch
    XCTContext.runActivity(
      named: "measured — window \(window.frame) | image \(image.frame) | strip \(strip.frame) "
        + "| markBar \(markBar.frame)"
    ) { _ in }
    attach(name: "compact-loupe-thumb-bar-fit")

    XCTAssertLessThanOrEqual(
      strip.frame.height, 88,
      "The thumb bar grew past a strip — it is a 72 pt band of 64 pt thumbnails.")
    XCTAssertGreaterThanOrEqual(
      image.frame.height, 320,
      "The image area is no longer usable with the strip in place. This is the phase's "
        + "pre-decided pivot trigger: make the strip collapsible from persistent chrome "
        + "(defaulting visible, never a hidden gesture) rather than dropping it.")
    XCTAssertGreaterThan(
      image.frame.height, strip.frame.height * 2,
      "The strip is eating the image area rather than accompanying it.")

    // Zoomed (P3's interaction): the strip stays put — zoom magnifies the frame, it does not
    // take the context away.
    let zoomToggle = app.buttons["loupeZoomToggle"]
    XCTAssertTrue(zoomToggle.waitForExistence(timeout: 10))
    XCTAssertEqual(zoomToggle.value as? String, "100 %")
    zoomToggle.tap()
    Thread.sleep(forTimeInterval: 1.0)
    XCTAssertEqual(
      zoomToggle.value as? String, "Fit",
      "Tapping the zoom chrome twin did not change the zoom state.")
    XCTAssertTrue(strip.exists, "The thumb bar disappeared when the frame was zoomed.")
    attach(name: "compact-loupe-thumb-bar-zoomed")

    // Leave the loupe at fit for whatever runs next in this simulator.
    zoomToggle.tap()
    Thread.sleep(forTimeInterval: 0.6)
    XCTAssertEqual(zoomToggle.value as? String, "100 %")
  }

  // MARK: - Shared

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// Launches the DEBUG fixture composition and opens the loupe on a tile — the same probe
  /// `LoupeZoomScreenshotUITests` and `LoupeAutoAdvanceScreenshotUITests` use, and for the same
  /// reason: a tile carries no accessibility identifier, and the pane the tiles occupy differs
  /// by layout mode, which this test must not encode (no idiom branching).
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
