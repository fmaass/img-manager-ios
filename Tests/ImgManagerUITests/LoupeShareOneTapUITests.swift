import XCTest

/// IMGMGR-348: ONE TAP on the loupe's share control opens the system share sheet for the
/// photograph on screen. Owner device pass on 0.11.0 (14), verbatim: "the sharing button should
/// immediatly open the native share functionality and share that picture, right ?"
///
/// This is the leg no unit test can give: the menu, the "Preparing the export…" row and the
/// second tap were all real SwiftUI, and a suite that only asserted store state would stay green
/// with every one of them still on screen. Here the tap is a real tap, and the sheet is the real
/// `UIActivityViewController` — waited for by the identifier `ShareSheet` puts on its own
/// container view, because the sheet DRAWS out of process and its rows are not this app's to
/// assert on.
///
/// It also carries the phase's own measurement: the interval from the tap to the sheet existing,
/// recorded per destination as a test activity, which is the "prepare-then-present" bound the AC
/// asks the phase to state (simulator, DEBUG fixture — client-side cost only, no network).
final class LoupeShareOneTapUITests: OrientationPinnedUITestCase {

  /// The fixture marks every third image `hasEdit` (`DebugStubTransport.fixtureImages`), so
  /// `gridTile-1` takes the MASTER path — `ShareExportPlan.variant` asking the download endpoint
  /// for `content=master` — and `gridTile-2` takes the preview one.
  func testOneTapSharesTheEditedMaster() throws {
    let app = launchAndOpenLoupe(tile: 1)

    let elapsed = tapShareAndWaitForSheet(app, name: "one-tap-share-master")

    XCTAssertNotNil(
      elapsed,
      "One tap on the share control did not present the system share sheet. Element tree: "
        + app.debugDescription)
    XCTAssertFalse(
      app.buttons["Share preview"].exists,
      "A menu appeared instead of the sheet — the one-tap rule is not in force.")
    XCTAssertFalse(
      app.buttons["shareReadyLink"].exists,
      "The inline ready row is back: that is the second tap the owner asked us to remove.")
    XCTAssertFalse(
      app.otherElements["shareRefusal"].exists,
      "The master share refused against the DEBUG fixture, which serves a master export.")

    // IMGMGR-348, the owner's other sentence: "there is also a 'play button' … and a 100 % zoom
    // function and an 'expand function' - i think we can get rid of those altogether". They were
    // ours, and they are gone; this is what keeps them from coming back unnoticed.
    for identifier in ["loupeZoomToggle", "loupeAutoAdvanceToggle", "loupeFullScreenToggle"] {
      XCTAssertFalse(
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists,
        "The loupe header still carries `\(identifier)` — the owner asked for it to be gone.")
    }
  }

  func testOneTapSharesThePreviewWhenThereIsNoEditedMaster() throws {
    let app = launchAndOpenLoupe(tile: 2)

    let elapsed = tapShareAndWaitForSheet(app, name: "one-tap-share-preview")

    XCTAssertNotNil(
      elapsed,
      "One tap on the share control did not present the system share sheet. Element tree: "
        + app.debugDescription)
    XCTAssertFalse(
      app.otherElements["shareRefusal"].exists,
      "The preview share refused against the DEBUG fixture, which serves a preview proxy.")
  }

  // MARK: - Shared

  /// Taps `loupeShare` once and waits for the presented sheet. Returns the interval in
  /// milliseconds, or nil if no sheet ever appeared — measured from immediately before the tap,
  /// so it includes the whole prepare-then-present path the phase had to bound.
  @discardableResult
  private func tapShareAndWaitForSheet(_ app: XCUIApplication, name: String) -> Double? {
    // WP30 P1 (IMGMGR-456): Share is the More menu's row — the header became a system toolbar
    // and Share moved into More (p4128 D4). One tap on the ROW still prepares and presents.
    let more = app.descendants(matching: .any).matching(identifier: "loupeMoreMenu").firstMatch
    XCTAssertTrue(
      more.waitForExistence(timeout: 10),
      "The loupe's More menu is missing — Share's home in persistent chrome.")
    more.tap()
    let share = app.buttons["loupeShare"]
    XCTAssertTrue(
      share.waitForExistence(timeout: 10),
      "More carries no Share row — sharing must be reachable from persistent chrome.")

    let started = Date()
    share.tap()

    // Both handles on a sheet whose contents are out of process: the container view this app
    // names itself, and the activity controller's own long-standing identifier.
    let ours = app.otherElements["loupeShareSheet"]
    let system = app.otherElements["ActivityListView"]
    var elapsed: Double?
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      if ours.exists || system.exists {
        elapsed = Date().timeIntervalSince(started) * 1000
        break
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    XCTContext.runActivity(
      named: "\(name): tap → sheet = \(elapsed.map { String(format: "%.0f ms", $0) } ?? "never")"
    ) { _ in }
    attach(name: name)
    return elapsed
  }

  /// Launches the DEBUG fixture composition and opens the loupe on one fixture tile, addressed
  /// by that tile's own identifier — never by normalized screen coordinates (IMGMGR-336, see
  /// `LoupeZoomScreenshotUITests` for what that cost).
  private func launchAndOpenLoupe(tile: Int) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    let dislike = app.buttons["Dislike"]
    XCTAssertTrue(
      dislike.waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared — expected the DEBUG fixture composition's "
        + "populated grid, got something else (sign-in screen, blank screen, failed stub).")

    let close = app.buttons["loupeBack"]
    let target = app.descendants(matching: .any).matching(identifier: "gridTile-\(tile)").firstMatch
    XCTAssertTrue(
      target.waitForExistence(timeout: 15),
      "The fixture tile `gridTile-\(tile)` never appeared.")
    // TWO taps, because that is the shipped way in: the first moves focus, the second opens the
    // loupe (spec 3220 §2.2), and which one a given tap is depends on where focus already sits.
    target.tap()
    if !close.waitForExistence(timeout: 2) {
      target.tap()
      _ = close.waitForExistence(timeout: 5)
    }
    XCTAssertTrue(close.exists, "The loupe never opened from a tile tap.")
    return app
  }

  private func attach(name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
