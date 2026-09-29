import XCTest

/// WP29 P1 (IMGMGR-452): the commands P1 moved, at the width that keeps the options row.
///
/// - Select is a NAVIGATION-BAR item (beside Info at Compact, in the trailing group at Regular)
///   and enters Select mode.
/// - More rides the bottom action bar at Compact — its only Compact home, at rest and in Select —
///   and the grid's toolbar at Regular.
/// - The options row's "?" opens the shortcut help sheet. The sheet's content check moved here
///   from `ViewOptionsScreenshotUITests` (TRANSFERRED): at Regular "?" has left the bar, so a
///   Regular destination asserts the removal instead.
///
/// Every test reads the width off the window (never the idiom) and asserts that width's own
/// contract, so no destination skips.
final class CompactSelectUITests: OrientationPinnedUITestCase {

  private func launchedGrid() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "The DEBUG fixture composition never rendered (sign-in, blank, or a failed stub).")
    Thread.sleep(forTimeInterval: 1.0)
    return app
  }

  func testTheNavigationBarSelectEntersSelectMode() {
    let app = launchedGrid()
    let width = rendersCompactShell(app) ? "compact" : "regular"
    let select = app.navigationBars.descendants(matching: .any)["gridSelectCommand"].firstMatch
    XCTAssertTrue(
      select.waitForExistence(timeout: 15),
      "\(width): no 'gridSelectCommand' on the navigation bar.")
    let caption = app.staticTexts["selectModeCaption"]
    XCTAssertFalse(caption.exists, "\(width): the grid launched in Select mode.")
    XCTAssertTrue(
      openPresentation(select, revealing: caption, timeout: 15),
      "\(width): the navigation bar's Select did not enter Select mode.")
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "select-from-nav-bar-\(width)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testMoreRidesTheBottomBarAtCompactAndTheToolbarAtRegular() {
    let app = launchedGrid()
    let compact = rendersCompactShell(app)
    let onNavigationBar = app.navigationBars.descendants(matching: .any)["gridMoreMenu"]
      .firstMatch.exists
    XCTAssertEqual(
      onNavigationBar, !compact,
      compact
        ? "More left the bottom action bar at Compact, its only Compact home."
        : "More is not on the grid's toolbar at Regular.")
    let copyRow = app.descendants(matching: .any)["gridMoreMenu.more.copyForLightroom"]
    XCTAssertTrue(
      openMoreMenu(in: app, revealing: copyRow, timeout: 15),
      "More did not open (\(compact ? "compact" : "regular")).")
    if compact {
      // In Select, too: at Compact More stays on the bottom bar (plan Decision 2).
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).tap()
      _ = copyRow.waitForNonExistence(timeout: 5)
      let select = app.navigationBars.descendants(matching: .any)["gridSelectCommand"].firstMatch
      let caption = app.staticTexts["selectModeCaption"]
      XCTAssertTrue(
        openPresentation(select, revealing: caption, timeout: 15),
        "Select did not enter Select mode.")
      let more = app.descendants(matching: .any)["gridMoreMenu"].firstMatch
      XCTAssertTrue(more.isHittable, "More is not on the bottom bar in Select at Compact.")
      XCTAssertFalse(
        app.navigationBars.descendants(matching: .any)["gridMoreMenu"].firstMatch.exists,
        "More moved onto the navigation bar in Select at Compact.")
    }
  }

  /// Diff-gate r1 blocker 3: the help sheet's only test compared the catalog-derived model
  /// against the catalog itself, so an EMPTY `ShortcutHelpSheet` body passed and no rendered
  /// evidence existed on either layout. This opens the real sheet and reads its rows back out
  /// of the live accessibility tree.
  ///
  /// EXACTLY the active catalog, from ONE source: the sheet publishes
  /// `ShortcutCatalog.activeEntries.count` in its header, every element whose identifier starts
  /// with `shortcutHelpRow.` is harvested (never a hand-written list), and the two numbers must
  /// be equal — so an extra rendered row fails as surely as a missing one. The delta-gate
  /// finding this replaces was a 15-entry literal inventory here that asserted only presence.
  ///
  /// HOW IT OPENS THE SHEET, and why: the render assertions go through the CHROME control,
  /// which both layouts carry (Compact's options row, Regular's `.primaryAction` toolbar).
  /// Pressing ⌘/ is attempted first but only LOGGED, never asserted — the queue-p4-green2 gate
  /// run showed the key equivalent never reaches the app on the iPad simulator, which has no
  /// attached hardware keyboard, and a UI test cannot open the system menu bar either. The
  /// proof that the ⌘/ and `?` declarations actually dispatch is
  /// `GridViewOptionsTests.helpDeclarationsDispatchThroughTheirOwnRunClosures`, which invokes
  /// each declaration's own `run` closure; this test's job is the RENDERED sheet.
  ///
  /// Makes no device-idiom decision (plan invariant (i)): every step keys off an observed
  /// element, never off which kind of device this destination happens to be.
  func testShortcutHelpSheetListsEveryActiveShortcut() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else (sign-in screen, blank screen, or a "
        + "failed stub composition).")

    let helpBar = app.navigationBars["Keyboard shortcuts"]
    app.typeKey("/", modifierFlags: .command)
    let openedByKeyEquivalent = helpBar.waitForExistence(timeout: 5)
    if !openedByKeyEquivalent {
      let helpControl = app.descendants(matching: .any)["gridShortcutHelpControl"]
      // WP29 P1 (IMGMGR-452, plan Decision 1): "?" left the REGULAR bar. Its homes there are ⌘/
      // and the menu bar's "Keyboard Shortcuts", neither drivable on the iPad simulator, and
      // their declarations are unit-proven (`GridViewOptionsTests`, `ShellToolbarLayoutTests`).
      // What a Regular destination CAN prove is the removal: no second touch home.
      guard rendersCompactShell(app) else {
        XCTAssertEqual(
          app.descendants(matching: .any).matching(identifier: "gridShortcutHelpControl").count,
          0,
          "The Regular bar still carries 'gridShortcutHelpControl' — \"?\" has one touch home "
            + "per width, and at Regular that is the menu bar.")
        return
      }
      XCTAssertTrue(
        helpControl.waitForExistence(timeout: 10),
        "Neither route into the shortcut help sheet exists at Compact: ⌘/ did not reach the app "
          + "and nothing named 'gridShortcutHelpControl' is on the options row.")
      helpControl.tap()
    }
    let openedVia = openedByKeyEquivalent ? "the ⌘/ key equivalent" : "the chrome control"

    // The sheet's own rendered chrome. NOT an identifier on the sheet container: one set there
    // overrides its descendants' (the `GridOptionsRow` lesson, `GridView.swift`), which would
    // make the rows below unaddressable.
    XCTAssertTrue(
      helpBar.waitForExistence(timeout: 10),
      "The shortcut help sheet never came up after opening it via \(openedVia).")

    let opened = XCUIScreen.main.screenshot()
    let openedAttachment = XCTAttachment(screenshot: opened)
    openedAttachment.name = "shortcut-help-sheet"
    openedAttachment.lifetime = .keepAlways
    add(openedAttachment)

    // HOW MANY rows there should be comes from the APP, not from a list copied into this file:
    // the sheet's header publishes `ShortcutCatalog.activeEntries.count`, read off the catalog
    // itself rather than off the rows the body renders. So a row the sheet invents, a row it
    // drops, and a catalog entry that never reaches the screen all break the equality below,
    // and this test holds no second inventory that could drift.
    //
    // The other half of "exactly the active catalog" is closed in the unit suite, which CAN see
    // the types: `ShortcutHelpSheetTests.listsExactlyTheActiveCatalogEntries` pins model ==
    // catalog and `…everyRowCarriesItsRenderedIdentifier` pins the identifier scheme and its
    // uniqueness. Rendered == published count, model == catalog, identifiers unique — with no
    // literal copy of the inventory anywhere.
    let counter = app.descendants(matching: .any)["shortcutHelpRowCount"]
    XCTAssertTrue(
      counter.waitForExistence(timeout: 10),
      "The sheet does not publish its active-shortcut count (nothing named "
        + "'shortcutHelpRowCount'), so 'exactly the active catalog' cannot be checked.")
    let published = (counter.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? counter.label
    guard let expectedCount = Int(published.filter { $0.isNumber }), expectedCount > 0 else {
      XCTFail("The sheet's row counter published '\(published)', which is not a positive count.")
      return
    }

    // A `List` only materialises the rows it has laid out, so the sheet is TRAVERSED and every
    // row read while it happens to be on screen — never "scroll until row N appears", which is
    // what the 20:50 gate run caught: one momentum drag carried `dislike` and `clear` past the
    // viewport, and a per-row search that has already overshot can only burn its budget moving
    // further away from them.
    //
    // Each step is a press-drag BETWEEN TWO POINTS INSIDE A ROW, never a view-level
    // `swipeUp`/`swipeDown`: on a presented sheet those act as grabber drags and close it, which
    // is what the 21:14 run hit (by the reverse pass the sheet's collection view was gone). The
    // drag is slow and ends in a hold, so it stops where it is put instead of coasting.
    let rowQuery = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "shortcutHelpRow."))
    var rendered: [String: String] = [:]
    func harvestVisibleRows() {
      for row in rowQuery.allElementsBoundByIndex {
        let text = self.renderedText(of: row)
        if text.count >= (rendered[row.identifier]?.count ?? 0) {
          rendered[row.identifier] = text
        }
      }
    }
    // WP13 P5b: anchor on the MIDDLE hittable row and drag a modest distance, so BOTH ends of
    // the gesture stay inside the list on either destination. The two edge anchors were each
    // tried and each failed on one device only, which is what identifies this as gesture
    // geometry rather than list content: anchoring on the FIRST row and dragging 220 pt up put
    // the endpoint behind the navigation bar and stalled both legs at 15 of 17 rows (run
    // 03:19); anchoring on the LAST row instead fixed the phone (17/17) and froze the iPad
    // completely at its initial 11 (run 04:00). A middle anchor is ~300 pt from either edge of
    // a form sheet's list, so ±150 pt cannot leave the scroll view on either.
    func dragInsideARow(by dy: CGFloat) -> Bool {
      let hittable = rowQuery.allElementsBoundByIndex.filter { $0.isHittable }
      guard !hittable.isEmpty else { return false }
      let anchor = hittable[hittable.count / 2]
      let start = anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      start.press(
        forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)),
        withVelocity: .slow, thenHoldForDuration: 0.2)
      return true
    }

    // The traverse ends when the sheet's own count has been accounted for, or when three
    // consecutive steps turn up nothing new — the end of the list. Either way the equality
    // below is what decides the test; stopping early simply fails it with the shortfall named.
    harvestVisibleRows()
    var forwardSteps = 0
    var barrenSteps = 0
    while forwardSteps < 30 && rendered.count < expectedCount && barrenSteps < 3 {
      let before = rendered.count
      guard dragInsideARow(by: -150) else { break }
      forwardSteps += 1
      guard helpBar.exists else {
        return XCTFail(
          "The traverse dismissed the sheet: it was gone after \(forwardSteps) forward "
            + "steps, with \(rendered.count) of \(expectedCount) rows collected.")
      }
      harvestVisibleRows()
      barrenSteps = rendered.count == before ? barrenSteps + 1 : 0
    }

    // Only if the forward pass actually skipped something — on a destination that renders the
    // whole sheet at once neither loop runs at all.
    var reverseSteps = 0
    barrenSteps = 0
    while reverseSteps < 30 && rendered.count < expectedCount && barrenSteps < 3 {
      let before = rendered.count
      guard dragInsideARow(by: 150) else { break }
      reverseSteps += 1
      guard helpBar.exists else {
        return XCTFail(
          "The traverse dismissed the sheet on the way back: gone after \(reverseSteps) "
            + "reverse steps, with \(rendered.count) of \(expectedCount) rows collected.")
      }
      harvestVisibleRows()
      barrenSteps = rendered.count == before ? barrenSteps + 1 : 0
    }

    let end = XCUIScreen.main.screenshot()
    let endAttachment = XCTAttachment(screenshot: end)
    endAttachment.name = "shortcut-help-sheet-scrolled"
    endAttachment.lifetime = .keepAlways
    add(endAttachment)

    // EXACT, not "at least": the rendered rows are counted against the number the sheet itself
    // publishes from the catalog, so an extra row fails here just as loudly as a missing one.
    XCTAssertEqual(
      rendered.count, expectedCount,
      "The sheet rendered \(rendered.count) distinct rows but publishes \(expectedCount) active "
        + "shortcuts. Opened via \(openedVia); traversed \(forwardSteps) forward and "
        + "\(reverseSteps) back; found: \(rendered.keys.sorted()).")

    // The rows a reader came for, asserted on the RENDERED text rather than on the model that
    // produced it: the ⌘ discovery half is the whole point of the sheet.
    for (identifier, key) in [
      ("shortcutHelpRow.help", "? or ⌘/"),
      ("shortcutHelpRow.zoomStep", "⌘1 … ⌘6"),
      ("shortcutHelpRow.sceneToggle", "⌘⇧G"),
      ("shortcutHelpRow.groupMode", "⌃⌘1 · ⌃⌘2"),
    ] {
      let text = rendered[identifier] ?? ""
      XCTAssertTrue(
        text.contains(key),
        "Rendered row \(identifier) reads '\(text)' — it does not show its key '\(key)'.")
    }

    XCTContext.runActivity(
      named: "Opened via \(openedVia) · ⌘/ reached the app: \(openedByKeyEquivalent) · "
        + "\(rendered.count) rendered rows in \(forwardSteps)+\(reverseSteps) steps · captured "
        + "\(opened.image.size)"
    ) { _ in }
  }

  /// Everything the row element can tell us about its own text: an accessibility element that
  /// merely COMBINES its children can come back with an empty `label` (it did on both legs of
  /// the queue-p4-green2 run), so the value and the element's own static texts are read too.
  private func renderedText(of element: XCUIElement) -> String {
    var parts = [element.label, (element.value as? String) ?? ""]
    for text in element.staticTexts.allElementsBoundByIndex {
      parts.append(text.label)
    }
    return parts.joined(separator: " ")
  }
}
