import XCTest

/// IMGMGR-502: Triage's photo area in the two preview states the session tests cannot see — a
/// preview that arrives late, and a photograph with no preview at all.
///
/// What the photo area renders is read off `debugProbe.triagePreview` (`loading`, `<id>:image`,
/// `<id>:none`), which publishes the very value the photo renders from (`shownPreview`): the
/// photo's own element collapses its children, so neither the spinner nor the "No preview" text
/// is visible to XCUITest on its own. The photograph named on screen is `triagePhoto`'s value.
///
/// Launch fixture: `-UITestStubGrid` (photograph 1 is picked, so a pass starts on photograph 2),
/// plus `-UITestHoldPreviewOf 3` (photograph 3's preview, and only it, is parked until the test
/// taps the fixture-only `debugReleaseHeldPreview` — never a timer; a global "after the first"
/// hold flaked on the gate when the grid's own preview loads used up "the first") or
/// `-UITestNoPreviews` (every preview answers 404). Triage is Compact-only, so both cases skip
/// at Regular.
final class TriagePreviewStatesUITests: OrientationPinnedUITestCase {

  /// The fixture's own order (`DebugStubTransport.fixtureImages`: index 0 is picked, indices
  /// 1-4 are unmarked), read independently of anything Triage shows: the pass starts on
  /// photograph 2, and a Skip moves the cursor to photograph 3.
  private static let firstPhotograph = 2
  private static let nextPhotograph = 3

  // MARK: - AC1: a held-back preview

  func testAHeldBackPreviewShowsTheCursorsPhotographOnceItArrives() throws {
    let app = try launchedCompactGrid(
      extraArguments: ["-UITestHoldPreviewOf", String(Self.nextPhotograph)])
    openTriage(app)
    let photo = element(app, "triagePhoto")
    let probe = element(app, "debugProbe.triagePreview")
    let held = element(app, "debugProbe.heldPreviews")

    // Photograph 2's preview is not held: the pass's first photograph is on screen.
    XCTAssertTrue(
      waitFor("value BEGINSWITH 'STUB_'", photo, timeout: 15),
      "The pass's first photograph was never shown.")
    XCTAssertEqual(
      photographID(app), Self.firstPhotograph, "The pass did not start on the expected photograph.")
    let start = try XCTUnwrap(position(app), "Triage shows no 'i of N' position.")
    XCTAssertTrue(
      waitFor("value == '\(Self.firstPhotograph):image'", probe, timeout: 5),
      "The photo area does not render photograph \(Self.firstPhotograph)'s preview: "
        + "\(String(describing: probe.value)).")

    // Skip: an advance with no server write, so nothing but the preview is in flight.
    let skip = element(app, "triageSkip")
    XCTAssertTrue(waitFor("isEnabled == true", skip), "Skip is not enabled on a shown photograph.")
    skip.tap()
    XCTAssertTrue(waitForPosition(app, start + 1), "Skip did not advance the cursor.")

    // The cursor's preview is parked in the fixture until this test releases it — observed, not
    // assumed — so the pending state below is read while it provably still holds.
    XCTAssertTrue(
      // At least one: Triage's request for photograph 3 — plus any earlier load of the same
      // preview elsewhere in the app, which the fixture parks too.
      waitFor("value MATCHES 'heldPreviews=[1-9][0-9]*'", held, timeout: 15),
      "The fixture never held the cursor's preview: \(String(describing: held.value)).")
    // The photo area shows the spinner — never the previous photograph, which is what a photo
    // lagging the cursor would still be rendering.
    XCTAssertEqual(
      probe.value as? String, "loading",
      "While the cursor's preview is held back the photo area renders "
        + "\(String(describing: probe.value)), not the loading state.")
    // An empty accessibility value can read back as nil, so the check is "names no file".
    let heldName = (photo.value as? String) ?? ""
    XCTAssertFalse(
      heldName.hasPrefix("STUB_"),
      "'\(heldName)' is named while the cursor's preview is held back.")

    // Release it, then the photograph on screen must be the cursor's — the independently
    // expected next photograph, named AND rendered.
    let release = element(app, "debugReleaseHeldPreview")
    XCTAssertTrue(release.waitForExistence(timeout: 5), "No fixture release control in Triage.")
    release.tap()
    let expectedName = "STUB_" + String(format: "%04d", Self.nextPhotograph) + ".jpg"
    XCTAssertTrue(
      waitFor("value == '\(expectedName)'", photo, timeout: 15),
      "Photograph \(Self.nextPhotograph) was not shown once its preview was released: "
        + "\(String(describing: photo.value)).")
    XCTAssertTrue(
      waitFor("value == '\(Self.nextPhotograph):image'", probe, timeout: 5),
      "Photograph \(Self.nextPhotograph) is named but the photo area renders "
        + "\(String(describing: probe.value)).")
  }

  // MARK: - AC2: no preview

  /// The decision this pins (IMGMGR-502 AC2): on a "No preview" photograph Pick and Dislike stay
  /// ENABLED, as shipped. A mark applies to the photograph, not to its preview, so a missing
  /// proxy does not block marking — `TriageView.loadImage` reports the placeholder to the
  /// session (`didDisplay`) exactly as it reports a loaded image, and that is what enables them.
  func testNoPreviewKeepsPickAndDislikeEnabledAndPickStillMarks() throws {
    let app = try launchedCompactGrid(extraArguments: ["-UITestNoPreviews"])
    openTriage(app)
    let probe = element(app, "debugProbe.triagePreview")

    XCTAssertTrue(
      waitFor("value ENDSWITH ':none'", probe, timeout: 15),
      "The photo area never showed 'No preview': \(String(describing: probe.value)).")
    XCTAssertTrue(
      waitFor("value BEGINSWITH 'STUB_'", element(app, "triagePhoto"), timeout: 5),
      "The 'No preview' photograph is not named on screen.")
    let cursor = try XCTUnwrap(photographID(app), "The shown photograph names no file.")
    XCTAssertEqual(
      probe.value as? String, "\(cursor):none",
      "The placeholder is not the cursor's (photograph \(cursor)).")

    XCTAssertTrue(
      waitFor("isEnabled == true", element(app, "triageDislike"), timeout: 5),
      "Dislike is disabled on a 'No preview' photograph.")
    let pick = element(app, "triagePick")
    XCTAssertTrue(
      waitFor("isEnabled == true", pick, timeout: 5),
      "Pick is disabled on a 'No preview' photograph.")

    // And the mark really applies: one write, and the pass moves on.
    let marks = element(app, "debugProbe.marks")
    XCTAssertTrue(marks.waitForExistence(timeout: 10), "No 'debugProbe.marks' inside Triage.")
    let before = try XCTUnwrap(
      numbers(in: (marks.value as? String) ?? "").first,
      "'debugProbe.marks' is unreadable: \(String(describing: marks.value)).")
    let start = try XCTUnwrap(position(app), "Triage shows no 'i of N' position.")
    pick.tap()
    XCTAssertTrue(
      waitFor("value == 'markWrites=\(before + 1)'", marks, timeout: 10),
      "Pick on a 'No preview' photograph wrote no mark.")
    XCTAssertTrue(waitForPosition(app, start + 1), "Pick did not advance the cursor.")
  }

  // MARK: - Shared

  private func launchedCompactGrid(extraArguments: [String]) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"] + extraArguments
    app.launch()
    XCTAssertTrue(
      app.buttons["gridPickButton"].waitForExistence(timeout: 30),
      "Action bar (gridPickButton) never appeared — expected the DEBUG fixture composition's "
        + "populated grid.")
    guard rendersCompactShell(app) else {
      throw XCTSkip("Regular width: Triage is Compact-only; the iPad culls in the loupe.")
    }
    return app
  }

  private func openTriage(_ app: XCUIApplication) {
    let entry = gridTriageEntry(app)
    XCTAssertTrue(
      entry.waitForExistence(timeout: 15), "No 'gridTriageButton' in the grid's options row.")
    XCTAssertTrue(waitFor("isEnabled == true", entry), "Triage is disabled on a populated grid.")
    entry.tap()
    XCTAssertTrue(
      element(app, "triagePosition").waitForExistence(timeout: 15), "Triage did not open.")
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func waitFor(_ format: String, _ element: XCUIElement, timeout: TimeInterval = 10)
    -> Bool
  {
    let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
    return XCTWaiter.wait(for: [done], timeout: timeout) == .completed
  }

  /// The cursor's index, off "i of N".
  private func position(_ app: XCUIApplication) -> Int? {
    numbers(in: element(app, "triagePosition").label).first
  }

  private func waitForPosition(_ app: XCUIApplication, _ expected: Int) -> Bool {
    waitFor("label BEGINSWITH '\(expected) of '", element(app, "triagePosition"))
  }

  /// The photograph on screen, off its file name ("STUB_0002.jpg" is photograph 2).
  private func photographID(_ app: XCUIApplication) -> Int? {
    numbers(in: (element(app, "triagePhoto").value as? String) ?? "").first
  }

  private func numbers(in text: String) -> [Int] {
    text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
  }
}
