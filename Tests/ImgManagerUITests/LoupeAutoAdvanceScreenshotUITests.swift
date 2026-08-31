import XCTest

/// WP13 P8 (IMGMGR-214): the retained visual evidence this phase's Verification names — the
/// loupe header with advance-on-mark ON and OFF, and the account sheet's own row — plus the
/// causal coverage no unit suite can give. The persistent-chrome rule is that the cadence must
/// never be only a hidden preference, so these tests drive the REAL controls in the running app
/// and read the state back from accessibility: deleting either chrome twin turns this leg RED.
///
/// STATE-INDEPENDENT by construction. `GridPreferences` persists into the app's standard
/// `UserDefaults`, which outlives a relaunch inside one simulator, so neither test may assume
/// the factory default — each reads the control's CURRENT value, drives it from there, and
/// restores what it found. The "on with nothing stored" claim belongs to
/// `GridStoreTests.autoAdvanceDefaultsToOnWithNoStoredPreference`, which runs against its own
/// ephemeral defaults suite, where the claim can actually be true.
final class LoupeAutoAdvanceScreenshotUITests: XCTestCase {

  // MARK: - Chrome twin 1: the loupe header

  func testLoupeHeaderCarriesTheAutoAdvanceToggle() throws {
    let app = launchAndOpenLoupe()

    let toggle = app.buttons["loupeAutoAdvanceToggle"]
    XCTAssertTrue(
      toggle.waitForExistence(timeout: 10),
      "The advance-on-mark chrome twin is missing from the loupe header — the cadence must "
        + "never be reachable only as a hidden preference.")

    if toggle.value as? String == "Off" {
      toggle.tap()
      Thread.sleep(forTimeInterval: 0.8)
    }
    XCTAssertEqual(
      toggle.value as? String, "On",
      "The loupe header toggle would not go on — the control is not wired to the preference.")
    attach(name: "loupe-auto-advance-on")

    toggle.tap()
    Thread.sleep(forTimeInterval: 0.8)
    XCTAssertEqual(
      toggle.value as? String, "Off",
      "Tapping the loupe header toggle did not turn advance-on-mark off.")
    attach(name: "loupe-auto-advance-off")

    // Leave the shipped default behind for whatever runs next in this simulator.
    toggle.tap()
    Thread.sleep(forTimeInterval: 0.8)
    XCTAssertEqual(toggle.value as? String, "On")
  }

  // MARK: - Chrome twin 2: the account sheet's row

  func testAccountSheetCarriesTheAutoAdvanceRow() throws {
    let app = launchStubbedApp()

    // By IDENTIFIER: the 09:02 gate run proved `app.buttons["Account"]` resolves as
    // `"Account" IN identifiers` and a `Label`'s text is not one, so the toolbar item carries an
    // explicit identifier now (`RootView.swift`).
    let account = app.descendants(matching: .any)["accountToolbarButton"]
    XCTAssertTrue(
      account.waitForExistence(timeout: 30),
      "The Account toolbar item never appeared — expected the DEBUG fixture composition's "
        + "workspace, got something else (sign-in screen, blank screen, failed stub).")
    account.tap()

    // A `Toggle` in a `List` is a switch; the permissive query is the fallback, not the first
    // guess, because only the switch itself carries the on/off value this test reads.
    var row = app.switches["accountAutoAdvanceToggle"].firstMatch
    if !row.waitForExistence(timeout: 10) {
      row = app.descendants(matching: .any)["accountAutoAdvanceToggle"].firstMatch
    }
    if !row.exists {
      XCTContext.runActivity(named: "element tree with no advance-on-mark row") { activity in
        activity.add(XCTAttachment(string: app.debugDescription))
      }
      attach(name: "account-row-missing")
    }
    XCTAssertTrue(
      row.exists,
      "The account sheet has no advance-on-mark row — the preference's second chrome surface, "
        + "the one that exists so the cadence is reachable without opening the loupe.")
    attach(name: "account-auto-advance-row")

    // A real write, read back through the same control: a row that renders but changes nothing
    // is exactly the "hidden preference with a decoration" this rule exists to prevent.
    let before = row.value as? String
    row.tap()
    Thread.sleep(forTimeInterval: 0.8)
    let after = row.value as? String
    let flip = "account row value \(before ?? "nil") -> \(after ?? "nil")"
    XCTContext.runActivity(named: flip) { _ in }
    XCTAssertNotEqual(
      before, after, "Tapping the account row did not change the preference (\(before ?? "nil")).")
    attach(name: "account-auto-advance-row-flipped")

    row.tap()
    Thread.sleep(forTimeInterval: 0.8)
    XCTAssertEqual(row.value as? String, before, "The account row did not restore its state.")
  }

  // MARK: - Shared

  private func launchStubbedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    return app
  }

  /// Launches the DEBUG fixture composition and opens the loupe on a tile — the same probe
  /// `LoupeZoomScreenshotUITests` uses, and for the same reason: a tile carries no
  /// accessibility identifier, and the pane the tiles occupy differs by layout mode, which
  /// this test must not encode (no idiom branching, no guessed pane widths).
  private func launchAndOpenLoupe() -> XCUIApplication {
    let app = launchStubbedApp()

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
