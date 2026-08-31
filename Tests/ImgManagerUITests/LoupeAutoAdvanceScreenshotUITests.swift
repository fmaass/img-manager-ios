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

  /// Restored by IMGMGR-255. WP13 P8 DELETED this test (commit `c8c474e`) rather than leave it
  /// red, because the sheet could not be opened at all: `RootView` attached its account
  /// `ToolbarItem` to the container WRAPPING the `NavigationSplitView`, which owns no bar, so
  /// SwiftUI dropped the item on both idioms in both launch states. The item rides the split
  /// view's own columns now, so this assertion is finally about the row again.
  ///
  /// LAUNCH STATE 1 of 2 — the queue root: the fixture's auto-select is skipped
  /// (`-UITestStubSkipAutoSelect`, the flag WP8 P7 added), so Compact stays on the sidebar column
  /// it launches into instead of pushing the shoot grid over it, and the sidebar's own bar is the
  /// one on screen. `testAccountToolbarItemRendersWithTheShootAlreadyOpen` takes the other state.
  /// Deliberately NO fallback navigation here (the draft patch carried a Back-and-look-again
  /// rescue): a rescue would hide exactly the placement regression this test exists to catch.
  func testAccountSheetCarriesTheAutoAdvanceRow() throws {
    let app = launchStubbedApp(skipAutoSelect: true)

    // By IDENTIFIER: the 09:02 gate run proved `app.buttons["Account"]` resolves as
    // `"Account" IN identifiers` and a `Label`'s text is not one, so the toolbar item carries an
    // explicit identifier (`RootView.swift`).
    let account = app.descendants(matching: .any)["accountToolbarButton"]
    if !account.waitForExistence(timeout: 30) {
      XCTContext.runActivity(named: "element tree with no account toolbar item") { activity in
        activity.add(XCTAttachment(string: app.debugDescription))
      }
      attach(name: "account-item-missing-at-queue-root")
    }
    XCTAssertTrue(
      account.exists,
      "The Account toolbar item never appeared at the queue root — the account sheet and Sign "
        + "Out are unreachable again (IMGMGR-255).")
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

    // Sign Out is the sheet's OTHER reason to exist, and IMGMGR-255's AC names it. Existence and
    // hittability only, never a tap: the next stage is a real confirmation dialog over a real
    // credential, and this suite must leave the simulator signed in for whatever runs next.
    let signOut = app.buttons["Sign Out…"].firstMatch
    XCTAssertTrue(
      signOut.waitForExistence(timeout: 10),
      "The account sheet's Sign Out control is not reachable.")
    XCTAssertTrue(signOut.isHittable, "The account sheet's Sign Out control is not hittable.")

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

  // MARK: - Chrome twin 2, the other launch state

  /// LAUNCH STATE 2 of 2 — a shoot already open. IMGMGR-255's AC is that the item renders on
  /// BOTH idioms in BOTH launch states, and the two states are not the same surface: with the
  /// fixture's auto-select left on, Compact pushes the shoot grid over the sidebar, so the only
  /// bar on screen is the grid's, not the queue's — the 10:15 P8 gate run dumped exactly that
  /// bar (`BackButton 'img-manager'` and `Info`, no account item anywhere). Regular keeps both
  /// columns and both bars. So this is the half the queue-root test above cannot see, and the
  /// gate running the pair on the iPhone AND the iPad destination is the both-idioms half.
  func testAccountToolbarItemRendersWithTheShootAlreadyOpen() throws {
    let app = launchStubbedApp()

    // The fixture's auto-select is asynchronous, so wait on chrome that only exists once a shoot
    // has actually loaded before concluding anything about what the bar carries.
    let dislike = app.buttons["Dislike"]
    XCTAssertTrue(
      dislike.waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared — expected the DEBUG fixture composition's "
        + "populated grid, got something else (sign-in screen, blank screen, failed stub).")

    let account = app.descendants(matching: .any)["accountToolbarButton"]
    if !account.waitForExistence(timeout: 15) {
      XCTContext.runActivity(named: "element tree with no account toolbar item") { activity in
        activity.add(XCTAttachment(string: app.debugDescription))
      }
      attach(name: "account-item-missing-over-open-shoot")
    }
    XCTAssertTrue(
      account.exists,
      "The Account toolbar item is missing while a shoot is open — on Compact the pushed "
        + "grid's bar is the only one on screen, so the item has to ride that bar too "
        + "(IMGMGR-255).")
    account.tap()

    let sheet = app.navigationBars["Account"]
    XCTAssertTrue(
      sheet.waitForExistence(timeout: 10),
      "Tapping the Account toolbar item over an open shoot did not present the account sheet.")
    attach(name: "account-sheet-over-open-shoot")
    app.buttons["Done"].firstMatch.tap()
  }

  // MARK: - Shared

  private func launchStubbedApp(skipAutoSelect: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments =
      skipAutoSelect ? ["-UITestStubGrid", "-UITestStubSkipAutoSelect"] : ["-UITestStubGrid"]
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
