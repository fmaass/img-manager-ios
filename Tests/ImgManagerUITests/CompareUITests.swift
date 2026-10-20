import XCTest

/// WP30 P3 (IMGMGR-458) acceptance: "UI test — three decision verbs only (no Swap), Undo present,
/// scene strip renders as content not glass", plus plan P3's Verification: Keep left writes
/// Pick/Dislike, Undo restores both and the pane pair, and the keyboard is isolated while Compare
/// is open. Compare is an iPad verb: at Compact every test proves `loupeCompareButton` absent.
///
/// The fixture is the Scene-mode stub (`DebugStubTransport`): scene 5000's band is members 3…7
/// then 601…635, so the loupe on member 3 has a scope of 40 and Compare opens on 3 | 4.
final class CompareUITests: OrientationPinnedUITestCase {
  private let leftID = 3
  private let rightID = 4
  private let nextID = 5

  // MARK: - Acceptance: three verbs, no Swap, Undo, content strip

  @MainActor
  func testCompareShowsThreeVerbsNoSwapUndoAndAContentStrip() throws {
    let app = launchIntoTheBand()
    guard !provesCompactAbsence(app) else { return }
    openCompare(app)

    XCTAssertTrue(paneShows(app, "compareLeftPane", leftID), "Left is not the focused image.")
    XCTAssertTrue(paneShows(app, "compareRightPane", rightID), "Right is not the next image.")

    let bar = element(app, "compareDecisionBar")
    XCTAssertTrue(bar.exists, "No decision cluster.")
    let verbs = bar.buttons.allElementsBoundByIndex.map { $0.identifier }
    XCTAssertEqual(
      verbs, ["compareKeepLeft", "compareBoth", "compareKeepRight"],
      "The decision cluster is not exactly Keep left · Both · Keep right.")
    let swap = NSPredicate(format: "label CONTAINS[c] 'swap' OR identifier CONTAINS[c] 'swap'")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(swap).count, 0, "Something is labelled Swap.")

    XCTAssertTrue(app.buttons["compareUndo"].exists, "Compare has no Undo.")
    XCTAssertFalse(bar.buttons["compareUndo"].exists, "Undo sits inside the verbs, not after them.")

    let strip = element(app, "compareStrip")
    XCTAssertTrue(strip.waitForExistence(timeout: 10), "Compare has no scene strip.")
    XCTAssertEqual(strip.value as? String, "content", "The strip does not render as content.")
    let leftThumbnail = app.buttons["compareStripThumbnail-\(leftID)"]
    XCTAssertTrue(leftThumbnail.exists, "The strip has no thumbnail for the left image.")
    XCTAssertFalse(leftThumbnail.isEnabled, "The left image's thumbnail is tappable.")
    XCTAssertTrue(
      app.buttons["compareStripThumbnail-\(rightID)"].isEnabled, "The right thumbnail is inert.")

    let title = element(app, "compareTitle").label
    XCTAssertTrue(title.hasPrefix("Compare · 2 of "), "The title misplaces the pair: '\(title)'.")
    XCTAssertTrue(title.hasSuffix(" in scene"), "The title does not name the scene: '\(title)'.")
    attach(name: "compare-regular")
  }

  // MARK: - Keep left writes Pick | Dislike

  @MainActor
  func testKeepLeftPicksTheLeftAndDislikesTheRight() throws {
    let app = launchIntoTheBand()
    guard !provesCompactAbsence(app) else { return }
    clearTheFocusedMark(app)
    openCompare(app)

    app.buttons["compareKeepLeft"].tap()
    XCTAssertTrue(
      waitForPane(app, "compareRightPane", nextID),
      "Keep left did not advance the right pane to the next unseen candidate.")
    XCTAssertTrue(paneShows(app, "compareLeftPane", leftID), "Keep left moved the left pane.")

    app.buttons["compareBack"].tap()
    let pick = app.buttons["loupePickButton"]
    XCTAssertTrue(pick.waitForExistence(timeout: 10), "Back did not return to the loupe.")
    XCTAssertTrue(waitForValue(pick, "Picked"), "The left image does not read as picked.")
    app.buttons["loupeNext"].tap()
    let dislike = app.buttons["loupeDislikeButton"]
    XCTAssertTrue(waitForValue(dislike, "Disliked"), "The right image does not read as disliked.")
  }

  // MARK: - Undo restores the pair and both marks

  @MainActor
  func testUndoRestoresThePairAndBothMarks() throws {
    let app = launchIntoTheBand()
    guard !provesCompactAbsence(app) else { return }
    clearTheFocusedMark(app)
    openCompare(app)

    app.buttons["compareKeepLeft"].tap()
    XCTAssertTrue(waitForPane(app, "compareRightPane", nextID), "Keep left did not advance.")
    let undo = app.buttons["compareUndo"]
    XCTAssertTrue(undo.isEnabled, "Undo is not live after a verb.")
    undo.tap()
    XCTAssertTrue(
      waitForPane(app, "compareRightPane", rightID), "Undo did not restore the right pane.")
    XCTAssertTrue(paneShows(app, "compareLeftPane", leftID), "Undo did not keep the left pane.")

    app.buttons["compareBack"].tap()
    let pick = app.buttons["loupePickButton"]
    XCTAssertTrue(pick.waitForExistence(timeout: 10), "Back did not return to the loupe.")
    XCTAssertTrue(waitForValue(pick, "Not picked"), "Undo left the left image picked.")
    app.buttons["loupeNext"].tap()
    let dislike = app.buttons["loupeDislikeButton"]
    XCTAssertTrue(waitForValue(dislike, "Not disliked"), "Undo left the right image disliked.")
  }

  // MARK: - Keyboard isolation (plan decision 7)

  @MainActor
  func testKeysDoNothingWhileCompareIsOpenAndWorkAgainAfterBack() throws {
    let app = launchIntoTheBand()
    guard !provesCompactAbsence(app) else { return }
    clearTheFocusedMark(app)
    let pick = app.buttons["loupePickButton"]

    // Positive control FIRST: a key that marks in the loupe. `CompactSelectUITests` records that
    // a key equivalent never reached the app on the iPad simulator once; if bare keys do not
    // reach it either, the negative half below would pass vacuously, so it is not claimed.
    app.typeKey("p", modifierFlags: [])
    guard waitForValue(pick, "Picked", timeout: 5) else {
      throw XCTSkip(
        "Hardware keys do not reach the app on this destination, so isolation cannot be observed "
          + "here; the published-nil rule is CompareSessionTests.keyboardIsolation.")
    }
    // IMGMGR-483 AC1: "Picked" is optimistic; the next tap waits for the write's own completion
    // (the mark controls re-enable only once the mutation lane has released).
    XCTAssertTrue(waitForEnabled(pick), "The mark lane never released after the P control.")
    clearTheFocusedMark(app)
    // IMGMGR-483 AC2: a POSITIVE record that the keys ARRIVED while Compare was open. The gate's
    // simulators deliver no ⌘ key equivalents (IMGMGR-508) and Compare handles no bare key of
    // its own, so the DEBUG probe logs every press the app receives (`DebugKeyReceipt`, at
    // `UIApplication.sendEvent`), stamped `withheld` while Compare withholds the grid's keys.
    let receipts = element(app, "debugProbe.keyReceipts")
    XCTAssertTrue(receipts.waitForExistence(timeout: 10), "The fixture has no key-receipt probe.")
    // Positive control for the hook itself: the P typed above provably reached the app (it
    // marked), so it must have left a `p:grid` receipt. If it did not, simulator key presses do
    // not pass through `UIApplication.sendEvent` on this destination and receipt cannot be
    // observed here; that is a skip with the reason, never a vacuous pass.
    // Only an EMPTY log may skip: any receipt at all proves the hook sees keys here, and then a
    // missing `p:grid` for the P that just marked is a failure, not a destination limit.
    let anyReceipt = NSPredicate(format: "value CONTAINS %@", ":")
    guard
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: anyReceipt, object: receipts)], timeout: 5)
        == .completed
    else {
      throw XCTSkip(
        "The P that marked left no key receipt at all (\(String(describing: receipts.value))): "
          + "key presses bypass UIApplication.sendEvent on this destination, so receipt in "
          + "Compare cannot be observed here.")
    }
    XCTAssertTrue(
      ((receipts.value as? String) ?? "").contains(":p:grid"),
      "The P that marked was not received as p:grid: \(String(describing: receipts.value)).")
    openCompare(app)

    let beforeCompareKeys = receiptCount(receipts)
    app.typeKey("p", modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
    let compareKeys = ["p:withheld", "rightArrow:withheld"]
    XCTAssertTrue(
      waitForFreshReceipts(receipts, after: beforeCompareKeys, compareKeys),
      "P and the arrow were not received while Compare withheld the keys: "
        + "\(String(describing: receipts.value)).")
    // The negative also waits on the condition itself (A3): an inverted expectation that fails
    // the moment P's mark shows on the left thumbnail, instead of a blind sleep.
    let leftThumbnail = app.buttons["compareStripThumbnail-\(leftID)"]
    let marked = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label ENDSWITH %@", ", picked"), object: leftThumbnail)
    marked.isInverted = true
    XCTAssertEqual(
      XCTWaiter.wait(for: [marked], timeout: 2), .completed, "P marked the left image in Compare.")
    XCTAssertTrue(paneShows(app, "compareLeftPane", leftID), "A key moved the left pane.")
    XCTAssertTrue(paneShows(app, "compareRightPane", rightID), "A key moved the right pane.")

    app.buttons["compareBack"].tap()
    XCTAssertTrue(pick.waitForExistence(timeout: 10), "Back did not return to the loupe.")
    XCTAssertTrue(waitForValue(pick, "Not picked"), "The left image changed inside Compare.")
    let beforeBackKey = receiptCount(receipts)
    app.typeKey("p", modifierFlags: [])
    XCTAssertTrue(
      waitForFreshReceipts(receipts, after: beforeBackKey, ["p:grid"]),
      "P after Back was not received with the grid's keys published: "
        + "\(String(describing: receipts.value)).")
    XCTAssertTrue(waitForValue(pick, "Picked"), "P does not mark again after Back.")
  }

  // MARK: - iPhone

  @MainActor
  func testThePhoneHasNoCompare() throws {
    let app = launchIntoTheBand()
    guard rendersCompactShell(app) else {
      XCTAssertTrue(
        element(app, "loupeCompareButton").exists, "The Regular loupe has no Compare control.")
      return
    }
    XCTAssertFalse(
      element(app, "loupeCompareButton").exists, "The phone's loupe carries a Compare control.")
  }

  // MARK: - Shared

  /// At Compact there is no Compare: the proof is the control's absence, and the test ends.
  private func provesCompactAbsence(_ app: XCUIApplication) -> Bool {
    guard rendersCompactShell(app) else { return false }
    XCTAssertFalse(
      element(app, "loupeCompareButton").exists, "The phone's loupe carries a Compare control.")
    return true
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func paneShows(_ app: XCUIApplication, _ identifier: String, _ imageID: Int) -> Bool {
    (element(app, identifier).value as? String) == String(imageID)
  }

  private func waitForPane(_ app: XCUIApplication, _ identifier: String, _ imageID: Int) -> Bool {
    let predicate = NSPredicate(format: "value == %@", String(imageID))
    let expectation = XCTNSPredicateExpectation(
      predicate: predicate, object: element(app, identifier))
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }

  private func waitForValue(_ control: XCUIElement, _ value: String, timeout: TimeInterval = 10)
    -> Bool
  {
    let predicate = NSPredicate(format: "value == %@", value)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: control)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  /// The fixture's member 3 is PICKED; the mark tests start it unmarked, through the loupe's own
  /// Clear, so every verdict they read afterwards was written by the verb under test.
  private func clearTheFocusedMark(_ app: XCUIApplication) {
    let pick = app.buttons["loupePickButton"]
    let clear = app.buttons["loupeClearButton"]
    XCTAssertTrue(clear.waitForExistence(timeout: 10), "The mark group has no Clear.")
    clear.tap()
    XCTAssertTrue(waitForValue(pick, "Not picked"), "Clear did not unmark the focused image.")
    // A3: "Not picked" is optimistic and shows before the mutation lane releases; the mark
    // controls re-enable only once it has, which is what the next step needs.
    XCTAssertTrue(waitForEnabled(pick), "The mark lane never released after Clear.")
  }

  /// How many receipts the key-receipt probe holds (`keyReceipts=1:p:grid; 2:…`).
  private func receiptCount(_ probe: XCUIElement) -> Int {
    let value = (probe.value as? String) ?? ""
    let list = value.hasPrefix("keyReceipts=") ? String(value.dropFirst(12)) : ""
    return list.split(separator: ";").count
  }

  /// Waits until the probe ENDS with exactly `entries`, numbered from `count + 1` — fresh
  /// receipts for these keys, in order, and nothing received after them.
  private func waitForFreshReceipts(_ probe: XCUIElement, after count: Int, _ entries: [String])
    -> Bool
  {
    let numbered = entries.enumerated().map { "\(count + $0.offset + 1):\($0.element)" }
    let tail = (count == 0 ? "keyReceipts=" : "; ") + numbered.joined(separator: "; ")
    let predicate = NSPredicate(format: "value ENDSWITH %@", tail)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: probe)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }

  private func waitForEnabled(_ control: XCUIElement, timeout: TimeInterval = 10) -> Bool {
    let predicate = NSPredicate(format: "isEnabled == true")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: control)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func openCompare(_ app: XCUIApplication) {
    let compare = element(app, "loupeCompareButton")
    XCTAssertTrue(compare.waitForExistence(timeout: 10), "The Regular loupe has no Compare.")
    XCTAssertTrue(compare.isEnabled, "Compare is disabled on a 40-image scene band.")
    compare.tap()
    XCTAssertTrue(
      app.buttons["compareBack"].waitForExistence(timeout: 10), "Compare did not open.")
  }

  /// The Scene fixture, its scene PUSHED (WP442 P12), the loupe opened on the scene's first
  /// member (3) by its own tile — no band handle overlays a member any more.
  private func launchIntoTheBand() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestEnterSceneMode", "-UITestStubNoAutoAdvance"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "The Scene-mode stub grid never rendered its action bar.")
    let handle = element(app, "sceneHandle-5000")
    XCTAssertTrue(handle.waitForExistence(timeout: 15), "The fixture scene's handle is missing.")
    handle.tap()
    XCTAssertTrue(
      element(app, "gridTile-\(leftID)").waitForExistence(timeout: 20),
      "Opening the scene did not put its members on screen.")

    let back = app.buttons["loupeBack"]
    for _ in 0..<3 where !back.exists {
      let tile = element(app, "gridTile-\(leftID)")
      guard tile.exists else { break }
      tile.tap()
      _ = back.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(back.exists, "Tapping gridTile-\(leftID) never opened the loupe.")

    let strip = element(app, "loupeFilmstrip")
    XCTAssertTrue(strip.waitForExistence(timeout: 10), "The member's loupe drew no strip.")
    XCTAssertTrue(
      app.buttons["filmstripThumbnail-\(leftID)"].isSelected,
      "The loupe is not on the band's first member.")
    return app
  }

  private func attach(name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
