import XCTest

/// Diff-gate round 2, item 9(a) follow-up (delta round): the one screenshot a unit test
/// cannot produce — a REAL device orientation change and a REAL screen capture — needs
/// XCUITest's own headless-capable runner. `xcodebuild test` drives UI tests without a live/
/// unlocked GUI session, unlike Simulator.app's own Hardware-menu rotation (blocked this
/// session by a locked merkur console — see `.phase-ledger.md`, item 9(a) section).
///
/// This is the ONE test in this target, scoped exactly to that gap — never a general UI-
/// automation surface. It launches the app in the DEBUG-only fixture composition
/// (`-UITestStubGrid`, `DebugStubTransport` — see that type's own doc comment: never compiled
/// into Release), rotates the simulator to landscape, and attaches a real screenshot
/// REGARDLESS of what is on screen — the point is retained visual evidence either way, so the
/// wait is logged, not fatal, and never blocks the capture itself.
final class RegularThreeScreenshotUITests: XCTestCase {
  func testRegularThreeLandscapeScreenshot() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    XCUIDevice.shared.orientation = .landscapeLeft

    let dislikeButton = app.buttons["Dislike"]
    let appeared = dislikeButton.waitForExistence(timeout: 20)
    XCTContext.runActivity(named: "Action bar appeared before timeout: \(appeared)") { _ in }

    // Give the rotation's own layout pass a moment to settle regardless of the wait outcome.
    Thread.sleep(forTimeInterval: 2.0)

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "Regular-3-landscape"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTContext.runActivity(named: "Captured size: \(screenshot.image.size)") { _ in }
  }
}
