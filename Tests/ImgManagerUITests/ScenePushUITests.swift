import Foundation
import UIKit
import XCTest

/// WP442 P12 (IMGMGR-540): a scene card PUSHES a scene screen titled "Scene · N photos".
///
/// Fixture (`-UITestStubGrid -UITestEnterSceneMode`): the stream is loose 1, loose 2, scene 5000,
/// loose 8, loose 9. Scene 5000 holds 41 photographs — members 3…7 (3 and 5 picked), the plain
/// tail 601…635, and 700 on the second membership page — so its card reads "41 photos, 2 picked".
///
/// The `debugProbe.*` elements render only from the ACTIVE grid instance, so `debugProbe.scope`
/// names the one instance the reader is looking at and the store's entry together.
///
/// Each test names the planned mutant it kills (plan §4, T1–T12).
final class ScenePushUITests: OrientationPinnedUITestCase {

  private static let scene = 5000
  private static let splitScene = 5001
  private static let title = "Scene · 41 photos"
  private static let tailMember = 621
  /// Split at 621: 5001 holds 621…635.
  private static let tailCount = 15

  // MARK: - T1–T6: the push and the write boundary

  /// T1 · kills M5 (a mark made inside never reaches the card the reader goes Back to).
  func testPushMarkBackIncrementsTheCardsPickCount() throws {
    let app = launched()
    XCTAssertTrue(card(app).label.contains("2 picked"), "Fixture card: '\(card(app).label)'.")
    tapCardBody(app)
    assertEntered(app, Self.scene)
    assertTitle(app, Self.title)

    focus(601, in: app)
    app.typeKey("p", modifierFlags: [])
    waitFor(app, "debugProbe.markRequests", "value == %@", "markRequests=pick:601", "P on 601")

    goBack(app)
    assertEntered(app, nil)
    let picked = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS %@", "3 picked"), object: card(app))
    XCTAssertEqual(
      XCTWaiter().wait(for: [picked], timeout: 15), .completed,
      "The card did not count the pick made inside: '\(card(app).label)'.")

    // The member read shows 601 picked on the next push.
    tapCardBody(app)
    let tile = element(app, "gridTile-601")
    XCTAssertTrue(tile.waitForExistence(timeout: 15))
    XCTAssertTrue(
      ((tile.value as? String) ?? "").contains("pick"),
      "601 is not drawn picked after re-entry: '\(String(describing: tile.value))'.")
  }

  /// T2 · kills M4 (the transition calls `pickLock.exit()`).
  func testLatchEngagedBeforePushIsEngagedAfterBack() throws {
    let app = launched(extra: ["-UITestLatchDislikeLock"])
    let caption = app.staticTexts["lockModeCaption"]
    XCTAssertTrue(caption.waitForExistence(timeout: 20), "Precondition: the latch is not on.")
    pushScene(app, Self.scene)
    assertEntered(app, Self.scene)
    XCTAssertTrue(
      app.staticTexts["lockModeCaption"].waitForExistence(timeout: 10),
      "Pushing the scene let go of the latch.")
    goBack(app)
    assertEntered(app, nil)
    XCTAssertTrue(
      app.staticTexts["lockModeCaption"].waitForExistence(timeout: 10),
      "Back let go of the latch.")
  }

  /// T3 · kills M18 / M18s (card focus leaves the photo focus standing, so P marks it).
  func testPOnAFocusedCardSendsNoMarkRequest() throws {
    let app = launched()
    app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
    let focusProbe = element(app, "debugProbe.focus")
    let focused = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value MATCHES %@", "uiFocus=none;focusedImageID=[0-9]+"),
      object: focusProbe)
    guard XCTWaiter().wait(for: [focused], timeout: 10) == .completed else {
      throw XCTSkip(
        "→ focused no photograph (\(String(describing: focusProbe.value))): bare keys do not "
          + "reach the app on this destination, so P cannot be observed (CompareUITests).")
    }
    let snapshot = probe(app, "debugProbe.markRequests")

    focusTheCardForReal(app)
    // PRECONDITION: real focus is on the card. A failure here is a STOP, never a caught mutant.
    waitFor(
      app, "debugProbe.focus", "value BEGINSWITH %@", "uiFocus=card-\(Self.scene);",
      "precondition: card focus")
    // IMGMGR-574: focusing the card opens nothing; the reader is still on the stream.
    assertEntered(app, nil)
    app.typeKey("p", modifierFlags: [])
    Thread.sleep(forTimeInterval: 1.5)
    XCTAssertEqual(
      probe(app, "debugProbe.markRequests"), snapshot, "P on a focused card wrote a mark.")
    XCTAssertTrue(probe(app, "debugProbe.focus").hasSuffix("focusedImageID=none"))

    // Positive control, same launch: a photo focus again → P writes exactly once. With the
    // system focus engaged (Regular, after Tab) an arrow can be the focus engine's move rather
    // than the grid's, so a tap on a loose photograph is the fallback driver of the photo focus.
    app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
    let photoFocus = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value MATCHES %@", "uiFocus=none;focusedImageID=[0-9]+"),
      object: focusProbe)
    if XCTWaiter().wait(for: [photoFocus], timeout: 5) != .completed { focus(1, in: app) }
    waitFor(
      app, "debugProbe.focus", "value MATCHES %@", "uiFocus=none;focusedImageID=[0-9]+",
      "control: photo focus")
    let photo = probe(app, "debugProbe.focus").components(separatedBy: "focusedImageID=").last!
    app.typeKey("p", modifierFlags: [])
    waitFor(
      app, "debugProbe.markRequests", "value ENDSWITH %@", "pick:\(photo)",
      "control: P on \(photo)")
    tapCardBody(app)
    assertEntered(app, Self.scene)
    focus(601, in: app)
    app.typeKey("p", modifierFlags: [])
    waitFor(app, "debugProbe.markRequests", "value ENDSWITH %@", "|pick:601", "P on 601 inside")
  }

  /// IMGMGR-586 (comment 12426): three members picked through three entry points — the tile
  /// corner, the bar's Pick on a focused member, the loupe's Pick — each write names its own
  /// member, never the cover or the first member. Members 4, 5, 6 are the 2nd–4th of 3…7; 5 is
  /// already picked, and the bar's Pick writes `pick` regardless (it sets, it does not toggle).
  func testPicksOnThreeMembersEachWriteThatMember() throws {
    let app = launched()
    tapCardBody(app)
    assertEntered(app, Self.scene)

    let corner = element(app, "tileMarkCorner-4")
    XCTAssertTrue(corner.waitForExistence(timeout: 15), "Member 4 carries no mark corner.")
    corner.tap()
    waitFor(app, "debugProbe.markRequests", "value == %@", "markRequests=pick:4", "corner on 4")

    focus(5, in: app)
    let barPick = app.buttons["gridPickButton"]
    XCTAssertTrue(barPick.waitForExistence(timeout: 10), "The bar has no Pick control.")
    barPick.tap()
    waitFor(
      app, "debugProbe.markRequests", "value == %@", "markRequests=pick:4|pick:5", "bar Pick on 5")

    // Focus first, then a tap on the focused tile opens the loupe on it (spec 3220 §2.2).
    focus(6, in: app)
    element(app, "gridTile-6").tap()
    XCTAssertTrue(app.buttons["loupeBack"].waitForExistence(timeout: 10), "No loupe on 6.")
    let loupePick = app.buttons["loupePickButton"]
    XCTAssertTrue(loupePick.waitForExistence(timeout: 10), "The loupe has no Pick control.")
    loupePick.tap()
    // The probes render from the active grid instance only, which the Regular loupe is not.
    let back = app.buttons["loupeBack"]
    if back.waitForExistence(timeout: 2) { back.tap() }
    waitFor(
      app, "debugProbe.markRequests", "value == %@", "markRequests=pick:4|pick:5|pick:6",
      "loupe Pick on 6")
  }

  /// T4 · kills M19a (the body tap routes `.stack` nowhere).
  func testCardBodyTapPushesTheScene() throws {
    let app = launched()
    tapCardBody(app)
    assertEntered(app, Self.scene)
    XCTAssertTrue(element(app, "gridTile-3").waitForExistence(timeout: 15))
  }

  /// T5 · kills M19 (a latched `tapCell(.stack)` marks the representative).
  func testLatchedCardBodyTapPushesAndMarksNothing() throws {
    let app = launched(extra: ["-UITestLatchDislikeLock"])
    XCTAssertTrue(app.staticTexts["lockModeCaption"].waitForExistence(timeout: 20))
    tapCardBody(app)
    assertEntered(app, Self.scene)
    XCTAssertEqual(probe(app, "debugProbe.markRequests"), "markRequests=")
    XCTAssertTrue(
      app.staticTexts["lockModeCaption"].waitForExistence(timeout: 5),
      "The latch did not survive the push.")
  }

  /// T6 · kills M19b (the card no longer enters). IMGMGR-542: the chevron opens a peek band,
  /// so the push is the card's.
  func testCardTapPushesTheScene() throws {
    let app = launched()
    pushScene(app, Self.scene)
    assertEntered(app, Self.scene)
    assertTitle(app, Self.title)
  }

  // MARK: - T7: Back names the folder

  /// T7 · kills M23 (subtitle and Back label dropped).
  func testBackNamesALongFolderTitle() throws {
    let app = launched(extra: ["-UITestLongFolderTitle"])
    let folder =
      "2026-08-27 — A Very Long Stub Shoot Title That Keeps Going Well Past Its Label!!"
    tapCardBody(app)
    assertEntered(app, Self.scene)
    let regularBack = app.buttons["sceneBackButton"]
    if regularBack.waitForExistence(timeout: 5) {
      XCTAssertEqual(regularBack.label, folder)
      let bar = app.navigationBars.firstMatch
      XCTAssertTrue(
        bar.frame.insetBy(dx: -1, dy: -1).contains(regularBack.frame),
        "Back at \(regularBack.frame) lies outside the bar \(bar.frame).")
    } else {
      let back = app.navigationBars.buttons.element(boundBy: 0)
      XCTAssertTrue(back.waitForExistence(timeout: 10) && back.isHittable, "No Back.")
      XCTAssertTrue(
        [folder, "Back", ""].contains(back.label), "Back reads '\(back.label)'.")
      XCTAssertTrue(
        app.navigationBars.descendants(matching: .any).matching(
          NSPredicate(format: "label == %@", folder)
        ).firstMatch.waitForExistence(timeout: 10),
        "The folder title is not readable under the scene title.")
      back.tap()
      assertEntered(app, nil)
    }
  }

  // MARK: - T8: one active instance owns rows, presentations and probes

  /// T8 · kills M24 (W1 refusal dropped) and M25 (W6 getter gate dropped). Stage B: a merge
  /// needs a second scene, so the split fixture makes 5001 first.
  func testCompactSceneOwnsRowsPresentationsAndProbes() throws {
    let app = launched(extra: ["-UITestSplitCreatesScene"])
    try requireCompact(app)
    tapCardBody(app)
    assertEntered(app, Self.scene)
    XCTAssertEqual(count(app, "debugProbe.scope"), 1)

    focus(601, in: app)
    app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
    let moved = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value MATCHES %@", ".*focusedImageID=(60[2-9]|6[1-3][0-9])"),
      object: element(app, "debugProbe.focus"))
    XCTAssertEqual(
      XCTWaiter().wait(for: [moved], timeout: 5), .completed,
      "↓ did not move to a member one row down: '\(probe(app, "debugProbe.focus"))'.")

    splitAtTheTail(app)
    assertEntered(app, Self.splitScene)
    // A retarget keeps the selection ({621} is a member of 5001); select it again only if not.
    if !app.staticTexts["selectModeCaption"].waitForExistence(timeout: 2) {
      focus(Self.tailMember, in: app)
      longPress(Self.tailMember, in: app)
    }
    let merge = element(app, "selectBar.scene.merge")
    XCTAssertTrue(openSceneMenu(in: app, revealing: merge, timeout: 10))
    merge.tap()
    let target = element(app, "sceneMergeTarget-\(Self.scene)")
    XCTAssertTrue(target.waitForExistence(timeout: 10), "The merge picker did not present.")
    Thread.sleep(forTimeInterval: 1.0)
    XCTAssertEqual(count(app, "sceneMergeTarget-\(Self.scene)"), 1, "Two pickers presented.")
    XCTAssertTrue(target.exists, "An inactive instance dismissed the merge picker.")
    XCTAssertEqual(count(app, "debugProbe.scope"), 1)

    app.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(target.waitForNonExistence(timeout: 10))
    assertEntered(app, Self.splitScene)
    goBack(app)
    assertEntered(app, nil)
    Thread.sleep(forTimeInterval: 1.0)
    XCTAssertEqual(count(app, "sceneMergeTarget-\(Self.scene)"), 0, "The picker reappeared.")

    // The stream's own absorb picker: exactly one.
    let loose = element(app, "gridTile-1")
    XCTAssertTrue(loose.waitForExistence(timeout: 10))
    focus(1, in: app)
    longPress(1, in: app)
    let absorb = element(app, "selectBar.scene.absorb")
    XCTAssertTrue(openSceneMenu(in: app, revealing: absorb, timeout: 10))
    absorb.tap()
    XCTAssertTrue(element(app, "sceneAbsorbTarget-\(Self.scene)").waitForExistence(timeout: 10))
    XCTAssertEqual(count(app, "sceneAbsorbTarget-\(Self.scene)"), 1)
    XCTAssertEqual(count(app, "debugProbe.scope"), 1)
  }

  // MARK: - T9: one scroll slot per scope

  /// T9 · kills M27 (one shared slot) and M27b (the transition writes the stream anchor).
  /// Stage B: the scene slot records its first visible member on arrival, so "opens at the top"
  /// reads as `sceneAnchor=<first member>`, not `none`.
  func testBackReturnsToThePushedFromPosition() throws {
    let app = launched()
    setThumbnailSize(app, "arrange.size.400")
    let grid: XCUIElement = app
    var anchor = streamAnchor(app)
    for _ in 0..<6 where anchor == "1" || anchor == "none" || !card(app).isHittable {
      if anchor == "1" || anchor == "none" {
        grid.swipeUp(velocity: .slow)
      } else {
        grid.swipeDown(velocity: .slow)
      }
      Thread.sleep(forTimeInterval: 0.8)
      anchor = streamAnchor(app)
    }
    if anchor == "1" {
      // Stage B: a stream that fits its viewport (the iPad at size 400 holds all five rows)
      // cannot scroll; the anchor is then the first photograph, which a scene scroll (M27) or
      // the transition (M27b) would still overwrite.
      XCTContext.runActivity(named: "stream fits its viewport; anchor stays 1") { _ in }
    }
    XCTAssertTrue(
      anchor != "none" && card(app).isHittable,
      "Precondition: no recorded stream position with the card reachable (anchor \(anchor)).")
    let marker = anchor.hasPrefix("stack-") ? card(app) : element(app, "gridTile-\(anchor)")
    let minY = marker.frame.minY

    tapCardBody(app)
    assertEntered(app, Self.scene)
    var sceneAnchor = self.sceneAnchor(app)
    for _ in 0..<6 where sceneAnchor == "3" || sceneAnchor == "none" {
      app.swipeUp(velocity: .slow)
      Thread.sleep(forTimeInterval: 0.8)
      sceneAnchor = self.sceneAnchor(app)
    }
    XCTAssertTrue(
      sceneAnchor != "3" && sceneAnchor != "none", "Precondition: the scene did not scroll.")
    XCTAssertEqual(streamAnchor(app), anchor, "A scene scroll wrote the stream anchor.")

    goBack(app)
    assertEntered(app, nil)
    XCTAssertEqual(streamAnchor(app), anchor)
    let back = anchor.hasPrefix("stack-") ? card(app) : element(app, "gridTile-\(anchor)")
    XCTAssertTrue(back.waitForExistence(timeout: 10))
    XCTAssertLessThanOrEqual(abs(back.frame.minY - minY), 400, "Back lost the stream position.")

    tapCardBody(app)
    assertEntered(app, Self.scene)
    waitFor(
      app, "debugProbe.scroll", "value ENDSWITH %@", "sceneAnchor=3",
      "the re-pushed scene opens at its first member")
  }

  // MARK: - T10, T11: Compact navigation

  /// T10 · kills M28 (the stack setter ignores `leavesScene`).
  func testSwipeBackLeavesTheScene() throws {
    let app = launched()
    try requireCompact(app)
    tapCardBody(app)
    assertEntered(app, Self.scene)
    focus(601, in: app)
    let before = probe(app, "debugProbe.markRequests")
    let window = app.windows.firstMatch
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).press(
      forDuration: 0.05,
      thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
    waitFor(
      app, "debugProbe.scope", "value == %@", "instance=stream;entered=none", "the edge swipe")
    app.typeKey("p", modifierFlags: [])
    Thread.sleep(forTimeInterval: 1.5)
    XCTAssertEqual(probe(app, "debugProbe.markRequests"), before, "P after the swipe wrote.")
  }

  /// T11 · kills M43 (the projection keeps the push-time id) and M12.
  func testSplitInsideTheSceneShowsTheRetargetedScene() throws {
    let app = launched(extra: ["-UITestSplitCreatesScene"])
    try requireCompact(app)
    tapCardBody(app)
    assertEntered(app, Self.scene)
    splitAtTheTail(app)
    assertTitle(app, "Scene · \(Self.tailCount) photos")
    waitFor(
      app, "debugProbe.scope", "value == %@",
      "instance=scene-\(Self.splitScene);entered=\(Self.splitScene)", "the retargeted screen")
    goBack(app)
    waitFor(app, "debugProbe.scope", "value == %@", "instance=stream;entered=none", "one Back")
    XCTAssertTrue(element(app, "sceneHandle-\(Self.scene)").waitForExistence(timeout: 10))
  }

  // MARK: - T12: the stream scope in Flat

  /// T12 · kills M54 (`.stream` renders `sceneDisplayRows` in Flat → an empty grid).
  func testFlatRendersPhotosAndSceneToFlatRestoresThem() throws {
    // IMGMGR-557: a folder with scenes opens in Scene, so the test opts into Flat first.
    let app = launched(extra: ["-UITestFolderHasScenes"], sceneMode: false)
    setGroup(app, "arrange.group.none")
    XCTAssertTrue(element(app, "gridTile-1").waitForExistence(timeout: 15), "Flat is empty.")
    XCTAssertEqual(handles(app), 0)
    setGroup(app, "arrange.group.scene")
    XCTAssertTrue(element(app, "sceneHandle-\(Self.scene)").waitForExistence(timeout: 15))
    setGroup(app, "arrange.group.none")
    XCTAssertTrue(element(app, "gridTile-1").waitForExistence(timeout: 15), "Flat is empty again.")
    XCTAssertEqual(handles(app), 0)
  }

  // MARK: - Helpers

  private func launched(extra: [String] = [], sceneMode: Bool = true) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"] + (sceneMode ? ["-UITestEnterSceneMode"] : []) + extra
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s.")
    if sceneMode {
      XCTAssertTrue(
        element(app, "sceneHandle-\(Self.scene)").waitForExistence(timeout: 20),
        "Scene mode never showed the fixture card.")
    }
    return app
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  private func count(_ app: XCUIApplication, _ identifier: String) -> Int {
    app.descendants(matching: .any).matching(identifier: identifier).count
  }

  private func handles(_ app: XCUIApplication) -> Int {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "sceneHandle-")
    ).count
  }

  private func card(_ app: XCUIApplication) -> XCUIElement { element(app, "sceneCard") }

  private func probe(_ app: XCUIApplication, _ identifier: String) -> String {
    (element(app, identifier).value as? String) ?? "<absent>"
  }

  private func streamAnchor(_ app: XCUIApplication) -> String {
    let value = probe(app, "debugProbe.scroll")
    return value.components(separatedBy: ";").first?.replacingOccurrences(
      of: "streamAnchor=", with: "") ?? "none"
  }

  private func sceneAnchor(_ app: XCUIApplication) -> String {
    probe(app, "debugProbe.scroll").components(separatedBy: "sceneAnchor=").last ?? "none"
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

  private func assertEntered(
    _ app: XCUIApplication, _ stackID: Int?, file: StaticString = #filePath, line: UInt = #line
  ) {
    let value =
      stackID.map { "instance=scene-\($0);entered=\($0)" } ?? "instance=stream;entered=none"
    waitFor(app, "debugProbe.scope", "value == %@", value, "scope", file: file, line: line)
  }

  private func assertTitle(_ app: XCUIApplication, _ title: String) {
    XCTAssertTrue(
      app.descendants(matching: .any).matching(
        NSPredicate(format: "label == %@ OR identifier == %@", title, title)
      ).firstMatch.waitForExistence(timeout: 10),
      "The pushed screen is not titled '\(title)'.")
  }

  /// T3's driver of REAL card focus. Regular first walks the system focus with Tab — the FKA
  /// reader's own path, no touch involved (on iPad a touch resets the focus engine, which is how
  /// run 132312 lost the probe button's assignment). Then, or at Compact, the DEBUG probe button,
  /// whose assignment is deferred past the touch. The caller asserts the precondition.
  private func focusTheCardForReal(_ app: XCUIApplication) {
    let card = "uiFocus=card-\(Self.scene);"
    if app.frame.size.width >= Self.compactShellWidthCeiling {
      for _ in 0..<12 where !probe(app, "debugProbe.focus").hasPrefix(card) {
        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.4)
      }
      XCTContext.runActivity(named: "after Tab: \(probe(app, "debugProbe.focus"))") { _ in }
      if probe(app, "debugProbe.focus").hasPrefix(card) { return }
    }
    let button = element(app, "debugFocusSceneCard")
    XCTAssertTrue(button.waitForExistence(timeout: 10), "No debugFocusSceneCard on the stream.")
    button.tap()
    XCTContext.runActivity(named: "after the probe button: \(probe(app, "debugProbe.scope"))") {
      _ in
    }
  }

  /// The card's centre, off the handle.
  private func tapCardBody(_ app: XCUIApplication) {
    let body = card(app)
    XCTAssertTrue(body.waitForExistence(timeout: 15), "No scene card on the stream.")
    body.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
  }

  private func goBack(_ app: XCUIApplication) {
    let regularBack = app.buttons["sceneBackButton"]
    if regularBack.exists {
      regularBack.tap()
    } else {
      app.navigationBars.buttons.element(boundBy: 0).tap()
    }
  }

  /// A browse tap moves the focus; a loupe that opened instead is closed again.
  private func focus(_ imageID: Int, in app: XCUIApplication) {
    let tile = element(app, "gridTile-\(imageID)")
    for _ in 0..<8 where !(tile.exists && tile.isHittable) {
      app.swipeUp(velocity: .slow)
    }
    XCTAssertTrue(tile.waitForExistence(timeout: 10), "gridTile-\(imageID) is not on screen.")
    tile.tap()
    let close = app.buttons["loupeBack"]
    if close.waitForExistence(timeout: 1) { close.tap() }
    waitFor(app, "debugProbe.focus", "value ENDSWITH %@", "focusedImageID=\(imageID)", "focus")
  }

  private func longPress(_ imageID: Int, in app: XCUIApplication) {
    element(app, "gridTile-\(imageID)").press(forDuration: 1.0)
    XCTAssertTrue(
      app.staticTexts["selectModeCaption"].waitForExistence(timeout: 10),
      "Long-pressing gridTile-\(imageID) did not enter Select.")
  }

  /// Focus the tail member, select exactly it, Scene ▸ Split here.
  private func splitAtTheTail(_ app: XCUIApplication) {
    focus(Self.tailMember, in: app)
    longPress(Self.tailMember, in: app)
    let split = element(app, "selectBar.scene.split")
    XCTAssertTrue(openSceneMenu(in: app, revealing: split, timeout: 10), "No Split row.")
    XCTAssertTrue(split.isEnabled, "Split here is disabled on {\(Self.tailMember)}.")
    split.tap()
  }

  private func requireCompact(_ app: XCUIApplication) throws {
    guard app.frame.size.width < Self.compactShellWidthCeiling else {
      throw XCTSkip("Compact-only: this destination is Regular (\(app.frame.size.width) pt).")
    }
  }

  private func openArrange(_ app: XCUIApplication, revealing row: String) {
    let control = element(app, "gridArrangeControl")
    XCTAssertTrue(control.waitForExistence(timeout: 10), "No 'gridArrangeControl'.")
    XCTAssertTrue(
      openPresentation(control, revealing: element(app, row), timeout: 10),
      "Arrange did not offer '\(row)'.")
  }

  private func closeArrange(_ app: XCUIApplication) {
    let done = element(app, "arrangeDone")
    XCTAssertTrue(reveal(done, in: app), "Arrange's Done is not reachable.")
    done.tap()
    XCTAssertTrue(done.waitForNonExistence(timeout: 10), "Done did not close Arrange.")
  }

  private func setGroup(_ app: XCUIApplication, _ row: String) {
    openArrange(app, revealing: row)
    let item = element(app, row)
    XCTAssertTrue(reveal(item, in: app), "'\(row)' is not reachable.")
    item.tap()
    closeArrange(app)
  }

  private func setThumbnailSize(_ app: XCUIApplication, _ row: String) {
    openArrange(app, revealing: "arrange.group.scene")
    let item = element(app, row)
    XCTAssertTrue(reveal(item, in: app), "'\(row)' is not reachable.")
    item.tap()
    closeArrange(app)
  }

  /// Scrolls the Arrange popover until `element` is hittable (ArrangePopoverUITests' reveal).
  private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
    if element.exists && element.isHittable { return true }
    let scroller = app.scrollViews.containing(.any, identifier: "arrange.sort.date_taken")
      .firstMatch
    guard scroller.exists else { return false }
    for _ in 0..<5 where !(element.exists && element.isHittable) { scroller.swipeUp() }
    for _ in 0..<5 where !(element.exists && element.isHittable) { scroller.swipeDown() }
    return element.exists && element.isHittable
  }
}
