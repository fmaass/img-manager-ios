import Foundation
import UIKit
import XCTest

/// IMGMGR-552 (R3 P18) on the real surface, both destinations: every way to mark a photograph —
/// E1 the latched Pick, E2 the latched Dislike, E3 Tap to Pick, E4 the quick-pick corner, E5 P/X,
/// E6 Clear — in every grid state — S1 ungrouped, S2 Mark, S3 Rating, S4 Camera, S5 a peek
/// band, S6 a pushed scene, S7 the pushed remainder, S8 Square, S9 the loupe — writes exactly
/// the mark requests it means, read from the fixture transport's append-only log
/// (`debugProbe.markRequests`, `"<state>:<ids>"` per request).
///
/// One method per STATE, so a regression is named by one `-only-testing` id; inside it every
/// entry is its own CELL: it starts from a reset (Done, the loupe and any Arrange closed), takes a
/// fresh baseline of the log, and is reported on its own — every failure message is prefixed
/// `[<state> × <entry>]` (`record(_:)` below), and every cell prints one
/// `LATCH-MATRIX [<state> × <entry>] PASS|FAIL` line, so a red method still shows which of its
/// cells passed. The reset also runs after a failed cell (`defer`), so one red cell cannot
/// cascade into the next.
///
/// The latch rules are the design record's R3-17 (BookStack page 4336): the latch survives
/// scroll, grouping, filter and size changes and a scene round trip; it ends with Done, leaving
/// the folder, or Select. `testLatchSurvives…` and `testFolderGridIsAnException` assert that.
final class LatchMatrixUITests: OrientationPinnedUITestCase {

  private enum Entry: CaseIterable {
    case latchPick, latchDislike, tapToPick, corner, keys, clear

    var title: String {
      switch self {
      case .latchPick: "E1 latch Pick"
      case .latchDislike: "E2 latch Dislike"
      case .tapToPick: "E3 Tap to Pick"
      case .corner: "E4 corner"
      case .keys: "E5 P/X"
      case .clear: "E6 Clear"
      }
    }
  }

  /// The photographs a state's entries aim at: `focus` is focused before a latch press,
  /// `tap` receives the latched tap, `corner` the quick-pick corner, `keys` P/X and Clear.
  private struct Targets {
    let focus: Int
    let tap: Int
    let corner: Int
    let keys: Int
  }

  /// The cell currently running, so every issue it records carries its name.
  private var currentCell: String?

  override func setUp() {
    super.setUp()
    continueAfterFailure = true
  }

  override func record(_ issue: XCTIssue) {
    var issue = issue
    if let cell = currentCell {
      issue.compactDescription = "[\(cell)] \(issue.compactDescription)"
    }
    super.record(issue)
  }

  // MARK: - S1–S8: the grid states

  func testS1UngroupedEveryEntryWritesItsOwnRequests() throws {
    let app = launched()
    establishJustified(app)
    runEntries(app, "S1 ungrouped", Targets(focus: 3, tap: 2, corner: 4, keys: 3))
  }

  func testS2MarkGroupsEveryEntryWritesItsOwnRequests() throws {
    let app = launched(["-UITestMarkGroups"])
    establishJustified(app)
    arrange(app, ["arrange.group.mark", "arrange.size.260"])
    XCTAssertTrue(element(app, "groupRemainderRow").waitForExistence(timeout: 15), "Not Mark.")
    runEntries(app, "S2 Mark", Targets(focus: 9002, tap: 9003, corner: 9001, keys: 9004))
  }

  func testS3RatingGroupsEveryEntryWritesItsOwnRequests() throws {
    let app = launched(["-UITestMarkGroups"])
    establishJustified(app)
    arrange(app, ["arrange.group.rating", "arrange.size.260"])
    XCTAssertTrue(element(app, "groupRemainderRow").waitForExistence(timeout: 15), "Not Rating.")
    runEntries(app, "S3 Rating", Targets(focus: 9002, tap: 9003, corner: 9001, keys: 9004))
  }

  func testS4CameraGroupsEveryEntryWritesItsOwnRequests() throws {
    let app = launched()
    establishJustified(app)
    arrange(app, ["arrange.group.camera", "arrange.size.260"])
    runEntries(app, "S4 Camera", Targets(focus: 3, tap: 2, corner: 4, keys: 3))
  }

  func testS5PeekBandEveryEntryWritesItsOwnRequests() throws {
    let app = launched(["-UITestEnterSceneMode", "-UITestPeekBands"])
    establishJustified(app)
    arrange(app, ["arrange.size.260"])
    let chevron = element(app, "sceneHandle-7001")
    XCTAssertTrue(scrollUntilHittable(app, chevron), "No chevron on card 7001.")
    chevron.tap()
    waitFor(app, "sceneHandle-7001", "value == %@", "open", "the band of 7001")
    runEntries(app, "S5 band", Targets(focus: 700102, tap: 700103, corner: 700101, keys: 700104))
  }

  func testS6PushedSceneEveryEntryWritesItsOwnRequests() throws {
    let app = launched(["-UITestEnterSceneMode"])
    establishJustified(app)
    arrange(app, ["arrange.size.260"])
    pushScene(app, 5000)
    waitFor(app, "debugProbe.scope", "value == %@", "instance=scene-5000;entered=5000", "push")
    runEntries(app, "S6 drilled scene", Targets(focus: 6, tap: 7, corner: 4, keys: 6))
  }

  func testS7PushedRemainderEveryEntryWritesItsOwnRequests() throws {
    let app = launched(["-UITestMarkGroups"])
    establishJustified(app)
    arrange(app, ["arrange.group.mark", "arrange.size.260"])
    // Tapped as `MarkGroupsUITests` does: the tap brings the row into view itself (a swipe
    // toward it timed the UI query out on the iPhone, run 230331).
    let row = element(app, "groupRemainderRow")
    XCTAssertTrue(row.waitForExistence(timeout: 15), "No remainder row under Mark.")
    row.tap()
    waitFor(
      app, "debugProbe.scope", "value == %@", "instance=remainder-mark;entered=remainder-mark",
      "the remainder push")
    runEntries(
      app, "S7 drilled remainder", Targets(focus: 9009, tap: 9010, corner: 9008, keys: 9011))
  }

  func testS8SquareEveryEntryWritesItsOwnRequests() throws {
    let app = launched()
    arrange(app, ["arrange.layout.square", "arrange.size.120"])
    let chrome = element(app, "debugProbe.gridChrome")
    XCTAssertTrue(
      waitForValue(chrome) { $0.hasSuffix(";layout=square") }.hasSuffix(";layout=square"),
      "Square is not in force.")
    runEntries(app, "S8 square", Targets(focus: 3, tap: 2, corner: 4, keys: 3))
  }

  // MARK: - S9: the loupe

  /// The loupe's own latch entry is its Lock rows (the bar's buttons never latch there); Tap to
  /// Pick and the corner are not on this surface at all, which is asserted, not assumed.
  func testS9LoupeEveryEntryWritesItsOwnRequestsOrIsAbsent() throws {
    let app = launched(["-UITestStubNoAutoAdvance"])
    establishJustified(app)
    let state = "S9 loupe"
    let frame = 2
    let back = app.buttons["loupeBack"]
    for verb in ["pick", "dislike"] {
      let entry = verb == "pick" ? Entry.latchPick : Entry.latchDislike
      cell("\(state) × \(entry.title)", app) {
        let row = "loupeMore.lock\(verb == "pick" ? "Pick" : "Dislike")"
        let caption = app.staticTexts["lockModeCaption"]
        // Setup: the Lock row, measured on its own. The log is drawn by the grid only, so the
        // delta is read after Back.
        let setupBaseline = log(app).count
        openLoupe(app, on: frame)
        openLoupeMore(app, revealing: row)
        element(app, row).tap()
        dismissLoupeMenu(app)
        back.tap()
        expectDelta(app, since: setupBaseline, [], "the loupe's Lock row")
        XCTAssertTrue(caption.waitForExistence(timeout: 10), "The Lock row did not latch the grid.")
        if caption.exists {
          XCTAssertTrue(
            caption.label.hasPrefix(verb == "pick" ? "Pick Lock" : "Dislike Lock"),
            "The lock row reads '\(caption.label)'.")
        }
        // Action: the loupe's verb button, on a fresh baseline. The loupe reopens with Space on
        // the focus, because a tile tap is now the latched tap and would write by itself.
        waitFor(
          app, "debugProbe.focus", "value ENDSWITH %@", "focusedImageID=\(frame)",
          "the focus after Back")
        let actionBaseline = log(app).count
        reopenLoupeWithSpace(app, on: frame)
        let button = app.buttons["loupe\(verb == "pick" ? "Pick" : "Dislike")Button"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "No loupe \(verb) control.")
        button.tap()
        back.tap()
        expectDelta(app, since: actionBaseline, ["\(verb):\(frame)"], "the loupe's \(verb) button")
        XCTAssertTrue(caption.waitForExistence(timeout: 10), "The loupe's \(verb) ended the latch.")
        let afterBack = log(app).count
        tapTile(app, 3)
        expectDelta(app, since: afterBack, ["\(verb):3"], "the latched tap after Back")
      }
    }
    cell("\(state) × \(Entry.tapToPick.title) (N/A)", app) {
      let baseline = log(app).count
      openLoupe(app, on: frame)
      let toggle = app.buttons["gridTapToPickToggle"]
      XCTAssertFalse(toggle.exists && toggle.isHittable, "Tap to Pick is reachable in the loupe.")
      back.tap()
      expectDelta(app, since: baseline, [], "nothing in the loupe")
    }
    cell("\(state) × \(Entry.corner.title) (N/A)", app) {
      let baseline = log(app).count
      openLoupe(app, on: frame)
      let corners = app.descendants(matching: .any).matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "tileMarkCorner-"))
      let reachable = (0..<min(corners.count, 40)).filter {
        corners.element(boundBy: $0).isHittable
      }
      XCTAssertTrue(reachable.isEmpty, "\(reachable.count) corner(s) are reachable in the loupe.")
      back.tap()
      expectDelta(app, since: baseline, [], "nothing in the loupe")
    }
    cell("\(state) × \(Entry.keys.title)", app) {
      for (key, verb) in [("p", "pick"), ("x", "dislike")] {
        let baseline = log(app).count
        // A press can precede key registration: pressed again only while nothing was written.
        for _ in 0..<3 where log(app).count == baseline {
          openLoupe(app, on: frame)
          app.typeKey(key, modifierFlags: [])
          Thread.sleep(forTimeInterval: 1)
          back.tap()
          _ = back.waitForNonExistence(timeout: 5)
          _ = waitForLog(app, atLeast: baseline + 1, timeout: 3)
        }
        expectDelta(app, since: baseline, ["\(verb):\(frame)"], "\(key) in the loupe")
      }
    }
    cell("\(state) × \(Entry.clear.title)", app) {
      let baseline = log(app).count
      openLoupe(app, on: frame)
      let clear = app.buttons["loupeClearButton"]
      XCTAssertTrue(clear.waitForExistence(timeout: 10), "No loupe Clear.")
      clear.tap()
      back.tap()
      expectDelta(app, since: baseline, ["none:\(frame)"], "the loupe's Clear")
    }
  }

  // MARK: - Exceptions

  /// Compare (iPad) is not the latch's surface: under a Dislike latch, P and X are withheld and
  /// Keep left writes Compare's own pair, never the latched verb; the latch is still on after.
  func testCompareIsAnException() throws {
    let app = launched(["-UITestEnterSceneMode", "-UITestStubNoAutoAdvance"])
    pushScene(app, 5000)
    XCTAssertTrue(element(app, "gridTile-3").waitForExistence(timeout: 20), "No member 3.")
    // The log is read on the grid, before the loupe covers it and after Back.
    let baseline = log(app).count
    openLoupe(app, on: 3)
    if rendersCompactShell(app) {
      XCTAssertFalse(element(app, "loupeCompareButton").exists, "The phone has Compare.")
      return
    }
    openLoupeMore(app, revealing: "loupeMore.lockDislike")
    element(app, "loupeMore.lockDislike").tap()
    dismissLoupeMenu(app)
    let compare = element(app, "loupeCompareButton")
    XCTAssertTrue(compare.waitForExistence(timeout: 10), "The Regular loupe has no Compare.")
    compare.tap()
    XCTAssertTrue(app.buttons["compareBack"].waitForExistence(timeout: 10), "No Compare.")
    let caption = app.staticTexts["lockModeCaption"]
    XCTAssertFalse(caption.exists && caption.isHittable, "The lock row shows inside Compare.")
    app.typeKey("p", modifierFlags: [])
    app.typeKey("x", modifierFlags: [])
    Thread.sleep(forTimeInterval: 1)
    app.buttons["compareKeepLeft"].tap()
    Thread.sleep(forTimeInterval: 1)
    app.buttons["compareBack"].tap()
    app.buttons["loupeBack"].tap()
    // P and X wrote nothing: the delta is Keep left's own pair and nothing else.
    expectDelta(app, since: baseline, ["pick:3", "dislike:4"], "Compare: Keep left only")
    XCTAssertTrue(caption.waitForExistence(timeout: 10), "Compare consumed the Dislike latch.")
    if caption.exists {
      XCTAssertTrue(caption.label.hasPrefix("Dislike Lock"), "The lock row: '\(caption.label)'.")
    }
    // The receipts are stamped at the press (`DebugKeyReceipt`), so they are read here on the
    // grid, as LooksStripUITests reads them after Back. CompareUITests' rule: only an EMPTY log
    // skips (the gate's simulators can withhold hardware keys, IMGMGR-508); any receipt at all
    // proves keys arrive here, and then P must have arrived withheld.
    let receipts = element(app, "debugProbe.keyReceipts")
    _ = receipts.waitForExistence(timeout: 10)
    let value = (receipts.value as? String) ?? ""
    guard value.contains(":") else {
      throw XCTSkip(
        "No key reached the app in Compare (\(value)), so withholding cannot be observed here; "
          + "the published-nil rule is CompareSessionTests.keyboardIsolation.")
    }
    XCTAssertTrue(
      value.contains(":p:withheld") && value.contains(":x:withheld"),
      "P and X were not received-and-withheld in Compare: \(value).")
  }

  /// The Untouched "N more ›" grid of FOLDER tiles is not a mark surface: no lock row there, a
  /// tile tap opens the folder and writes nothing, and leaving the latched folder ended the
  /// latch. "Start with Tap to Pick" is turned OFF explicitly, so the folder change cannot latch
  /// Pick afresh (IMGMGR-548) and hide the exit.
  func testFolderGridIsAnException() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-UITestStubGrid", "-UITestStubSkipAutoSelect", "-UITestManyUntouched",
      "-UITestPerFolderGrid", "-culling.tapToPickDefault", "NO",
    ]
    app.launch()
    let row = element(app, "untouchedRow-23")
    XCTAssertTrue(row.waitForExistence(timeout: 30), "No Untouched row for folder 23.")
    row.tap()
    XCTAssertTrue(element(app, "gridTile-23001").waitForExistence(timeout: 30), "No grid of 23.")
    let toggle = app.buttons["gridTapToPickToggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10), "No Tap to Pick toggle.")
    toggle.tap()
    let caption = app.staticTexts["lockModeCaption"]
    XCTAssertTrue(caption.waitForExistence(timeout: 10), "Tap to Pick did not latch.")
    let baseline = log(app).count

    if rendersCompactShell(app) {
      let back = app.navigationBars.buttons.firstMatch
      if back.waitForExistence(timeout: 10), back.isHittable { back.tap() }
    }
    let more = element(app, "untouchedMore")
    XCTAssertTrue(more.waitForExistence(timeout: 20), "No \"N more ›\" row on the home.")
    let sheet = element(app, "untouchedAllSheet")
    XCTAssertTrue(openPresentation(more, revealing: sheet, timeout: 20), "No folder grid.")
    XCTAssertFalse(
      sheet.descendants(matching: .any)["lockModeCaption"].exists, "A lock row in the sheet.")
    // The overflow grid's own scroll view, swiped upward only (`UntouchedSectionUITests`).
    let tile = element(app, "untouchedTile-31")
    let scroller = app.scrollViews.containing(
      NSPredicate(format: "identifier BEGINSWITH %@", "untouchedTile-")
    ).firstMatch
    for _ in 0..<6 where !(tile.exists && tile.isHittable) { scroller.swipeUp() }
    XCTAssertTrue(tile.exists && tile.isHittable, "Folder tile 31 is never hittable.")
    tile.tap()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 15), "The folder tile did not open.")
    XCTAssertTrue(element(app, "gridTile-31001").waitForExistence(timeout: 30), "No grid of 31.")
    expectDelta(app, since: baseline, [], "the folder tile tap")
    XCTAssertTrue(caption.waitForNonExistence(timeout: 10), "Leaving the folder kept the latch.")
    let focusBaseline = log(app).count
    focus(app, 31001)
    expectDelta(app, since: focusBaseline, [], "an unlatched tap in the new folder")
  }

  // MARK: - R3-17: what the latch survives

  /// Scroll, grouping, a push into the remainder and Back, filter, size and layout: after each,
  /// the lock row is still up and one latched tap writes exactly one request.
  func testLatchSurvivesScrollGroupPushBackFilterSizeAndLayout() throws {
    let app = launched(["-UITestMarkGroups"])
    establishJustified(app)
    let toggle = app.buttons["gridTapToPickToggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10), "No Tap to Pick toggle.")
    toggle.tap()
    assertLatchedTap(app, after: "Tap to Pick", on: 9001)

    app.swipeUp()
    app.swipeUp()
    assertLatchedTap(app, after: "a scroll", on: 9002)
    arrange(app, ["arrange.group.mark"])
    assertLatchedTap(app, after: "grouping by Mark", on: 9003)
    // Tapped as `MarkGroupsUITests` does: the tap brings the row into view itself (a swipe
    // toward it timed the UI query out on the iPhone, run 230331).
    let row = element(app, "groupRemainderRow")
    XCTAssertTrue(row.waitForExistence(timeout: 15), "No remainder row under Mark.")
    row.tap()
    waitFor(
      app, "debugProbe.scope", "value == %@", "instance=remainder-mark;entered=remainder-mark",
      "the remainder push")
    assertLatchedTap(app, after: "the push into the remainder", on: 9008)
    goBack(app)
    waitFor(app, "debugProbe.scope", "value == %@", "instance=stream;entered=none", "Back")
    assertLatchedTap(app, after: "Back", on: 9004)
    arrange(app, ["arrange.group.rating"])
    assertLatchedTap(app, after: "grouping by Rating", on: 9005)
    arrange(app, ["arrange.group.none"])
    let unmarked = element(app, "filterPopoverRow-mark-none")
    XCTAssertTrue(
      openPresentation(element(app, "gridFilterControl"), revealing: unmarked, timeout: 10),
      "The filter popover has no Unmarked row.")
    unmarked.tap()
    dismissFilter(app)
    assertLatchedTap(app, after: "a filter change", on: 9009)
    arrange(app, ["arrange.size.260"])
    assertLatchedTap(app, after: "a size change", on: 9010)
    arrange(app, ["arrange.layout.square"])
    assertLatchedTap(app, after: "the Square layout", on: 9011)
  }

  /// R1 (IMGMGR-552): Scene → Flat → Scene is a scene round trip and keeps the latch; a latched
  /// card tap pushes and writes nothing; Select and Done still end the latch.
  func testLatchSurvivesASceneRoundTripAndEndsWithSelectOrDone() throws {
    let app = launched(["-UITestEnterSceneMode"])
    let toggle = app.buttons["gridTapToPickToggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10), "No Tap to Pick toggle.")
    toggle.tap()
    let caption = app.staticTexts["lockModeCaption"]
    XCTAssertTrue(caption.waitForExistence(timeout: 10), "Tap to Pick did not latch.")

    let cardBaseline = log(app).count
    pushScene(app, 5000)
    waitFor(app, "debugProbe.scope", "value == %@", "instance=scene-5000;entered=5000", "push")
    expectDelta(app, since: cardBaseline, [], "a latched card tap")
    goBack(app)
    waitFor(app, "debugProbe.scope", "value == %@", "instance=stream;entered=none", "Back")

    arrange(app, ["arrange.group.none"])
    XCTAssertTrue(element(app, "gridTile-4").waitForExistence(timeout: 20), "Flat never drew 4.")
    assertLatchedTap(app, after: "Scene → Flat", on: 4)
    arrange(app, ["arrange.group.scene"])
    XCTAssertTrue(
      element(app, "sceneHandle-5000").waitForExistence(timeout: 20), "Scene did not return.")
    assertLatchedTap(app, after: "Flat → Scene", on: 2)

    // Select ends it: a long press on a photograph.
    element(app, "gridTile-1").press(forDuration: 1.0)
    XCTAssertTrue(
      app.staticTexts["selectModeCaption"].waitForExistence(timeout: 10), "No Select.")
    XCTAssertFalse(caption.exists, "Select kept the latch.")
    let selectDone = element(app, "selectModeDone")
    if selectDone.exists { selectDone.tap() }
    // Done ends it.
    toggle.tap()
    XCTAssertTrue(caption.waitForExistence(timeout: 10), "Tap to Pick did not latch again.")
    element(app, "lockModeDone").tap()
    XCTAssertTrue(caption.waitForNonExistence(timeout: 10), "Done kept the latch.")
  }

  // MARK: - The cells

  private func runEntries(_ app: XCUIApplication, _ state: String, _ targets: Targets) {
    for entry in Entry.allCases {
      cell("\(state) × \(entry.title)", app) { drive(entry, app, targets) }
    }
  }

  /// One cell: reset, run, clean up, report. The failure count is sampled before the setup, so
  /// a setup that fails (a reset that leaves the latch on or a presentation open) fails its cell
  /// rather than printing PASS. The cleanup runs after the body whatever it recorded, is itself
  /// checked (latch off, nothing presented, back on the scope the cell began on), and the
  /// PASS/FAIL line is printed only after it, so a stranded state fails its cell.
  private func cell(_ name: String, _ app: XCUIApplication, _ body: () -> Void) {
    let failuresBefore = testRun?.totalFailureCount ?? 0
    currentCell = "\(name) · setup"
    reset(app)
    assertClean(app, scope: nil)
    let scope = scopeValue(app)
    currentCell = name
    defer {
      currentCell = "\(name) · cleanup"
      reset(app)
      assertClean(app, scope: scope)
      let failed = (testRun?.totalFailureCount ?? 0) > failuresBefore
      print("LATCH-MATRIX [\(name)] \(failed ? "FAIL" : "PASS")")
      currentCell = nil
    }
    body()
  }

  /// Compare and the loupe closed, any stranded menu or popover dismissed, Arrange closed, the
  /// latch off. Focus is set by each cell itself.
  private func reset(_ app: XCUIApplication) {
    dismissStrandedPresentations(app)
    let compareBack = app.buttons["compareBack"]
    if compareBack.exists, compareBack.isHittable {
      compareBack.tap()
      _ = compareBack.waitForNonExistence(timeout: 5)
    }
    dismissStrandedPresentations(app)
    let back = app.buttons["loupeBack"]
    if back.exists, back.isHittable {
      back.tap()
      _ = back.waitForNonExistence(timeout: 5)
    }
    let arrangeDone = element(app, "arrangeDone")
    if arrangeDone.exists, arrangeDone.isHittable {
      arrangeDone.tap()
      _ = arrangeDone.waitForNonExistence(timeout: 5)
    }
    dismissStrandedPresentations(app)
    let done = element(app, "lockModeDone")
    if done.exists, done.isHittable {
      done.tap()
      _ = app.staticTexts["lockModeCaption"].waitForNonExistence(timeout: 5)
    }
  }

  /// A row of a menu or popover the matrix opens (the loupe's More, the filter, Arrange) or an
  /// iPad popover's own dismiss region; or, on the grid, an action bar something covers.
  private func strandedPresentation(_ app: XCUIApplication) -> String? {
    if app.buttons["PopoverDismissRegion"].exists { return "PopoverDismissRegion" }
    let prefixes = ["loupeMore.", "filterPopoverRow-", "arrange."]
    let subpredicates = prefixes.map { NSPredicate(format: "identifier BEGINSWITH %@", $0) }
    let rows = app.descendants(matching: .any).matching(
      NSCompoundPredicate(orPredicateWithSubpredicates: subpredicates))
    if rows.firstMatch.exists { return rows.firstMatch.identifier }
    let onGrid = !app.buttons["loupeBack"].exists && !app.buttons["compareBack"].exists
    let bar = app.buttons["gridDislikeButton"]
    if onGrid, bar.exists, !bar.isHittable { return "a cover over the action bar" }
    return nil
  }

  private func dismissStrandedPresentations(_ app: XCUIApplication) {
    for _ in 0..<3 {
      guard strandedPresentation(app) != nil else { return }
      let region = app.buttons["PopoverDismissRegion"]
      if region.exists, region.isHittable {
        region.tap()
      } else if app.buttons["loupeBack"].exists {
        dismissLoupeMenu(app)
      } else {
        // Outside any menu: the tap only dismisses what is presented.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
      }
      Thread.sleep(forTimeInterval: 0.75)
    }
  }

  /// The cleanup's own check: latch off, nothing presented, the grid on top with its action bar
  /// reachable, and (after the body) the scope the cell began on.
  private func assertClean(_ app: XCUIApplication, scope: String?) {
    XCTAssertFalse(app.staticTexts["lockModeCaption"].exists, "Cleanup left the latch on.")
    XCTAssertNil(strandedPresentation(app), "Cleanup left a presentation up.")
    XCTAssertFalse(
      app.buttons["loupeBack"].exists || app.buttons["compareBack"].exists,
      "Cleanup left the loupe or Compare open.")
    XCTAssertTrue(
      app.buttons["gridDislikeButton"].waitForExistence(timeout: 5), "Cleanup left no grid bar.")
    if let scope {
      XCTAssertEqual(scopeValue(app), scope, "Cleanup did not return to the cell's scope.")
    }
  }

  private func scopeValue(_ app: XCUIApplication) -> String {
    let probe = element(app, "debugProbe.scope")
    return probe.exists ? (probe.value as? String ?? "") : "<absent>"
  }

  /// Space opens the loupe on the focus (`GridStore.handleOpenShortcut`), re-pressed while the
  /// loupe has not appeared (the gate's simulators can drop a press, IMGMGR-508).
  private func reopenLoupeWithSpace(_ app: XCUIApplication, on id: Int) {
    let close = app.buttons["loupeBack"]
    for _ in 0..<3 where !close.exists {
      app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [])
      _ = close.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(close.exists, "Space never reopened the loupe on \(id).")
  }

  private func drive(_ entry: Entry, _ app: XCUIApplication, _ targets: Targets) {
    let caption = app.staticTexts["lockModeCaption"]
    switch entry {
    case .latchPick, .latchDislike:
      let verb = entry == .latchPick ? "pick" : "dislike"
      focus(app, targets.focus)
      var baseline = log(app).count
      let button = app.buttons[verb == "pick" ? "gridPickButton" : "gridDislikeButton"]
      XCTAssertTrue(button.waitForExistence(timeout: 10), "No bar \(verb) control.")
      button.doubleTap()
      XCTAssertTrue(caption.waitForExistence(timeout: 10), "The double press did not latch.")
      if caption.exists {
        XCTAssertTrue(
          caption.label.hasPrefix(verb == "pick" ? "Pick Lock" : "Dislike Lock"),
          "The lock row reads '\(caption.label)'.")
      }
      // Setup: the first press of the pair applied the verb to the focus.
      expectDelta(app, since: baseline, ["\(verb):\(targets.focus)"], "setup: the double press")
      baseline = log(app).count
      tapTile(app, targets.tap)
      expectDelta(app, since: baseline, ["\(verb):\(targets.tap)"], "the latched tap")
      XCTAssertFalse(app.buttons["loupeBack"].exists, "A latched tap opened the loupe.")

    case .tapToPick:
      let toggle = app.buttons["gridTapToPickToggle"]
      XCTAssertTrue(toggle.waitForExistence(timeout: 10), "No Tap to Pick toggle.")
      let baseline = log(app).count
      toggle.tap()
      XCTAssertTrue(caption.waitForExistence(timeout: 10), "Tap to Pick did not latch.")
      tapTile(app, targets.tap)
      expectDelta(app, since: baseline, ["pick:\(targets.tap)"], "toggle, then the latched tap")
      XCTAssertFalse(app.buttons["loupeBack"].exists, "A latched tap opened the loupe.")
      toggle.tap()
      XCTAssertTrue(caption.waitForNonExistence(timeout: 10), "The second press did not exit.")

    case .corner:
      let corner = element(app, "tileMarkCorner-\(targets.corner)")
      XCTAssertTrue(scrollUntilHittable(app, corner), "Photograph \(targets.corner) has no corner.")
      let mark = String(((corner.value as? String) ?? "").split(separator: ",").first ?? "")
      let verb = mark.trimmingCharacters(in: .whitespaces) == "Picked" ? "none" : "pick"
      let baseline = log(app).count
      corner.tap()
      expectDelta(app, since: baseline, ["\(verb):\(targets.corner)"], "the corner one-shot")
      XCTAssertFalse(app.buttons["loupeBack"].exists, "The corner opened the loupe.")
      XCTAssertFalse(caption.exists, "The corner latched.")

    case .keys:
      focus(app, targets.keys)
      for (key, verb) in [("p", "pick"), ("x", "dislike")] {
        let baseline = log(app).count
        // A press can precede key registration: pressed again only while nothing was written.
        for _ in 0..<3 where log(app).count == baseline {
          app.typeKey(key, modifierFlags: [])
          _ = waitForLog(app, atLeast: baseline + 1, timeout: 3)
        }
        expectDelta(app, since: baseline, ["\(verb):\(targets.keys)"], "\(key) on the focus")
      }
      XCTAssertFalse(caption.exists, "A key latched.")

    case .clear:
      focus(app, targets.keys)
      let baseline = log(app).count
      let clear = element(app, "gridClearButton")
      if !(clear.exists && clear.isHittable) {
        XCTAssertTrue(openMoreMenu(in: app, revealing: clear, timeout: 10), "No Clear in More.")
      }
      clear.tap()
      expectDelta(app, since: baseline, ["none:\(targets.keys)"], "Clear on the focus")
    }
  }

  private func assertLatchedTap(_ app: XCUIApplication, after what: String, on id: Int) {
    let caption = app.staticTexts["lockModeCaption"]
    XCTAssertTrue(caption.waitForExistence(timeout: 10), "\(what) ended the latch.")
    if caption.exists {
      XCTAssertTrue(caption.label.hasPrefix("Pick Lock"), "After \(what): '\(caption.label)'.")
    }
    let baseline = log(app).count
    tapTile(app, id)
    expectDelta(app, since: baseline, ["pick:\(id)"], "one latched tap after \(what)")
  }

  // MARK: - The request log

  /// The probe is drawn by the active GRID only: read where no loupe or Compare covers it.
  private func log(_ app: XCUIApplication) -> [String] {
    let probe = element(app, "debugProbe.markRequests")
    guard probe.waitForExistence(timeout: 10) else {
      XCTFail("The request log is not on screen (read under the loupe?).")
      return []
    }
    let value = (probe.value as? String) ?? ""
    let entries = value.replacingOccurrences(of: "markRequests=", with: "")
    return entries.isEmpty ? [] : entries.components(separatedBy: "|")
  }

  @discardableResult
  private func waitForLog(_ app: XCUIApplication, atLeast count: Int, timeout: TimeInterval)
    -> Int
  {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while log(app).count < count && Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
    return log(app).count
  }

  /// Exactly `expected` was appended since `baseline`: waits for it, then re-reads after a 1 s
  /// settle so a second write still in flight is seen rather than missed.
  private func expectDelta(
    _ app: XCUIApplication, since baseline: Int, _ expected: [String], _ what: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    waitForLog(app, atLeast: baseline + expected.count, timeout: 15)
    Thread.sleep(forTimeInterval: 1)
    let delta = Array(log(app).dropFirst(baseline))
    XCTAssertEqual(
      delta, expected, "\(what): the request log added \(delta)", file: file, line: line)
  }

  // MARK: - Driving

  private func launched(_ extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"] + extra
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s.")
    return app
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  private func waitForValue(
    _ element: XCUIElement, timeout: TimeInterval = 10, _ predicate: (String) -> Bool
  ) -> String {
    let deadline = Date(timeIntervalSinceNow: timeout)
    var value = (element.value as? String) ?? ""
    while !predicate(value) && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.25)
      value = (element.value as? String) ?? ""
    }
    return value
  }

  private func waitFor(
    _ app: XCUIApplication, _ identifier: String, _ format: String, _ argument: String,
    _ what: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let target = element(app, identifier)
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: format, argument), object: target)
    XCTAssertEqual(
      XCTWaiter().wait(for: [expectation], timeout: 15), .completed,
      "\(what): \(identifier) reads '\(String(describing: target.value))'.", file: file,
      line: line)
  }

  /// A1: every non-square state starts in the justified layout, established, not assumed.
  private func establishJustified(_ app: XCUIApplication) {
    let chrome = element(app, "debugProbe.gridChrome")
    if !waitForValue(chrome, timeout: 5, { $0.hasSuffix(";layout=justified") })
      .hasSuffix(";layout=justified")
    {
      arrange(app, ["arrange.layout.justified"])
    }
    XCTAssertTrue(
      waitForValue(chrome) { $0.hasSuffix(";layout=justified") }.hasSuffix(";layout=justified"),
      "The grid is not in the justified layout: \(String(describing: chrome.value)).")
  }

  /// Arrange › each row in turn › Done, through the shared opener and reveal.
  private func arrange(_ app: XCUIApplication, _ rows: [String]) {
    let control = element(app, "gridArrangeControl")
    XCTAssertTrue(control.waitForExistence(timeout: 10), "No 'gridArrangeControl'.")
    XCTAssertTrue(
      openPresentation(control, revealing: element(app, rows[0]), timeout: 10),
      "Arrange did not offer '\(rows[0])'.")
    for identifier in rows {
      let row = element(app, identifier)
      XCTAssertTrue(revealInArrange(row, in: app), "'\(identifier)' is not reachable.")
      row.tap()
    }
    let done = element(app, "arrangeDone")
    XCTAssertTrue(revealInArrange(done, in: app), "Arrange's Done is not reachable.")
    done.tap()
    XCTAssertTrue(done.waitForNonExistence(timeout: 10), "Done did not close Arrange.")
  }

  /// The filter popover closes on the row's own tap (`FilterPopoverUITests`).
  private func dismissFilter(_ app: XCUIApplication) {
    XCTAssertTrue(
      element(app, "filterPopoverRow-mark-none").waitForNonExistence(timeout: 10),
      "The filter popover did not close on its row's tap.")
  }

  private func scrollUntilHittable(_ app: XCUIApplication, _ target: XCUIElement) -> Bool {
    if target.waitForExistence(timeout: 5), target.isHittable { return true }
    for _ in 0..<6 where !(target.exists && target.isHittable) { app.swipeUp(velocity: .slow) }
    for _ in 0..<12 where !(target.exists && target.isHittable) {
      app.swipeDown(velocity: .slow)
    }
    return target.exists && target.isHittable
  }

  private func tapTile(_ app: XCUIApplication, _ id: Int) {
    let tile = element(app, "gridTile-\(id)")
    XCTAssertTrue(scrollUntilHittable(app, tile), "gridTile-\(id) is not on screen.")
    tile.tap()
  }

  /// A browse tap moves the focus; a loupe that opened instead (the tile was focused) is closed.
  private func focus(_ app: XCUIApplication, _ id: Int) {
    tapTile(app, id)
    let close = app.buttons["loupeBack"]
    if close.waitForExistence(timeout: 1) { close.tap() }
    waitFor(app, "debugProbe.focus", "value ENDSWITH %@", "focusedImageID=\(id)", "focus \(id)")
  }

  private func openLoupe(_ app: XCUIApplication, on id: Int) {
    let close = app.buttons["loupeBack"]
    for _ in 0..<3 where !close.exists {
      tapTile(app, id)
      _ = close.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(close.exists, "Tapping gridTile-\(id) never opened the loupe.")
  }

  private func openLoupeMore(_ app: XCUIApplication, revealing identifier: String) {
    let more = element(app, "loupeMoreMenu")
    XCTAssertTrue(more.waitForExistence(timeout: 10), "The loupe's bar has no More.")
    XCTAssertTrue(
      openPresentation(more, revealing: element(app, identifier), timeout: 15),
      "More did not open with its `\(identifier)` row.")
  }

  /// A tap on an empty stretch of the photograph (a single tap there does nothing of its own).
  private func dismissLoupeMenu(_ app: XCUIApplication) {
    let back = app.buttons["loupeBack"]
    if back.isHittable { return }
    element(app, "loupeImage").coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.9)).tap()
    let hittable = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isHittable == true"), object: back)
    _ = XCTWaiter().wait(for: [hittable], timeout: 10)
  }

  private func goBack(_ app: XCUIApplication) {
    let regularBack = app.buttons["sceneBackButton"]
    if regularBack.exists {
      regularBack.tap()
    } else {
      app.navigationBars.buttons.element(boundBy: 0).tap()
    }
  }
}
