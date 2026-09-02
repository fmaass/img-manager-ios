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
final class LoupeAutoAdvanceScreenshotUITests: OrientationPinnedUITestCase {

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

  // MARK: - IMGMGR-275: the mark bar shows the FOCUSED photograph's own verdict

  /// Owner report 2026-08-31 (iPad, native app): "marks cannot be seen". The unit suite proves
  /// the presentation rule; this reads the SHIPPED control out of the running app's accessibility
  /// tree — a bar whose buttons are decorative again turns this leg RED — and attaches the
  /// screenshot the ticket's acceptance names, on BOTH gate destinations.
  ///
  /// Advance-on-mark is turned OFF for the duration on purpose: with the cadence on, the mark
  /// moves the loupe to the NEXT frame, and a plain-reading bar there is the correct answer to a
  /// different question. Restored to whatever it was found at, like every test in this file.
  func testLoupeMarkBarReflectsTheFocusedPhotographsVerdict() throws {
    let app = launchAndOpenLoupe()

    let toggle = app.buttons["loupeAutoAdvanceToggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10), "The loupe header toggle is missing.")
    let wasOn = (toggle.value as? String) == "On"
    if wasOn {
      toggle.tap()
      Thread.sleep(forTimeInterval: 0.8)
    }
    XCTAssertEqual(
      toggle.value as? String, "Off", "Could not park the cadence for a same-frame reading.")

    // BY IDENTIFIER (IMGMGR-280). These queries used to match the CONTAINER's identifier plus the
    // button's label, because `.accessibilityIdentifier("loupeMarkBar")` on the enclosing HStack
    // propagated DOWN and overrode every child's: the 23:26 gate run dumped all four controls
    // reporting `identifier: 'loupeMarkBar'`, `loupeClearButton` — which has carried its own
    // identifier since P5 — included. The bar is an `.accessibilityElement(children: .contain)`
    // now, so each control answers to its own name, and THAT is what these three lines assert:
    // put the identifier back on the bare HStack and they stop resolving.
    let pick = app.buttons["loupePickButton"]
    XCTAssertTrue(
      pick.waitForExistence(timeout: 10),
      "The loupe mark bar has no Pick control (IMGMGR-275).")

    let clear = app.buttons["loupeClearButton"]
    XCTAssertTrue(
      clear.waitForExistence(timeout: 10),
      "`loupeClearButton` does not resolve by its own identifier — the mark bar's container "
        + "identifier is shadowing its children again (IMGMGR-280).")

    // STATE-INDEPENDENT, like every test in this file. Which frame the coordinate probe lands on
    // differs by idiom and the DEBUG fixture ships some photographs already marked — the 00:30
    // iPhone run opened on `STUB_0001.jpg, picked` while the iPad opened on an unmarked one, and
    // a hard-coded starting verdict fails on exactly one of them for a reason that has nothing to
    // do with the behaviour under test. So the frame is driven to unmarked first, through the
    // bar's own Clear control, and the reading is asserted from there.
    XCTContext.runActivity(named: "Pick reads \(pick.value as? String ?? "nil") on arrival") { _ in
    }
    if (pick.value as? String) != "Not picked" {
      clear.tap()
      let cleared = expectation(
        for: NSPredicate(format: "value == 'Not picked'"), evaluatedWith: pick)
      wait(for: [cleared], timeout: 10)
    }
    XCTAssertEqual(
      pick.value as? String, "Not picked",
      "The Pick control does not report an unmarked frame as unmarked — its state reading is "
        + "absent or inverted.")
    attach(name: "loupe-mark-bar-unmarked")

    pick.tap()
    let becamePicked = expectation(
      for: NSPredicate(format: "value == 'Picked'"), evaluatedWith: pick)
    wait(for: [becamePicked], timeout: 10)
    attach(name: "loupe-mark-bar-picked")

    // Undo takes the verdict back, and the control's own reading with it.
    let undo = app.buttons["loupeUndoButton"]
    XCTAssertTrue(undo.waitForExistence(timeout: 10), "The loupe mark bar has no Undo control.")
    undo.tap()
    let backToPlain = expectation(
      for: NSPredicate(format: "value == 'Not picked'"), evaluatedWith: pick)
    wait(for: [backToPlain], timeout: 10)

    if wasOn {
      toggle.tap()
      Thread.sleep(forTimeInterval: 0.8)
      XCTAssertEqual(toggle.value as? String, "On", "The cadence preference was not restored.")
    }
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
    flipInListRow(row)
    let after = row.value as? String
    let flip = "account row value \(before ?? "nil") -> \(after ?? "nil")"
    XCTContext.runActivity(named: flip) { _ in }
    XCTAssertNotEqual(
      before, after, "Tapping the account row did not change the preference (\(before ?? "nil")).")
    attach(name: "account-auto-advance-row-flipped")

    flipInListRow(row)
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

  /// Launches the DEBUG fixture composition and opens the loupe on the fixture's FIRST tile,
  /// addressed by that tile's own identifier — the same way `LoupeZoomScreenshotUITests` does
  /// it, and for the same reason (IMGMGR-336): the normalized-coordinate probe both classes
  /// used encoded a pane geometry that the simulator-global device orientation, not this class,
  /// decides.
  private func launchAndOpenLoupe() -> XCUIApplication {
    let app = launchStubbedApp()

    let dislike = app.buttons["Dislike"]
    XCTAssertTrue(
      dislike.waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared — expected the DEBUG fixture composition's "
        + "populated grid, got something else (sign-in screen, blank screen, failed stub).")

    let close = app.buttons["loupeClose"]
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

  /// Flips a SwiftUI `Toggle` that lives in a `List` row, which a bare `element.tap()` does not.
  ///
  /// The 14:02 gate run is the evidence and it is unambiguous. The query already resolves a
  /// `Switch` (the log reads `Checking existence of "accountAutoAdvanceToggle" Switch`), the tap
  /// synthesised cleanly against a hittable element, and the value read back "1" on both sides of
  /// it — while `testLoupeHeaderCarriesTheAutoAdvanceToggle` flipped the SAME preference three
  /// times in that same run. So the preference's write-through is fine and the tap simply never
  /// reached the control: the row's accessibility element spans the whole row, `tap()` aims at its
  /// centre, that centre is the label, and a SwiftUI toggle's label is not a hit target.
  ///
  /// The remedy is a fixed distance INSIDE the element's trailing edge rather than a normalised
  /// fraction of it: the switch is trailing-anchored and about 51 pt wide, so an offset lands on
  /// it at any row width — a fraction would drift off the control as the sheet gets wider, which
  /// is exactly the "guessed pane width" this suite is not allowed to encode.
  private func flipInListRow(_ toggle: XCUIElement) {
    XCTContext.runActivity(named: "toggle element frame \(toggle.frame)") { _ in }
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 0.5))
      .withOffset(CGVector(dx: -30, dy: 0))
      .tap()
    Thread.sleep(forTimeInterval: 0.8)
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
