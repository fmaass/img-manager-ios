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
    clearTheFocusedMark(app)
    openCompare(app)

    app.typeKey("p", modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
    // A negative has to wait, but on the condition itself (A3): an inverted expectation that
    // fails the moment P's mark shows on the left thumbnail, instead of a blind sleep.
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
    app.typeKey("p", modifierFlags: [])
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

  /// The Scene fixture, its scene open, the loupe on loose photograph 1, advanced into the band
  /// until the strip appears (member 3) — the path `LoupeFilmstripScopeUITests` established.
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
      let tile = element(app, "gridTile-1")
      guard tile.exists else { break }
      tile.tap()
      _ = back.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(back.exists, "Tapping gridTile-1 never opened the loupe.")

    let strip = element(app, "loupeFilmstrip")
    let next = app.buttons["loupeNext"]
    var advances = 0
    while !strip.exists, advances < 5, next.exists {
      next.tap()
      advances += 1
      _ = strip.waitForExistence(timeout: 4)
    }
    XCTAssertTrue(strip.exists, "Advancing never reached the scene's band.")
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
