import XCTest

/// IMGMGR-548 (R3 P9): the Settings sheet opens from BOTH entry points — the sidebar gear and the
/// account item — and renders every row in its group, with no offline row anywhere (p4337
/// Decision 5).
///
/// Regular (the iPad destination, landscape) carries both entry points on the sidebar column. The
/// iPhone destination is the Compact tab shell: no sidebar, so no gear — the account item on the
/// Shoots root is its one entry point, and the test asserts the gear's ABSENCE there rather than
/// skipping. The layout is read off the screen (the tab bar), never off the device idiom.
///
/// Rows are read TOP-TO-BOTTOM through a bounded, upward-only scroll: a downward swipe on a
/// sheet's list at its top dismisses the sheet on iPhone. Nothing is toggled — the suite leaves
/// the simulator's defaults as it found them.
final class SettingsSheetUITests: OrientationPinnedUITestCase {

  override class var pinnedOrientation: UIDeviceOrientation { .landscapeLeft }

  /// The header labels, EXACT (`SettingsSection.title`, rendered with `.textCase(nil)`).
  private static let headers: [(identifier: String, label: String)] = [
    ("settingsSection.account", "Account"),
    ("settingsSection.sidebar", "Sidebar"),
    ("settingsSection.library", "Library"),
    ("settingsSection.lightroomSync", "Lightroom Sync"),
    ("settingsSection.culling", "Culling"),
    ("settingsSection.gridDisplay", "Grid Display"),
    ("settingsSection.storage", "Storage"),
    ("settingsSection.about", "About"),
  ]

  func testSettingsOpensFromTheSidebarGearAndTheAccountChip() {
    let app = launch()
    let account = element(app, "accountToolbarButton")
    XCTAssertTrue(account.waitForExistence(timeout: 30), "The account item never appeared.")

    if isCompact(app) {
      XCTAssertFalse(
        element(app, "settingsGearButton").exists,
        "Compact has no sidebar, so it must carry no sidebar gear.")
    } else {
      let gear = element(app, "settingsGearButton")
      XCTAssertTrue(
        gear.waitForExistence(timeout: 10), "The Regular sidebar carries no Settings gear.")
      assertOpensSettings(app, from: gear, named: "the sidebar gear")
      dismissSettings(app)
    }
    assertOpensSettings(app, from: account, named: "the account item")
  }

  func testEveryRowRendersInItsGroupAndNoneIsOffline() {
    let app = launch()
    let account = element(app, "accountToolbarButton")
    XCTAssertTrue(account.waitForExistence(timeout: 30), "The account item never appeared.")
    let compact = isCompact(app)
    assertOpensSettings(app, from: account, named: "the account item")

    // The first group, before anything scrolls.
    assertHeader(app, 0)
    XCTAssertTrue(
      app.buttons["Sign Out…"].firstMatch.waitForExistence(timeout: 10),
      "Settings › Account has no Sign Out.")
    assertNoOfflineElement(app)

    assertHeader(app, 1)
    let sidebarVisible = element(app, "settingsSidebarVisibleToggle")
    if compact {
      XCTAssertFalse(sidebarVisible.exists, "Compact offers the Regular-only Show Sidebar row.")
    } else {
      assertRow(app, "settingsSidebarVisibleToggle")
    }
    assertRow(app, "settingsShowUntouchedToggle")
    assertRow(app, "settingsShowPinnedToggle")
    assertRow(app, "settingsShowRecentToggle")
    assertHeader(app, 2)
    assertRow(app, "settingsUntouchedSincePicker")
    assertHeader(app, 3)
    assertRow(app, "settingsLightroomModeRow")
    // IMGMGR-545: Automatic is shown, disabled, with its reason.
    assertRow(app, "settingsLightroomAutomaticRow")
    XCTAssertFalse(
      element(app, "settingsLightroomAutomaticRow").isEnabled, "Automatic sync is selectable.")
    assertRow(app, "settingsLightroomAutomaticReason")
    assertHeader(app, 4)
    assertRow(app, "accountAutoAdvanceToggle")
    assertRow(app, "settingsTapToPickDefaultToggle")
    assertHeader(app, 5)
    assertRow(app, "settingsFilenamePlatesToggle")
    assertRow(app, "settingsPicksInGroupsToggle")
    assertHeader(app, 6)
    assertRow(app, "settingsPruneMirroredToggle")
    assertHeader(app, 7)
    assertRow(app, "settingsAboutVersion")
  }

  /// IMGMGR-587: About › Version reads "<version> (<build>)" and opens What's new, whose FIRST
  /// section is headed with that very line — the running build's notes before every earlier one.
  /// The line is read off the row rather than written into the test, so the test survives every
  /// version bump and still fails when the screen opens on another build's notes.
  func testVersionRowOpensWhatsNewWithTheRunningBuildFirst() {
    let app = launch()
    let account = element(app, "accountToolbarButton")
    XCTAssertTrue(account.waitForExistence(timeout: 30), "The account item never appeared.")
    assertOpensSettings(app, from: account, named: "the account item")

    let row = element(app, "settingsAboutVersion")
    XCTAssertTrue(reveal(row, in: app), "Settings has no Version row.")
    let shown = "\(row.label) \(row.value as? String ?? "")"
    let pattern = #"[0-9]+\.[0-9]+(\.[0-9]+)? \([0-9]+\)"#
    guard let range = shown.range(of: pattern, options: .regularExpression) else {
      XCTFail("The Version row reads '\(shown)', not '<version> (<build>)'.")
      return
    }
    let running = String(shown[range])

    row.tap()
    XCTAssertTrue(
      app.navigationBars["What's new"].waitForExistence(timeout: 10),
      "Tapping Version did not open What's new.")
    let heading = element(app, "whatsNewHeading.0")
    XCTAssertTrue(heading.waitForExistence(timeout: 10), "What's new shows no section.")
    XCTAssertEqual(heading.label, running, "What's new does not open on the running build's notes.")
    let body = element(app, "whatsNewBody.0")
    XCTAssertTrue(body.waitForExistence(timeout: 5), "The running build's section has no notes.")
    XCTAssertFalse(body.label.isEmpty, "The running build's section renders empty.")
  }

  // MARK: - Helpers

  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"]
    app.launch()
    XCUIDevice.shared.orientation = Self.pinnedOrientation
    _ = app.windows.firstMatch.waitForExistence(timeout: 30)
    return app
  }

  /// The Compact tab shell is what renders — read off the screen, never the idiom.
  private func isCompact(_ app: XCUIApplication) -> Bool {
    app.tabBars.firstMatch.exists
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  private func assertOpensSettings(
    _ app: XCUIApplication, from control: XCUIElement, named: String
  ) {
    let bar = app.navigationBars["Settings"]
    let opened = openPresentation(control, revealing: bar, timeout: 15)
    if !opened {
      XCTContext.runActivity(named: "element tree with no Settings sheet") { activity in
        activity.add(XCTAttachment(string: app.debugDescription))
      }
    }
    XCTAssertTrue(opened, "Tapping \(named) did not present the Settings sheet.")
  }

  private func dismissSettings(_ app: XCUIApplication) {
    let done = app.navigationBars["Settings"].buttons["Done"]
    XCTAssertTrue(done.waitForExistence(timeout: 10), "The Settings sheet has no Done button.")
    done.tap()
    XCTAssertTrue(
      app.navigationBars["Settings"].waitForNonExistence(timeout: 10),
      "Done did not dismiss the Settings sheet.")
  }

  private func assertHeader(_ app: XCUIApplication, _ index: Int) {
    let header = Self.headers[index]
    let found = element(app, header.identifier)
    XCTAssertTrue(reveal(found, in: app), "Settings has no \(header.label) group header.")
    XCTAssertEqual(found.label, header.label, "\(header.identifier) reads differently.")
    assertNoOfflineElement(app)
  }

  private func assertRow(_ app: XCUIApplication, _ identifier: String) {
    let row = element(app, identifier)
    XCTAssertTrue(reveal(row, in: app), "Settings has no \(identifier) row.")
    assertNoOfflineElement(app)
  }

  /// Any element type — Text, buttons, toggles, headers — at the current scroll position (the
  /// list's cells are lazy, so this runs at every step of the walk).
  private func assertNoOfflineElement(_ app: XCUIApplication) {
    let offline = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@", "offline", "offline"))
    XCTAssertEqual(offline.count, 0, "Settings shows an offline element (Decision 5).")
  }

  /// Bounded and UPWARD ONLY (see the type's comment); answers whether `element` is on screen.
  /// Each step is a PARTIAL drag (no fling): in iPhone landscape the sheet's list is a few rows
  /// tall, and a `swipeUp()` throws a row past the top edge, where an upward-only walk can never
  /// bring it back.
  private func reveal(_ element: XCUIElement, in app: XCUIApplication, steps: Int = 16) -> Bool {
    if element.waitForExistence(timeout: 5), element.isHittable { return true }
    let list = app.collectionViews["settingsList"]
    let scroller = list.exists ? list : app.descendants(matching: .any)["settingsList"]
    for _ in 0..<steps {
      let from = scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
      let to = scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
      from.press(forDuration: 0.1, thenDragTo: to)
      if element.waitForExistence(timeout: 1), element.isHittable { return true }
    }
    return element.exists && element.isHittable
  }
}
