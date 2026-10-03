import XCTest

/// WP31 P2 (IMGMGR-461) acceptance: the Pass Summary sheet counts the pass (net of undo), the
/// Handoff activity carries the shoot and the position, and the receiving route opens the loupe
/// on that photograph.
///
/// Launch fixture: `-UITestStubGrid`. Folder 1 opens on its own; photograph 1 is picked, so a
/// pass starts on photograph 2 (plan decision 2). The activity a surface made current is
/// read off `debugProbe.activity` on the presented surface (Triage, then the sheet); how a
/// continuation ended is read off `debugProbe.continuation`, the positive signal a "no loupe"
/// assertion waits for. The receiving side is driven by `-UITestContinueActivity <json>`, which
/// feeds the same function `.onContinueUserActivity` calls — Handoff between two simulators is
/// not available to the gate.
///
/// The iPhone cases skip at Regular (Triage is Compact-only); the iPad cases skip at Compact.
final class PassSummaryHandoffUITests: OrientationPinnedUITestCase {

  // MARK: - iPhone: the summary counts the pass, the activity carries the position

  func testPassSummaryCountsMatchThePassAndTheActivityCarriesThePosition() throws {
    let app = try launchedCompactGrid()
    openTriage(app)
    let start = try XCTUnwrap(position(app), "Triage shows no 'i of N' position.")

    decide(app, "triagePick", expecting: start + 1)
    decide(app, "triageDislike", expecting: start + 2)
    decide(app, "triageSkip", expecting: start + 3)
    decide(app, "triagePick", expecting: start + 4)
    let undo = element(app, "triageUndo")
    XCTAssertTrue(waitFor("isEnabled == true", undo), "Undo is not enabled after the Pick.")
    undo.tap()
    XCTAssertTrue(waitForPosition(app, start + 3), "Undo after the Pick did not step back.")
    waitForShownPhotograph(app)
    let cursorIndex = try XCTUnwrap(position(app), "Triage shows no position after Undo.")
    let cursorID = try XCTUnwrap(photographID(app), "The Triage photograph names no file.")

    // Triage advertises its own activity while it is open.
    let triageFields = try activityFields(app, source: "triage", imageID: nil)
    XCTAssertEqual(triageFields["type"], "live.discomarder.imgmanager.triage")
    XCTAssertEqual(triageFields["eligible"], "true", "Triage's activity: \(triageFields).")
    XCTAssertEqual(triageFields["folderID"], "1", "Triage's activity: \(triageFields).")

    element(app, "triageBack").tap()
    XCTAssertTrue(
      waitFor("exists == false", element(app, "triagePosition")), "Back did not close Triage.")

    XCTAssertEqual(try statValue(app, "picks"), 1, "Picks are not net of the undone Pick.")
    XCTAssertEqual(try statValue(app, "dislikes"), 1)
    XCTAssertEqual(try statValue(app, "skipped"), 1)
    XCTAssertTrue(element(app, "passSummary.handoff").exists, "No 'Continue on iPad' row.")
    XCTAssertTrue(
      app.navigationBars["Pass summary"].waitForExistence(timeout: 10),
      "An unfinished pass is not titled 'Pass summary'.")

    let fields = try activityFields(app, source: "passSummary", imageID: cursorID)
    XCTAssertEqual(fields["type"], "live.discomarder.imgmanager.triage")
    XCTAssertEqual(fields["eligible"], "true", "The activity is not eligible for Handoff.")
    XCTAssertEqual(fields["folderID"], "1", "The activity does not carry the fixture folder.")
    XCTAssertEqual(fields["imageID"], String(cursorID), "The activity's position: \(fields).")
    XCTAssertEqual(fields["index"], String(cursorIndex), "The activity's index: \(fields).")
    XCTAssertEqual(fields["completed"], "false")
    attach(name: "IMGMGR-461-pass-summary")

    element(app, "passSummaryDone").tap()
    XCTAssertTrue(
      waitFor("exists == false", element(app, "passSummary.picks")), "Done left the sheet up.")
  }

  // MARK: - iPhone: deciding the last photograph ends the pass, completed

  func testDecidingTheLastPhotographByPickEndsThePassCompleted() throws {
    try assertPassEndsOnLastPhotograph(by: "triagePick", picks: 1)
  }

  func testDecidingTheLastPhotographBySkipEndsThePassCompleted() throws {
    try assertPassEndsOnLastPhotograph(by: "triageSkip", picks: 0)
  }

  // MARK: - iPhone: a continuation arriving while the Pass Summary is up

  /// IMGMGR-501: the receiving route against the REAL dismissal, not the gate's fakes. A Handoff
  /// of this pass's own position arrives mid-session while the Pass Summary sheet is up — the
  /// fixture trigger on the sheet (`-UITestMidSessionContinuation`) hands the sheet's own payload
  /// to the running process's `continueTriage(userInfo:)`: the route dismisses the sheet, waits
  /// for its `onDismiss`, and only then opens the loupe — at Compact, the loupe's cover, which
  /// UIKit refuses while the sheet is still going. The launch probe, read before and after,
  /// proves it was the same process throughout.
  func testContinuationWhileThePassSummaryIsUpOpensTheLoupeAfterItsDismissal() throws {
    let app = try launchedCompactGrid(extraArguments: ["-UITestMidSessionContinuation"])
    let launch = try launchID(app)
    openTriage(app)
    let start = try XCTUnwrap(position(app), "Triage shows no 'i of N' position.")
    decide(app, "triageSkip", expecting: start + 1)
    waitForShownPhotograph(app)
    let cursorID = try XCTUnwrap(photographID(app), "The Triage photograph names no file.")
    element(app, "triageBack").tap()
    XCTAssertTrue(
      waitFor("exists == false", element(app, "triagePosition")), "Back did not close Triage.")

    _ = try activityFields(app, source: "passSummary", imageID: cursorID)
    let sheet = element(app, "passSummary.skipped")
    XCTAssertTrue(sheet.waitForExistence(timeout: 15), "The Pass Summary sheet is not up.")

    // Gate on 1676195: `app.open(url)` RELAUNCHED the app on the iPhone destination, so the
    // payload reached a fresh process with no sheet. The fixture trigger on the sheet hands the
    // sheet's own advertised payload to THIS process's receiving route instead.
    let trigger = element(app, "debugTrigger.midSessionContinuation")
    XCTAssertTrue(
      trigger.waitForExistence(timeout: 10), "No fixture continuation trigger on the sheet.")
    trigger.tap()

    XCTAssertTrue(
      waitFor("exists == false", sheet, timeout: 15), "The continuation left the sheet up.")
    let back = element(app, "loupeBack")
    XCTAssertTrue(
      back.waitForExistence(timeout: 30), "The loupe did not open after the sheet's dismissal.")
    XCTAssertFalse(sheet.exists, "The loupe opened with the Pass Summary sheet still up.")
    attach(name: "IMGMGR-501-continued-over-pass-summary")

    // The probes sit on the workspace, which the loupe's cover hides: read them after Back.
    back.tap()
    XCTAssertTrue(waitFor("exists == false", back, timeout: 15), "Back did not close the loupe.")
    // Review advisory: a relaunch STOPS the test here — the ordering asserts below would only
    // describe a fresh process and fail misleadingly.
    guard try launchID(app) == launch else {
      XCTFail(
        "The app was RELAUNCHED during the continuation: the probes describe a fresh process "
          + "that never showed the Pass Summary, so their order proves nothing.")
      return
    }
    XCTAssertTrue(
      waitFor("value == 'continuation=opened-\(cursorID)'", continuationProbe(app), timeout: 15),
      "The continuation did not open \(cursorID): "
        + "\(String(describing: continuationProbe(app).value)).")
    // Review r1 + the review of ada3ad8: the ORDER at the route boundary pins that the route
    // waited for the sheet's settlement — the sheet settled, and the very next route event is
    // the loupe opening on the advertised photograph. WHICH path settled it (`onDismiss`, or
    // the leaving grace while an `onDismiss` carries no generation) is a follow-up ticket.
    let events = element(app, "debugProbe.routeEvents")
    let order = ".*passSummarySheet:(onDismiss|grace)>openLoupe-\(cursorID)"
    XCTAssertTrue(
      waitFor(NSPredicate(format: "value MATCHES %@", order), events),
      "The loupe did not open right after the sheet's settlement: "
        + "\(String(describing: events.value)).")
    let dismissal = element(app, "debugProbe.dismissal")
    XCTAssertTrue(
      waitFor("value MATCHES 'dismissal=passSummarySheet:(onDismiss|grace)'", dismissal),
      "The route did not wait for the sheet's settlement: "
        + "\(String(describing: dismissal.value)).")
  }

  // MARK: - iPad: the receiving route

  /// Photograph 7015 is on the paged fixture shoot's SECOND page, so the route has to page. The
  /// payload's `index` is deliberately WRONG (3): the receiver resolves by id, never by index,
  /// so the loupe still lands on 15 of 20.
  func testContinueActivityOpensTheLoupeOnAPhotographBeyondTheFirstPage() throws {
    let app = try launchedRegular(continuing: 7015)
    XCTAssertTrue(
      waitFor("value == 'continuation=opened-7015'", continuationProbe(app), timeout: 30),
      "The continuation did not open 7015: "
        + "\(String(describing: continuationProbe(app).value)).")
    let title = app.staticTexts["loupeTitle"]
    XCTAssertTrue(title.waitForExistence(timeout: 15), "The loupe did not open.")
    XCTAssertTrue(
      waitFor("label ENDSWITH '15 of 20'", title),
      "The loupe is not on photograph 15 of 20: '\(title.label)'.")
    attach(name: "IMGMGR-461-continued-loupe")
  }

  func testContinueActivityForAnUnknownPhotographOpensTheGridOnly() throws {
    let app = try launchedRegular(continuing: 999_999)
    XCTAssertTrue(
      waitFor("value == 'continuation=notFound'", continuationProbe(app), timeout: 30),
      "The continuation did not end as not found: "
        + "\(String(describing: continuationProbe(app).value)).")
    XCTAssertTrue(
      element(app, "gridTile-7001").waitForExistence(timeout: 15),
      "The grid did not open on the continued shoot.")
    XCTAssertFalse(app.staticTexts["loupeTitle"].exists, "A loupe opened on an unknown id.")
    XCTAssertFalse(element(app, "loupeBack").exists, "A loupe opened on an unknown id.")
  }

  // MARK: - Shared

  private func assertPassEndsOnLastPhotograph(by identifier: String, picks: Int) throws {
    let app = try launchedCompactGrid()
    openTriage(app)
    let start = try XCTUnwrap(position(app), "Triage shows no 'i of N' position.")
    let total = try XCTUnwrap(
      numbers(in: element(app, "triagePosition").label).last, "Triage shows no total.")
    XCTAssertGreaterThan(total, start, "The fixture pass has nothing to skip to.")
    for next in stride(from: start + 1, through: total, by: 1) {
      decide(app, "triageSkip", expecting: next)
    }
    waitForShownPhotograph(app)
    let lastID = try XCTUnwrap(photographID(app), "The last photograph names no file.")

    element(app, identifier).tap()
    XCTAssertTrue(
      waitFor("exists == false", element(app, "triagePosition"), timeout: 15),
      "Deciding the last photograph did not end the pass.")
    XCTAssertTrue(
      app.navigationBars["Pass finished"].waitForExistence(timeout: 15),
      "A completed pass is not titled 'Pass finished'.")
    XCTAssertEqual(try statValue(app, "picks"), picks)
    XCTAssertEqual(try statValue(app, "dislikes"), 0)
    XCTAssertEqual(try statValue(app, "skipped"), total - start + 1 - picks)

    let fields = try activityFields(app, source: "passSummary", imageID: lastID)
    XCTAssertEqual(fields["completed"], "true", "The completed pass's activity: \(fields).")
    XCTAssertEqual(fields["imageID"], String(lastID), "Not the final photograph: \(fields).")
    XCTAssertEqual(fields["index"], String(total), "Not the final index: \(fields).")
    XCTAssertEqual(fields["folderID"], "1")
    attach(name: "IMGMGR-461-pass-finished-\(identifier)")
  }

  private func launchedCompactGrid(extraArguments: [String] = []) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"] + extraArguments
    app.launch()
    XCTAssertTrue(
      app.buttons["gridPickButton"].waitForExistence(timeout: 30),
      "Action bar (gridPickButton) never appeared — expected the DEBUG fixture composition's "
        + "populated grid, got something else (sign-in screen, blank screen, failed stub).")
    guard rendersCompactShell(app) else {
      throw XCTSkip("Regular width: Triage is Compact-only; the iPad culls in the loupe.")
    }
    return app
  }

  /// The paged fixture shoot is folder 7 (`DebugStubTransport.pagedFolderID`), photographs
  /// 7001…7020 over two pages. The `index` is 3 whatever the photograph — informational only
  /// (`TriageActivity`), so a receiver that used it would land on the wrong photograph.
  private func launchedRegular(continuing imageID: Int) throws -> XCUIApplication {
    let app = XCUIApplication()
    let json = #"{"v":1,"folderID":7,"imageID":\#(imageID),"index":3,"completed":false}"#
    app.launchArguments = ["-UITestStubGrid", "-UITestContinueActivity", json]
    app.launch()
    // No wait on the grid's bar first: the route may already have swapped the grid for the
    // docked loupe by then. The continuation probe is the signal each test waits on.
    if rendersCompactShell(app) {
      throw XCTSkip("Compact width: the receiving route is proven on the iPad destination.")
    }
    return app
  }

  /// This process's identity (`DebugProbe.launchID`), read off the workspace's probe.
  private func launchID(_ app: XCUIApplication) throws -> String {
    let probe = element(app, "debugProbe.launch")
    XCTAssertTrue(probe.waitForExistence(timeout: 10), "No 'debugProbe.launch' on screen.")
    XCTAssertTrue(waitFor("value BEGINSWITH 'launch='", probe), "The launch probe is empty.")
    return try XCTUnwrap(probe.value as? String, "'debugProbe.launch' is unreadable.")
  }

  private func openTriage(_ app: XCUIApplication) {
    // IMGMGR-462: Triage lives in the Compact options row, not the navigation bar — and
    // IMGMGR-509 looks for it there, inside the row's container, not anywhere in the app.
    let entry = gridTriageEntry(app)
    XCTAssertTrue(
      entry.waitForExistence(timeout: 15), "No 'gridTriageButton' in the grid's options row.")
    XCTAssertTrue(waitFor("isEnabled == true", entry), "Triage is disabled on a populated grid.")
    entry.tap()
    XCTAssertTrue(
      element(app, "triagePosition").waitForExistence(timeout: 15), "Triage did not open.")
    waitForShownPhotograph(app)
  }

  /// One decision by its twin, once the cursor's photograph is shown, then the advance.
  private func decide(_ app: XCUIApplication, _ identifier: String, expecting next: Int) {
    waitForShownPhotograph(app)
    element(app, identifier).tap()
    XCTAssertTrue(waitForPosition(app, next), "'\(identifier)' did not advance to \(next).")
  }

  private func waitForShownPhotograph(_ app: XCUIApplication) {
    XCTAssertTrue(
      waitFor("isEnabled == true", element(app, "triageSkip"), timeout: 15),
      "The cursor's photograph was never shown, so no decision became possible.")
    XCTAssertTrue(
      waitFor("value BEGINSWITH 'STUB_'", element(app, "triagePhoto")),
      "The shown photograph names no file.")
  }

  /// The surface's recorded activity as `key=value` fields, once THAT surface recorded one (for
  /// `imageID`, when given). Unreadable or never recorded → the test fails, never compares
  /// empty values.
  private func activityFields(_ app: XCUIApplication, source: String, imageID: Int?) throws
    -> [String: String]
  {
    let probe = element(app, "debugProbe.activity")
    XCTAssertTrue(probe.waitForExistence(timeout: 10), "No 'debugProbe.activity' on screen.")
    var format = "value BEGINSWITH 'source=\(source);'"
    if let imageID { format += " AND value CONTAINS ';imageID=\(imageID);'" }
    XCTAssertTrue(
      waitFor(format, probe, timeout: 15),
      "The \(source) activity was never recorded (image \(String(describing: imageID))): "
        + "\(String(describing: probe.value)).")
    let value = try XCTUnwrap(probe.value as? String, "'debugProbe.activity' is unreadable.")
    var fields: [String: String] = [:]
    for pair in value.split(separator: ";") {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { continue }
      fields[String(parts[0])] = String(parts[1])
    }
    return fields
  }

  private func statValue(_ app: XCUIApplication, _ id: String) throws -> Int {
    let stat = element(app, "passSummary.\(id)")
    XCTAssertTrue(stat.waitForExistence(timeout: 15), "The sheet shows no '\(id)' count.")
    return try XCTUnwrap(
      numbers(in: stat.label).first, "'passSummary.\(id)' is unreadable: '\(stat.label)'.")
  }

  private func continuationProbe(_ app: XCUIApplication) -> XCUIElement {
    element(app, "debugProbe.continuation")
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func waitFor(_ format: String, _ element: XCUIElement, timeout: TimeInterval = 10)
    -> Bool
  {
    waitFor(NSPredicate(format: format), element, timeout: timeout)
  }

  private func waitFor(
    _ predicate: NSPredicate, _ element: XCUIElement, timeout: TimeInterval = 10
  ) -> Bool {
    let done = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [done], timeout: timeout) == .completed
  }

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

  private func attach(name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
