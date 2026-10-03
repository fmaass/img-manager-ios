import XCTest

/// WP30 P2 (IMGMGR-457): the Cull loupe's More menu and the photograph's context menu, on both
/// gate destinations. Membership is pinned here by identifier, and the section/group structure
/// by the pure tables the views render (`CullMenuModelTests`). Every other test in this file is
/// an EFFECT (plan r2, B5): a correctly populated menu whose row does nothing turns one of them
/// red.
final class LoupeMoreMenuUITests: OrientationPinnedUITestCase {

  /// The six More rows, in spec order: Share · Tag · Lock Pick · Lock Dislike | Zoom to 100% ·
  /// Advance after marking. Share keeps the identifier it has carried since IMGMGR-348.
  private static let moreRows = [
    "loupeShare", "loupeMore.tag", "loupeMore.lockPick", "loupeMore.lockDislike",
    "loupeMore.zoomToOneToOne", "loupeMore.advanceAfterMarking",
  ]

  /// The context menu's six top-level entries: Pick, Dislike, Clear | Tag, Share | Lock ▸.
  private static let contextEntries = [
    "loupeContext.pick", "loupeContext.dislike", "loupeContext.clear", "loupeContext.tag",
    "loupeContext.share", "loupeContext.lock",
  ]

  // MARK: - More: membership

  func testMoreShowsExactlyTheSixRows() throws {
    let app = launchAndOpenLoupe()
    openMore(app, revealing: "loupeShare")

    for identifier in Self.moreRows {
      XCTAssertTrue(element(app, identifier).exists, "More is missing its `\(identifier)` row.")
      XCTAssertEqual(
        app.descendants(matching: .any).matching(identifier: identifier).count, 1,
        "`\(identifier)` renders more than once in More.")
    }
    let moreOwn = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "loupeMore.")).count
    XCTAssertEqual(moreOwn, 5, "More carries a row beyond the spec's six (Share + five).")
    XCTAssertEqual(
      app.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS[c] %@", "Lightroom")).count, 0,
      "More carries a Lightroom row — owner decision D-a dropped it.")
    attach(app, name: "loupe-more-open")
  }

  // MARK: - More: effects

  /// Advance after marking OFF: Pick leaves the loupe on the same frame. Turned ON through the
  /// More row itself: the same Pick moves the focus — so an inert row keeps the title still and
  /// turns this red.
  func testAdvanceAfterMarkingRowDecidesWhetherPickMovesFocus() throws {
    let app = launchAndOpenLoupe(arguments: ["-UITestStubNoAutoAdvance"])
    let title = app.staticTexts["loupeTitle"]
    let pick = app.buttons["loupePickButton"]
    let undo = app.buttons["loupeUndoButton"]
    XCTAssertTrue(title.waitForExistence(timeout: 10), "The loupe has no title.")
    XCTAssertTrue(pick.waitForExistence(timeout: 10), "The loupe has no Pick control.")
    XCTAssertTrue(undo.waitForExistence(timeout: 10), "The loupe has no Undo control.")
    driveToUnpicked(app, pick: pick)

    let frameBefore = title.label
    pick.tap()
    waitFor("value == 'Picked'", pick)
    // IMGMGR-485: the write's own completion, not a sleep. Undo enables only once the entry is
    // recorded AND the mark lane is released (`LoupeUndoButton`), and `applyLoupeMark` decides
    // the advance synchronously after that release — so by the time Undo reads enabled, an
    // advance that was going to happen locally has happened. 'Picked' is observed first: while
    // the write is in flight Undo is disabled, so an Undo still enabled from the Clear above
    // cannot satisfy this wait early.
    waitFor("isEnabled == true", undo)
    XCTAssertEqual(
      title.label, frameBefore, "With Advance after marking OFF, Pick still moved the focus.")

    openMore(app, revealing: "loupeMore.advanceAfterMarking")
    element(app, "loupeMore.advanceAfterMarking").tap()

    waitFor("isEnabled == true", undo)
    undo.tap()
    waitFor("value == 'Not picked'", pick)
    let frameOn = title.label
    pick.tap()
    waitFor(NSPredicate(format: "label != %@", frameOn), title)
    XCTAssertNotEqual(
      title.label, frameOn,
      "With Advance after marking turned ON from More, Pick did not move the focus.")
  }

  /// Zoom to 100%: the photograph's own zoom reading goes fit → 1:1 → fit through the row.
  func testZoomTo100RowZoomsAndReturnsToFit() throws {
    let app = launchAndOpenLoupe()
    let image = element(app, "loupeImage")
    XCTAssertTrue(image.waitForExistence(timeout: 10), "The loupe has no photograph.")
    waitFor("value == 'zoom fit, pan 0, 0'", image)

    openMore(app, revealing: "loupeMore.zoomToOneToOne")
    element(app, "loupeMore.zoomToOneToOne").tap()
    waitFor("value BEGINSWITH 'zoom 100 %'", image)
    attach(app, name: "loupe-more-zoom-100")

    openMore(app, revealing: "loupeMore.zoomToOneToOne")
    element(app, "loupeMore.zoomToOneToOne").tap()
    waitFor("value == 'zoom fit, pan 0, 0'", image)
  }

  func testShareRowPresentsTheShareSheet() throws {
    let app = launchAndOpenLoupe()
    openMore(app, revealing: "loupeShare")
    element(app, "loupeShare").tap()
    XCTAssertTrue(waitForShareSheet(app), "More › Share did not present the share sheet.")
    attach(app, name: "loupe-more-share")
  }

  /// Tag: the grid's own tag entry, presented OVER the loupe — the docked Regular loupe has no
  /// grid mounted to host it, so a sheet left on the grid would never appear here.
  func testTagRowPresentsTheTagSheet() throws {
    let app = launchAndOpenLoupe()
    openMore(app, revealing: "loupeMore.tag")
    element(app, "loupeMore.tag").tap()
    let sheet = app.navigationBars["Add tag"]
    XCTAssertTrue(
      sheet.waitForExistence(timeout: 10), "More › Tag did not present the tag entry sheet.")
    attach(app, name: "loupe-more-tag")
    app.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(
      app.buttons["loupeBack"].waitForExistence(timeout: 10),
      "Cancelling tag entry left the loupe.")
  }

  /// IMGMGR-485: tag entry is hosted by the loupe while it is open and by the grid otherwise
  /// (`TagEntryHost`). Raising and cancelling it from the loupe must leave nothing behind that
  /// re-targets the grid's own Tag: after Back and a DIFFERENT grid focus, the grid's sheet writes
  /// the grid's focused photograph (2), never the loupe's frame (1) — read off the fixture's wire
  /// record of the tag edit, not off a sheet closing.
  func testLoupeTagCancelThenGridTagTargetsTheGridsFocusedPhotograph() throws {
    let app = launchAndOpenLoupe()
    let sheet = app.navigationBars["Add tag"]
    openMore(app, revealing: "loupeMore.tag")
    element(app, "loupeMore.tag").tap()
    XCTAssertTrue(
      sheet.waitForExistence(timeout: 10), "More › Tag did not present the tag entry sheet.")
    app.buttons["Cancel"].firstMatch.tap()
    waitFor("exists == false", sheet)

    let back = app.buttons["loupeBack"]
    waitFor("isHittable == true", back)
    back.tap()
    waitFor("exists == false", back)

    // The grid's focus is the loupe's frame (1); one tap on another tile moves it there.
    let other = element(app, "gridTile-2")
    XCTAssertTrue(other.waitForExistence(timeout: 15), "The grid has no second tile after Back.")
    other.tap()
    let gridTag = app.buttons["gridTagButton"]
    XCTAssertTrue(gridTag.waitForExistence(timeout: 10), "The grid's bar has no Tag.")
    waitFor("isEnabled == true", gridTag)
    gridTag.tap()
    XCTAssertTrue(
      sheet.waitForExistence(timeout: 10), "The grid's Tag did not present the tag entry sheet.")
    attach(app, name: "grid-tag-after-loupe-tag")

    let field = app.textFields["Tag"]
    XCTAssertTrue(field.waitForExistence(timeout: 10), "The tag entry sheet has no Tag field.")
    field.tap()
    field.typeText("wp398")
    let add = app.buttons["Add"].firstMatch
    waitFor("isEnabled == true", add)
    add.tap()

    let probe = element(app, "debugProbe.tagEdits")
    XCTAssertTrue(probe.waitForExistence(timeout: 10), "The fixture publishes no tag-edit probe.")
    waitFor(NSPredicate(format: "value == %@", "tagEdits=add(tag: wp398, imageIDs: [2])"), probe)
    XCTAssertEqual(
      probe.value as? String, "tagEdits=add(tag: wp398, imageIDs: [2])",
      "The grid's tag sheet did not write exactly the grid's focused photograph.")
  }

  /// Lock Pick is the GRID's latch: ✓ on re-open, and after Back the grid's lock row is on.
  func testLockPickRowLatchesTheGridsLock() throws {
    let app = launchAndOpenLoupe()
    openMore(app, revealing: "loupeMore.lockPick")
    let row = element(app, "loupeMore.lockPick")
    XCTAssertFalse(isChecked(row), "Lock Pick reads as checked before anything latched it.")
    row.tap()

    openMore(app, revealing: "loupeMore.lockPick")
    let reopened = element(app, "loupeMore.lockPick")
    attach(app, name: "loupe-more-lock-pick-checked")
    XCTAssertTrue(
      isChecked(reopened),
      "Lock Pick does not read as checked after selecting it (value: "
        + "\(String(describing: reopened.value)), selected: \(reopened.isSelected)).")

    // Dismiss the menu with a tap on an empty stretch of the photograph (a single tap there
    // does nothing of its own), then go Back as a reader would.
    element(app, "loupeImage").coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.9)).tap()
    let back = app.buttons["loupeBack"]
    waitFor("isHittable == true", back)
    back.tap()

    let caption = app.staticTexts["lockModeCaption"]
    XCTAssertTrue(
      caption.waitForExistence(timeout: 15),
      "After Back the grid shows no lock mode row — the loupe's Lock Pick is not the grid latch.")
    XCTAssertTrue(
      caption.label.hasPrefix("Pick Lock"), "The grid's lock row reads '\(caption.label)'.")
    attach(app, name: "grid-after-loupe-lock-pick")
  }

  // MARK: - Context menu

  func testContextMenuShowsExactlyPickDislikeClearTagShareLock() throws {
    let app = launchAndOpenLoupe()
    openContextMenu(app)

    for identifier in Self.contextEntries {
      XCTAssertTrue(
        element(app, identifier).exists, "The photo's context menu lacks `\(identifier)`.")
    }
    let topLevel = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "loupeContext."))
      .allElementsBoundByIndex
      .map { $0.identifier }
      .filter { $0 != "loupeContext.lockPick" && $0 != "loupeContext.lockDislike" }
    XCTAssertEqual(
      Set(topLevel), Set(Self.contextEntries),
      "The context menu's top level is not exactly Pick, Dislike, Clear, Tag, Share, Lock.")
    XCTAssertEqual(topLevel.count, 6, "A context menu entry renders more than once.")
    attach(app, name: "loupe-context-menu")

    // Depth 2: Lock opens its own two rows.
    element(app, "loupeContext.lock").tap()
    XCTAssertTrue(
      element(app, "loupeContext.lockPick").waitForExistence(timeout: 10),
      "Lock ▸ has no Lock Pick row.")
    XCTAssertTrue(element(app, "loupeContext.lockDislike").exists, "Lock ▸ has no Lock Dislike.")
  }

  func testContextMenuDislikeMarksTheFocusedPhotograph() throws {
    let app = launchAndOpenLoupe(arguments: ["-UITestStubNoAutoAdvance"])
    let dislike = app.buttons["loupeDislikeButton"]
    let clear = app.buttons["loupeClearButton"]
    XCTAssertTrue(dislike.waitForExistence(timeout: 10), "The loupe has no Dislike control.")
    if (dislike.value as? String) != "Not disliked" {
      clear.tap()
      waitFor("value == 'Not disliked'", dislike)
    }

    openContextMenu(app)
    element(app, "loupeContext.dislike").tap()
    waitFor("value == 'Disliked'", dislike)
    XCTAssertEqual(
      dislike.value as? String, "Disliked", "Context menu › Dislike did not mark the photograph.")
  }

  // MARK: - Shared

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// Opens the loupe's More through the shared IMGMGR-404 opener.
  private func openMore(
    _ app: XCUIApplication, revealing identifier: String, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let more = element(app, "loupeMoreMenu")
    XCTAssertTrue(
      more.waitForExistence(timeout: 10), "The loupe's bar has no More.", file: file, line: line)
    XCTAssertTrue(
      openPresentation(more, revealing: element(app, identifier), timeout: 15),
      "More did not open with its `\(identifier)` row.", file: file, line: line)
  }

  /// Long-presses the photograph through the same opener, so a lost press is re-tried once.
  private func openContextMenu(_ app: XCUIApplication) {
    let image = element(app, "loupeImage")
    XCTAssertTrue(image.waitForExistence(timeout: 10), "The loupe has no photograph.")
    XCTAssertTrue(
      openPresentation(
        image, revealing: element(app, "loupeContext.pick"), timeout: 20, gesture: .longPress),
      "A long press on the photograph did not open its context menu.")
  }

  /// A menu check row (a `Toggle` inside a `Menu`) states its ✓ as the selected trait or as an
  /// on-value, depending on how the system bridges it; either reading is accepted, and the
  /// caller asserts the unchecked reading first, so an always-true predicate cannot pass.
  private func isChecked(_ row: XCUIElement) -> Bool {
    if row.isSelected { return true }
    let value = (row.value as? String)?.lowercased() ?? ""
    return ["1", "on", "checked", "selected"].contains(value)
  }

  private func driveToUnpicked(_ app: XCUIApplication, pick: XCUIElement) {
    if (pick.value as? String) != "Not picked" {
      app.buttons["loupeClearButton"].tap()
      waitFor("value == 'Not picked'", pick)
    }
  }

  private func waitForShareSheet(_ app: XCUIApplication) -> Bool {
    let ours = app.otherElements["loupeShareSheet"]
    let system = app.otherElements["ActivityListView"]
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline && !(ours.exists || system.exists) {
      Thread.sleep(forTimeInterval: 0.1)
    }
    return ours.exists || system.exists
  }

  private func waitFor(
    _ format: String, _ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) {
    waitFor(NSPredicate(format: format), element, file: file, line: line)
  }

  private func waitFor(
    _ predicate: NSPredicate, _ element: XCUIElement, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let result = XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 10)
    XCTAssertEqual(
      result, .completed, "Timed out waiting for \(predicate.predicateFormat).", file: file,
      line: line)
  }

  /// Launches the stub grid and opens the loupe on the first tile (two taps: the first focuses,
  /// the second opens — `GridStore.tapTile`), addressed by identifier (IMGMGR-336).
  private func launchAndOpenLoupe(arguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"] + arguments
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "The stub grid never rendered its action bar.")
    let back = app.buttons["loupeBack"]
    for _ in 0..<3 where !back.exists {
      let tile = element(app, "gridTile-1")
      guard tile.waitForExistence(timeout: 15) else { break }
      tile.tap()
      _ = back.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(back.exists, "The loupe never opened from a tile tap.")
    return app
  }

  private func attach(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
