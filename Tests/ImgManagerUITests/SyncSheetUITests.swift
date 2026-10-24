import Foundation
import XCTest

/// IMGMGR-545 acceptance 2, on the real thing: More › Shoot › Sync to Lightroom… opens the Sync
/// sheet, Sync now cannot be pressed with "Lightroom is closed" off, the confirmation is never
/// remembered, and the rendered status lines are the ledger's words.
///
/// The fixture's status carries a SUCCEEDED latest, so nothing is watched when the sheet opens:
/// a request-state line can only come from a request this test made. Makes no device-idiom
/// decision; every step keys off an observed element, on both destinations.
final class SyncSheetUITests: OrientationPinnedUITestCase {

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the fixture grid.")
    return app
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  /// Opens the sheet from More › Shoot and returns its Sync now button.
  private func openSyncSheet(in app: XCUIApplication) -> XCUIElement {
    let entry = element(app, "gridMoreMenu.more.sync")
    XCTAssertTrue(
      openMoreMenu(in: app, revealing: entry, timeout: 5), "No Sync entry in the More menu.")
    entry.tap()
    let button = app.buttons["syncNowButton"]
    XCTAssertTrue(button.waitForExistence(timeout: 15), "The Sync sheet never came up.")
    return button
  }

  private func lightroomSwitch(_ app: XCUIApplication) -> XCUIElement {
    app.switches["syncLightroomClosedSwitch"].firstMatch
  }

  /// The switch's own control at the row's trailing edge — the tap a person makes (the same
  /// gesture `UntouchedSectionUITests` uses for a Settings toggle).
  private func flip(_ app: XCUIApplication) {
    let toggle = lightroomSwitch(app)
    XCTAssertTrue(toggle.waitForExistence(timeout: 5), "No 'Lightroom is closed' switch.")
    let before = toggle.value as? String
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 0.5))
      .withOffset(CGVector(dx: -30, dy: 0))
      .tap()
    let flipped = NSPredicate(format: "value != %@", before ?? "")
    _ = XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: flipped, object: toggle)], timeout: 5)
  }

  private func isOn(_ app: XCUIApplication) -> Bool {
    (lightroomSwitch(app).value as? String) == "1"
  }

  private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.25)
    }
    return condition()
  }

  func testSyncNowCannotBePressedWithTheSwitchOff() throws {
    let app = launchedApp()
    let syncNow = openSyncSheet(in: app)
    let stateLine = element(app, "syncRequestStateLine")

    XCTAssertFalse(isOn(app), "The confirmation started on.")
    XCTAssertFalse(syncNow.isEnabled, "Sync now is pressable with Lightroom not confirmed closed.")
    XCTAssertFalse(stateLine.exists, "A request-state line before any request was made.")

    // Pressing it anyway sends nothing.
    syncNow.tap()
    XCTAssertFalse(
      stateLine.waitForExistence(timeout: 3), "A disabled Sync now still started a request.")

    // Positive control: the switch, and only the switch, is what enables it.
    flip(app)
    XCTAssertTrue(waitFor(syncNow.isEnabled, timeout: 5), "The switch on did not enable Sync now.")
    flip(app)
    XCTAssertTrue(waitFor(!syncNow.isEnabled, timeout: 5), "The switch off left Sync now enabled.")
  }

  func testConfirmationIsNotRememberedBetweenRequests() throws {
    let app = launchedApp()
    let syncNow = openSyncSheet(in: app)

    flip(app)
    XCTAssertTrue(waitFor(syncNow.isEnabled, timeout: 5), "The switch on did not enable Sync now.")
    syncNow.tap()

    let stateLine = element(app, "syncRequestStateLine")
    XCTAssertTrue(stateLine.waitForExistence(timeout: 15), "Sync now started no request.")
    XCTAssertTrue(
      waitFor(stateLine.label.hasPrefix("Sync finished at"), timeout: 30),
      "The request never reached a terminal state: '\(stateLine.label)'.")
    XCTAssertFalse(isOn(app), "The confirmation survived the request.")
    XCTAssertFalse(syncNow.isEnabled, "A second request is possible without a new confirmation.")

    // An unused confirmation does not survive closing the sheet either.
    flip(app)
    XCTAssertTrue(waitFor(isOn(app), timeout: 5), "The switch did not turn on.")
    app.buttons["syncSheetDone"].tap()
    XCTAssertTrue(waitFor(!syncNow.exists, timeout: 10), "The Sync sheet did not close.")
    let reopened = openSyncSheet(in: app)
    XCTAssertFalse(isOn(app), "The reopened sheet remembered the confirmation.")
    XCTAssertFalse(reopened.isEnabled, "The reopened sheet's Sync now is pressable.")
  }

  func testRenderedLedgerText() throws {
    let app = launchedApp()
    _ = openSyncSheet(in: app)
    let line = element(app, "syncStatusLine")
    let expected =
      "5 marks not yet written to sidecars · last sync 14:05 CEST · 1 refused"
      + " · 3 on JPEG/HEIF can't travel"
    XCTAssertTrue(
      waitFor(line.label == expected, timeout: 15),
      "The status line reads '\(line.label)', not the ledger's words.")
    XCTAssertEqual(
      element(app, "syncReadMetadataLine").label,
      "Read Metadata from Files in Lightroom: not confirmed")
    XCTAssertTrue(element(app, "syncContentRow").exists, "No 'Writes: Picks & dislikes' row.")

    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "IMGMGR-545-sync-sheet"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
