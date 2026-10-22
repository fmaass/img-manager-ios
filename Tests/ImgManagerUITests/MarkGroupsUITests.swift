import Foundation
import XCTest

/// IMGMGR-541 (R3-6, R3-16, R3-21) on the real surface, both destinations: grouped by Mark, the
/// grid heads "Picks · 5" and "Dislikes · 2" and closes with ONE row, "493 photos without a
/// mark", which opens the photographs without a mark like a scene.
///
/// Fixture (`-UITestStubGrid -UITestMarkGroups`): 500 photographs, 9001…9500 — 9001…9005 picked,
/// 9006…9007 disliked, the rest without a mark; ratings 3×5, 2×4, 2×1, the rest unrated or 0/-1.
/// The fixture moves a photograph between groups only on the next request after a real mark
/// write, as a server does.
final class MarkGroupsUITests: OrientationPinnedUITestCase {

  private static let markRow = "493 photos without a mark"

  // MARK: - Acceptance

  func testGroupByMarkShowsPicksDislikesAndOneRemainderRow() throws {
    let app = launched()
    setGroup(app, "arrange.group.mark")
    assertHeader(app, "Picks · 5")
    assertHeader(app, "Dislikes · 2")
    let row = remainderRow(app)
    XCTAssertTrue(row.waitForExistence(timeout: 15), "No remainder row under Mark.")
    XCTAssertEqual(row.label, Self.markRow)
    XCTAssertEqual(count(app, "groupRemainderRow"), 1, "More than one remainder row.")
    XCTAssertEqual(headerCount(app, "Unknown"), 0, "The null bucket got a header.")
    XCTAssertFalse(element(app, "gridTile-9008").exists, "An unmarked photo is in the stream.")
    attach("mark-groups-stream")
  }

  func testAMarkInsideTheRemainderStaysUntilBackThenTheRowShrinks() throws {
    let app = launched()
    setGroup(app, "arrange.group.mark")
    let row = remainderRow(app)
    XCTAssertTrue(row.waitForExistence(timeout: 15), "No remainder row under Mark.")
    row.tap()
    assertScope(app, "instance=remainder-mark;entered=remainder-mark")

    focus(9008, in: app)
    app.typeKey("p", modifierFlags: [])
    waitFor(app, "debugProbe.markRequests", "value == %@", "markRequests=pick:9008", "P on 9008")
    let tile = element(app, "gridTile-9008")
    XCTAssertTrue(tile.exists, "The photo marked inside the remainder left it.")
    let picked = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value CONTAINS %@", "pick"), object: tile)
    XCTAssertEqual(XCTWaiter().wait(for: [picked], timeout: 10), .completed, "9008 not picked.")
    let next = element(app, "gridTile-9009")
    XCTAssertTrue(next.exists)
    XCTAssertTrue(precedes(tile.frame, next.frame), "9008 moved: \(tile.frame), \(next.frame).")
    attach("mark-groups-remainder-marked")

    goBack(app)
    assertScope(app, "instance=stream;entered=none")
    let shrunk = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", "492 photos without a mark"),
      object: remainderRow(app))
    XCTAssertEqual(
      XCTWaiter().wait(for: [shrunk], timeout: 15), .completed,
      "The row did not shrink on return: '\(remainderRow(app).label)'.")
    assertHeader(app, "Picks · 6")
    XCTAssertTrue(element(app, "gridTile-9008").exists, "9008 is not under Picks.")
  }

  // MARK: - Presentation

  func testCompactRemainderPushesAndInteractiveBackReturns() throws {
    let app = launched()
    try requireCompact(app)
    setGroup(app, "arrange.group.mark")
    let row = remainderRow(app)
    XCTAssertTrue(row.waitForExistence(timeout: 15), "No remainder row under Mark.")
    row.tap()
    assertScope(app, "instance=remainder-mark;entered=remainder-mark")
    XCTAssertTrue(
      app.navigationBars[Self.markRow].waitForExistence(timeout: 10),
      "The pushed screen is not titled '\(Self.markRow)'.")
    XCTAssertTrue(element(app, "gridTile-9008").waitForExistence(timeout: 10))

    let window = app.windows.firstMatch
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).press(
      forDuration: 0.05,
      thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
    assertScope(app, "instance=stream;entered=none")
    XCTAssertEqual(remainderRow(app).label, Self.markRow, "Back without a mark changed the row.")
  }

  func testRegularRemainderShowsTitleAndBackButton() throws {
    let app = launched()
    guard app.frame.size.width >= Self.compactShellWidthCeiling else {
      throw XCTSkip("Regular-only: this destination is Compact (\(app.frame.size.width) pt).")
    }
    setGroup(app, "arrange.group.mark")
    let row = remainderRow(app)
    XCTAssertTrue(row.waitForExistence(timeout: 15), "No remainder row under Mark.")
    row.tap()
    assertScope(app, "instance=remainder-mark;entered=remainder-mark")
    let title = app.staticTexts.matching(NSPredicate(format: "label == %@", Self.markRow))
    XCTAssertTrue(
      title.firstMatch.waitForExistence(timeout: 10),
      "The remainder is not titled '\(Self.markRow)'.")
    let back = app.buttons["sceneBackButton"]
    XCTAssertTrue(back.waitForExistence(timeout: 10), "No Back button in the remainder.")
    back.tap()
    assertScope(app, "instance=stream;entered=none")
  }

  func testSceneDefaultFolderToMarkAndBackToScene() throws {
    let app = launched(extra: ["-UITestFolderHasScenes"])
    XCTAssertTrue(
      element(app, "sceneHandle-5000").waitForExistence(timeout: 20), "Not in Scene at launch.")
    setGroup(app, "arrange.group.mark")
    assertHeader(app, "Picks · 5")
    XCTAssertTrue(remainderRow(app).waitForExistence(timeout: 15), "No remainder row.")
    setGroup(app, "arrange.group.scene")
    XCTAssertTrue(
      element(app, "sceneHandle-5000").waitForExistence(timeout: 15), "Scene did not return.")
    XCTAssertEqual(count(app, "groupRemainderRow"), 0, "The remainder row outlived Mark.")
  }

  func testArrangeGroupListIsNoneSceneMarkRatingCameraLensIsoLocation() throws {
    let app = launched()
    let order = [
      "arrange.group.none", "arrange.group.scene", "arrange.group.mark", "arrange.group.rating",
      "arrange.group.camera", "arrange.group.lens", "arrange.group.iso", "arrange.group.location",
    ]
    openArrange(app, revealing: order[0])
    for (above, below) in zip(order, order.dropFirst()) {
      let lower = element(app, below)
      XCTAssertTrue(revealInArrange(lower, in: app), "'\(below)' is not reachable.")
      let upper = element(app, above)
      if upper.exists {
        XCTAssertLessThan(upper.frame.minY, lower.frame.minY, "'\(above)' over '\(below)'.")
      }
    }
    for gone in ["arrange.group.day", "arrange.group.month"] {
      XCTAssertEqual(count(app, gone), 0, "'\(gone)' is still offered.")
    }
  }

  func testGroupByRatingShowsTheRemainderRow() throws {
    let app = launched()
    setGroup(app, "arrange.group.rating")
    assertHeader(app, "5 · 3")
    assertHeader(app, "4 · 2")
    assertHeader(app, "1 · 2")
    let row = remainderRow(app)
    XCTAssertTrue(row.waitForExistence(timeout: 15), "No remainder row under Rating.")
    XCTAssertEqual(row.label, "493 photos without a rating")
    row.tap()
    assertScope(app, "instance=remainder-rating;entered=remainder-rating")
    XCTAssertTrue(element(app, "gridTile-9008").waitForExistence(timeout: 10), "0 is unrated.")
  }

  // MARK: - Helpers

  private func launched(extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestMarkGroups"] + extra
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s.")
    return app
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  private func count(_ app: XCUIApplication, _ identifier: String) -> Int {
    app.descendants(matching: .any).matching(identifier: identifier).count
  }

  /// Reading order: above, or on the same line and to the left.
  private func precedes(_ first: CGRect, _ second: CGRect) -> Bool {
    if first.minY != second.minY { return first.minY < second.minY }
    return first.minX < second.minX
  }

  private func remainderRow(_ app: XCUIApplication) -> XCUIElement {
    element(app, "groupRemainderRow")
  }

  private func headers(_ app: XCUIApplication, _ label: String) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == %@ AND label == %@", "gridSectionHeader", label))
  }

  private func headerCount(_ app: XCUIApplication, _ label: String) -> Int {
    headers(app, label).count
  }

  private func assertHeader(
    _ app: XCUIApplication, _ label: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      headers(app, label).firstMatch.waitForExistence(timeout: 15),
      "No section header '\(label)'.", file: file, line: line)
  }

  private func probe(_ app: XCUIApplication, _ identifier: String) -> String {
    (element(app, identifier).value as? String) ?? "<absent>"
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

  private func assertScope(
    _ app: XCUIApplication, _ value: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    waitFor(app, "debugProbe.scope", "value == %@", value, "scope", file: file, line: line)
  }

  private func requireCompact(_ app: XCUIApplication) throws {
    guard app.frame.size.width < Self.compactShellWidthCeiling else {
      throw XCTSkip("Compact-only: this destination is Regular (\(app.frame.size.width) pt).")
    }
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
    XCTAssertTrue(tile.waitForExistence(timeout: 10), "gridTile-\(imageID) is not on screen.")
    tile.tap()
    let close = app.buttons["loupeBack"]
    if close.waitForExistence(timeout: 1) { close.tap() }
    waitFor(app, "debugProbe.focus", "value ENDSWITH %@", "focusedImageID=\(imageID)", "focus")
  }

  private func openArrange(_ app: XCUIApplication, revealing row: String) {
    let control = element(app, "gridArrangeControl")
    XCTAssertTrue(control.waitForExistence(timeout: 10), "No 'gridArrangeControl'.")
    XCTAssertTrue(
      openPresentation(control, revealing: element(app, row), timeout: 10),
      "Arrange did not offer '\(row)'.")
  }

  private func setGroup(_ app: XCUIApplication, _ row: String) {
    openArrange(app, revealing: row)
    let item = element(app, row)
    XCTAssertTrue(revealInArrange(item, in: app), "'\(row)' is not reachable.")
    item.tap()
    let done = element(app, "arrangeDone")
    XCTAssertTrue(revealInArrange(done, in: app), "Arrange's Done is not reachable.")
    done.tap()
    XCTAssertTrue(done.waitForNonExistence(timeout: 10), "Done did not close Arrange.")
  }

  private func attach(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
