import Foundation
import UIKit
import XCTest

/// IMGMGR-542 (R3-22): the chevron on a scene card opens that scene's photographs as their own
/// rows directly under the card's row — a peek band — without pushing the scene.
///
/// Fixture (`-UITestStubGrid -UITestEnterSceneMode -UITestPeekBands`, `DebugPeekBandsFixture`):
/// loose 7101, scene 7001, loose 7102, scene 7002, loose 7103, 7104, scene 7003, loose 7105,
/// scenes 7004 and 7005, loose 7106, scene 7006, loose 7107, 7108. Scenes 7001…7006 hold 7, 12,
/// 18, 25, 33 and 40 members; scene S's members are S×100+1…S×100+n (7001 → 700101…700107).
///
/// `debugProbe.frames` ends in `bands=<open band ids in opening order>`; `debugProbe.scroll`
/// starts with `streamAnchor=<id>` (`stack-<id>` for a card).
final class PeekBandUITests: OrientationPinnedUITestCase {

  private static let looseIDs = Array(7101...7108)
  private static let memberCounts = [7001: 7, 7002: 12, 7003: 18, 7004: 25, 7005: 33, 7006: 40]

  private static func members(_ stackID: Int) -> [Int] {
    (1...(memberCounts[stackID] ?? 0)).map { stackID * 100 + $0 }
  }

  // MARK: - UI-1: the band opens below the card's row

  func testChevronOpensABandBelowTheCardRowWithoutPushing() throws {
    let app = launched()
    let above = tile(app, 7101)
    XCTAssertTrue(above.waitForExistence(timeout: 15), "Loose 7101 is not on screen.")
    let aboveMinY = above.frame.minY
    let cardMaxY = try XCTUnwrap(card(app, 7001), "No card holds handle 7001.").frame.maxY

    toggle(app, 7001, expecting: "open")
    waitForBands(app, "7001")
    assertEntered(app, nil)
    XCTAssertFalse(
      app.descendants(matching: .any).matching(
        NSPredicate(format: "label BEGINSWITH %@", "Scene ·")
      ).firstMatch.exists,
      "The chevron pushed the scene: a 'Scene ·' title is on screen.")

    XCTAssertEqual(tile(app, 7101).frame.minY, aboveMinY, accuracy: 0.5, "A row above moved.")
    let band = Self.members(7001).map { tile(app, $0) }.filter { $0.exists }
    XCTAssertFalse(band.isEmpty, "No member of 7001 is on screen after the chevron.")
    for member in band {
      XCTAssertGreaterThan(
        member.frame.minY, cardMaxY - 0.5, "\(member.identifier) is not below the card's row.")
    }
    let top = band.map { $0.frame.minY }.min() ?? 0
    let bottom = band.map { $0.frame.maxY }.max() ?? 0
    for id in Self.looseIDs {
      let other = tile(app, id)
      guard other.exists else { continue }
      XCTAssertFalse(
        other.frame.minY < bottom - 0.5 && other.frame.maxY > top + 0.5,
        "Loose \(id) sits inside the band's rows (\(other.frame) vs \(top)…\(bottom)).")
    }
    XCTAssertTrue(
      element(app, "peekBandRow-7001").exists, "The band rows carry no peekBandRow-7001.")
  }

  // MARK: - UI-2: several bands, Esc

  func testThreeBandsOpenInInsertionOrderAndEscClosesTheLastOne() throws {
    let app = launched()
    toggle(app, 7002, expecting: "open")
    toggle(app, 7001, expecting: "open")
    toggle(app, 7003, expecting: "open")
    waitForBands(app, "7002,7001,7003")

    try pressEscape(app)
    waitForBands(app, "7002,7001")
    XCTAssertEqual(handle(app, 7003).value as? String, "closed")
    XCTAssertEqual(handle(app, 7001).value as? String, "open")
    XCTAssertEqual(handle(app, 7002).value as? String, "open")

    try pressEscape(app)
    waitForBands(app, "7002")
  }

  // MARK: - UI-3, UI-3b: Collapse all and the restore

  func testCollapseAllClosesEveryBandAndRestoresTheScrollPosition() throws {
    let app = launched()
    let before = streamAnchor(app)
    let cardMinY = try XCTUnwrap(card(app, 7001)).frame.minY
    toggle(app, 7001, expecting: "open")
    toggle(app, 7002, expecting: "open")
    waitForBands(app, "7001,7002")

    let collapse = element(app, "gridMoreMenu.more.collapseAllBands")
    XCTAssertTrue(openMoreMenu(in: app, revealing: collapse, timeout: 10), "No Collapse all row.")
    collapse.tap()
    waitForBands(app, "")
    XCTAssertEqual(handle(app, 7001).value as? String, "closed")
    XCTAssertEqual(handle(app, 7002).value as? String, "closed")
    XCTAssertFalse(tile(app, Self.members(7001)[0]).exists, "A member of 7001 is still drawn.")
    XCTAssertEqual(streamAnchor(app), before, "Collapse all moved the stream anchor.")
    XCTAssertEqual(
      try XCTUnwrap(card(app, 7001)).frame.minY, cardMinY, accuracy: 2,
      "The viewport did not come back to where it was.")
  }

  /// The plan's §5 example: open A, scroll into A, open B there, close A, scroll into B, Esc.
  /// B's open-time anchor named a member of A, which no longer exists, so the viewport lands on
  /// B's card. Scene 7006's 40 members are opened first so both destinations can scroll.
  func testClosingBandsInSequenceLandsOnTheSurvivingCard() throws {
    let app = launched()
    let topInset = tile(app, 7101).frame.minY
    let a = 7001

    toggle(app, 7006, expecting: "open")
    scrollUntil(app, "the top of the stream", up: false) { self.handle(app, a).isHittable }
    toggle(app, a, expecting: "open")
    // B is the first card drawn BELOW A's band: on a wide grid 7002 shares A's row, and a card
    // above the band is off screen while the anchor is inside it.
    let bandBottom =
      Self.members(a).map { tile(app, $0) }.filter { $0.exists }.map { $0.frame.maxY }.max() ?? 0
    let b =
      [7002, 7003, 7004, 7005].first {
        handle(app, $0).exists && handle(app, $0).frame.minY > bandBottom
      } ?? 7002
    // Short drags stop at A's first member, where a narrow grid can still hold B below the
    // screen: go on until both hold.
    scrollUntil(app, "the anchor inside A with B's chevron on screen", up: true) {
      Self.members(a).map(String.init).contains(self.streamAnchor(app))
        && self.handle(app, b).isHittable
    }
    XCTAssertTrue(
      handle(app, b).isHittable,
      "Precondition: B's chevron is not reachable with the anchor inside A "
        + "(anchor \(streamAnchor(app))).")
    toggle(app, b, expecting: "open")

    scrollUntil(app, "A's chevron", up: false) { self.handle(app, a).isHittable }
    toggle(app, a, expecting: "closed")
    waitForBands(app, "7006,\(b)")

    scrollUntil(app, "the anchor inside B", up: true) {
      Self.members(b).map(String.init).contains(self.streamAnchor(app))
    }
    try pressEscape(app)
    waitForBands(app, "7006")

    waitFor(app, "debugProbe.scroll", "value BEGINSWITH %@", "streamAnchor=stack-\(b);", "anchor")
    let cardB = try XCTUnwrap(card(app, b), "B's card is not on screen after the close.")
    XCTAssertEqual(cardB.frame.minY, topInset, accuracy: 4, "B's card is not at the grid's top.")
    for id in Self.members(a) + Self.members(b) {
      XCTAssertFalse(tile(app, id).exists, "Member \(id) of a closed band is still drawn.")
    }
  }

  // MARK: - UI-4: marks inside a band

  func testPickDislikeAndClearMarkInsideABandAndTheTileStaysUnderAMarkFilter() throws {
    let app = launched()
    let unmarked = element(app, "filterPopoverRow-mark-none")
    XCTAssertTrue(
      openPresentation(element(app, "gridFilterControl"), revealing: unmarked, timeout: 10),
      "The filter popover has no Unmarked row.")
    unmarked.tap()
    XCTAssertTrue(handle(app, 7001).waitForExistence(timeout: 15), "The filter lost card 7001.")

    toggle(app, 7001, expecting: "open")
    let member = Self.members(7001)[1]
    focus(member, in: app)
    let minY = tile(app, member).frame.minY

    for (key, verb) in [("p", "pick"), ("x", "dislike"), ("u", "none")] {
      app.typeKey(key, modifierFlags: [])
      waitFor(
        app, "debugProbe.markRequests", "value ENDSWITH %@", "\(verb):\(member)",
        "\(key) on band member \(member)")
      XCTAssertTrue(tile(app, member).exists, "\(verb): the member left the band.")
      XCTAssertEqual(
        tile(app, member).frame.minY, minY, accuracy: 0.5, "\(verb): the member moved.")
    }

    let latch = app.buttons["gridTapToPickToggle"]
    XCTAssertTrue(latch.waitForExistence(timeout: 10), "No Tap to Pick toggle.")
    latch.tap()
    XCTAssertTrue(
      app.staticTexts["lockModeCaption"].waitForExistence(timeout: 10), "Pick Lock is not on.")
    let other = Self.members(7001)[2]
    tile(app, other).tap()
    waitFor(
      app, "debugProbe.markRequests", "value ENDSWITH %@", "pick:\(other)",
      "a latched tap on band member \(other)")
    XCTAssertTrue(tile(app, other).exists, "The latched pick took the member out of the band.")
    let written = probe(app, "debugProbe.markRequests")
      .replacingOccurrences(of: "markRequests=", with: "")
      .split(separator: "|").flatMap { $0.split(separator: ":").last?.split(separator: ",") ?? [] }
    XCTAssertFalse(written.contains("7001"), "A write named the card's id: \(written).")
  }

  // MARK: - UI-5, UI-5b: the loupe

  func testTheLoupeFilmstripOfABandMemberIsTheBand() throws {
    let app = launched()
    toggle(app, 7001, expecting: "open")
    openLoupe(app, on: Self.members(7001)[0])
    XCTAssertTrue(
      element(app, "loupeFilmstrip").waitForExistence(timeout: 10),
      "A member's loupe has no strip.")
    let thumbnails = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'filmstripThumbnail-'"))
    XCTAssertEqual(thumbnails.count, Self.members(7001).count, "The strip is not the band.")
    for id in Self.members(7001) {
      XCTAssertTrue(app.buttons["filmstripThumbnail-\(id)"].exists, "\(id) is not in the strip.")
    }
    for id in Self.looseIDs {
      XCTAssertFalse(app.buttons["filmstripThumbnail-\(id)"].exists, "Loose \(id) is in the strip.")
    }
  }

  func testTheLoupeOnALoosePhotographWalksOpenBandsAndSkipsClosedOnes() throws {
    let app = launched()
    toggle(app, 7001, expecting: "open")
    toggle(app, 7002, expecting: "open")
    toggle(app, 7001, expecting: "closed")
    waitForBands(app, "7002")

    // The loupe's OWN advance (its Next control, the card-order walk), not the grid's arrow,
    // which walks the packed rows. From 7101 the next photograph is 7102: the closed band of
    // 7001 between them is skipped.
    openLoupe(app, on: 7101)
    XCTAssertFalse(element(app, "loupeFilmstrip").exists, "A loose photograph drew a strip.")
    tapLoupeNext(app)
    app.typeKey("p", modifierFlags: [])
    app.buttons["loupeBack"].tap()
    waitFor(app, "debugProbe.markRequests", "value ENDSWITH %@", "pick:7102", "→ from 7101")

    // From 7102 the walk enters the open band of 7002 at its first member.
    openLoupe(app, on: 7102)
    tapLoupeNext(app)
    app.typeKey("p", modifierFlags: [])
    app.buttons["loupeBack"].tap()
    waitFor(
      app, "debugProbe.markRequests", "value ENDSWITH %@", "pick:\(Self.members(7002)[0])",
      "→ from 7102")
  }

  // MARK: - UI-6: the card still pushes

  func testCardTapStillPushesWithABandOpen() throws {
    let app = launched()
    toggle(app, 7001, expecting: "open")
    let body = try XCTUnwrap(card(app, 7001))
    body.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
    assertEntered(app, 7001)
    let back = app.buttons["sceneBackButton"]
    if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
    assertEntered(app, nil)
    XCTAssertEqual(handle(app, 7001).value as? String, "open", "The push closed the band.")
  }

  // MARK: - Helpers

  private func launched(extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments =
      ["-UITestStubGrid", "-UITestEnterSceneMode", "-UITestPeekBands"] + extra
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s.")
    XCTAssertTrue(
      handle(app, 7001).waitForExistence(timeout: 20), "The peek-band fixture never showed 7001.")
    return app
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  private func tile(_ app: XCUIApplication, _ id: Int) -> XCUIElement {
    element(app, "gridTile-\(id)")
  }

  private func handle(_ app: XCUIApplication, _ stackID: Int) -> XCUIElement {
    element(app, "sceneHandle-\(stackID)")
  }

  /// Every card answers to `sceneCard`; the one meant is the card holding this scene's chevron.
  private func card(_ app: XCUIApplication, _ stackID: Int) -> XCUIElement? {
    let chevron = handle(app, stackID)
    guard chevron.exists else { return nil }
    let centre = CGPoint(x: chevron.frame.midX, y: chevron.frame.midY)
    let cards = app.descendants(matching: .any).matching(identifier: "sceneCard")
    for index in 0..<cards.count {
      let candidate = cards.element(boundBy: index)
      if candidate.frame.contains(centre) { return candidate }
    }
    return nil
  }

  private func probe(_ app: XCUIApplication, _ identifier: String) -> String {
    (element(app, identifier).value as? String) ?? "<absent>"
  }

  private func streamAnchor(_ app: XCUIApplication) -> String {
    let value = probe(app, "debugProbe.scroll")
    return value.components(separatedBy: ";").first?.replacingOccurrences(
      of: "streamAnchor=", with: "") ?? "none"
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
      "\(what): \(identifier) reads '\(probe(app, identifier))', expected \(format) "
        + "\(argument).", file: file, line: line)
  }

  private func waitForBands(
    _ app: XCUIApplication, _ ids: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    waitFor(
      app, "debugProbe.frames", "value ENDSWITH %@", "bands=\(ids)",
      "open bands (keys received: \(probe(app, "debugProbe.keyReceipts")))",
      file: file, line: line)
  }

  /// Presses Esc and skips the test when the press never reaches the app: the gate's
  /// simulators can withhold hardware keys (IMGMGR-508), and an empty `debugProbe.keyReceipts`
  /// means `UIApplication.sendEvent` saw nothing. A press that ARRIVES and closes nothing still
  /// fails at the caller's band check. Esc's dispatch is PeekBandTests and
  /// MenuOneRowPerCommandTests.
  private func pressEscape(_ app: XCUIApplication) throws {
    let before = receiptCount(app)
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    let deadline = Date(timeIntervalSinceNow: 5)
    while Date() < deadline {
      if receiptCount(app) > before { return }
      Thread.sleep(forTimeInterval: 0.25)
    }
    throw XCTSkip(
      "Esc never reached the app (\(probe(app, "debugProbe.keyReceipts"))), so hardware keys "
        + "are not delivered on this destination; Esc's dispatch is PeekBandTests and "
        + "MenuOneRowPerCommandTests.")
  }

  private func receiptCount(_ app: XCUIApplication) -> Int {
    let list = probe(app, "debugProbe.keyReceipts").replacingOccurrences(
      of: "keyReceipts=", with: "")
    return list.isEmpty || list == "<absent>" ? 0 : list.components(separatedBy: "; ").count
  }

  private func assertEntered(
    _ app: XCUIApplication, _ stackID: Int?, file: StaticString = #filePath, line: UInt = #line
  ) {
    let value =
      stackID.map { "instance=scene-\($0);entered=\($0)" } ?? "instance=stream;entered=none"
    waitFor(app, "debugProbe.scope", "value == %@", value, "scope", file: file, line: line)
  }

  /// Taps the chevron (scrolling it into reach first) and waits for its state.
  private func toggle(
    _ app: XCUIApplication, _ stackID: Int, expecting state: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let chevron = handle(app, stackID)
    scrollUntil(app, "chevron \(stackID)", file: file, line: line) {
      chevron.exists && chevron.isHittable
    }
    chevron.tap()
    waitFor(
      app, "sceneHandle-\(stackID)", "value == %@", state, "chevron \(stackID)",
      file: file, line: line)
  }

  /// Swipes the grid until `done` holds: in the given direction, or — with none given — down
  /// first (a no-op at the top of the stream), then up. Fails after eight swipes each way.
  private func scrollUntil(
    _ app: XCUIApplication, _ what: String, up: Bool? = nil,
    file: StaticString = #filePath, line: UInt = #line, _ done: () -> Bool
  ) {
    if done() { return }
    let directions: [Bool] = up.map { [$0] } ?? [false, true]
    for direction in directions {
      for _ in 0..<(direction ? 30 : 8) where !done() {
        if direction { nudgeUp(app) } else { app.swipeDown(velocity: .slow) }
        Thread.sleep(forTimeInterval: 0.6)
      }
      if done() { return }
    }
    XCTFail("Could not scroll to \(what) (anchor \(streamAnchor(app))).", file: file, line: line)
  }

  /// A short drag held at its end, so the content moves about a sixth of the screen and does not
  /// fling: a swipe can carry a one-row band past the top in a single step on a wide grid.
  private func nudgeUp(_ app: XCUIApplication) {
    let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
    let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46))
    from.press(
      forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(300),
      thenHoldForDuration: 0.3)
  }

  /// A browse tap moves the focus; a loupe that opened instead is closed again.
  private func focus(_ imageID: Int, in app: XCUIApplication) {
    let target = tile(app, imageID)
    scrollUntil(app, "gridTile-\(imageID)") { target.exists && target.isHittable }
    target.tap()
    let close = app.buttons["loupeBack"]
    if close.waitForExistence(timeout: 1) { close.tap() }
    waitFor(app, "debugProbe.focus", "value ENDSWITH %@", "focusedImageID=\(imageID)", "focus")
  }

  /// The second tap on the focused tile opens the loupe (`GridStore.tapTile`).
  private func tapLoupeNext(_ app: XCUIApplication) {
    let next = app.buttons["loupeNext"]
    XCTAssertTrue(next.waitForExistence(timeout: 5), "The loupe has no Next control.")
    XCTAssertTrue(next.isEnabled, "The loupe's Next control is disabled.")
    next.tap()
  }

  private func openLoupe(_ app: XCUIApplication, on imageID: Int) {
    let target = tile(app, imageID)
    scrollUntil(app, "gridTile-\(imageID)") { target.exists && target.isHittable }
    let close = app.buttons["loupeBack"]
    for _ in 0..<3 where !close.exists {
      let current = tile(app, imageID)
      guard current.exists else { break }
      current.tap()
      _ = close.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(close.exists, "Tapping gridTile-\(imageID) never opened the loupe.")
  }
}
