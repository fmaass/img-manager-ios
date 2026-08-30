import XCTest

/// WP13 P4 (IMGMGR-215) acceptance, on the real thing: the ticket's own AC is "primary-surface
/// controls for group/scene and zoom on BOTH idioms". The falsifiable form of that is —
/// the two controls are reachable and hittable WITHOUT opening any overflow menu, whatever
/// layout this destination resolves to. Before this phase they were
/// `ToolbarItem(placement: .secondaryAction)`, i.e. reachable only after tapping the nav bar's
/// `OverflowBarButtonItem` (verified live on the iPhone 17 Pro simulator, 2026-08-30 — see
/// `.phase-ledger.md`), so this test was RED for the right reason before the change and is
/// GREEN only because the controls moved out of the overflow.
///
/// Deliberately makes NO device-idiom decision (plan invariant (i)): it asserts the same thing
/// on both destinations and lets the layout put the controls wherever that layout puts them —
/// Compact's options row or Regular's `.primaryAction` toolbar.
final class ViewOptionsScreenshotUITests: XCTestCase {

  func testGroupAndZoomAreOnAPrimarySurface() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else (sign-in screen, blank screen, or a "
        + "failed stub composition).")

    let group = app.descendants(matching: .any)["gridGroupControl"]
    let zoom = app.descendants(matching: .any)["gridZoomControl"]

    XCTAssertTrue(
      group.waitForExistence(timeout: 10),
      "The Group control is not on a primary surface — nothing named 'gridGroupControl' is in "
        + "the hierarchy without opening an overflow menu.")
    XCTAssertTrue(
      zoom.waitForExistence(timeout: 10),
      "The Zoom control is not on a primary surface — nothing named 'gridZoomControl' is in "
        + "the hierarchy without opening an overflow menu.")
    XCTAssertTrue(group.isHittable, "The Group control exists but cannot be tapped where it is.")
    XCTAssertTrue(zoom.isHittable, "The Zoom control exists but cannot be tapped where it is.")

    // The other half of "primary surface": the toolbar overflow chevron that used to hide these
    // two is gone. `OverflowBarButtonItem` is the identifier UIKit gives that chevron — it is
    // exactly what the pre-change probe found on Compact, with "Group"/"Zoom" reachable only
    // after tapping it. Paired with a positive control in the same check (LSN-0033), and the
    // control is the action bar's Dislike button rather than the nav bar's Info button: Info is
    // only rendered outside Regular-3 (`RootView.contentColumn`), so on a Regular-3 destination
    // it is legitimately absent and would fail as a control while proving nothing.
    XCTAssertTrue(
      app.buttons["Dislike"].exists,
      "Positive control failed: the Dislike button is gone, so the 0-hit overflow check below "
        + "would pass vacuously.")
    XCTAssertFalse(
      app.buttons["OverflowBarButtonItem"].exists,
      "A toolbar overflow chevron is still present — something is back in `.secondaryAction`, "
        + "which is exactly where these two controls could not be found.")

    // Value-in-label: the state must be readable WITHOUT opening anything. Both controls are
    // menus, so their rendered label is what a reader sees at rest.
    XCTAssertTrue(
      group.label.contains("Group:"),
      "Group control label '\(group.label)' does not carry its current value.")
    XCTAssertTrue(
      zoom.label.contains("Zoom:"),
      "Zoom control label '\(zoom.label)' does not carry its current value.")

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "view-options-primary-surface"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTContext.runActivity(
      named: "Group label: '\(group.label)' · Zoom label: '\(zoom.label)' · captured "
        + "\(screenshot.image.size)"
    ) { _ in }
  }

  /// Diff-gate r1 blocker 3: the help sheet's only test compared the catalog-derived model
  /// against the catalog itself, so an EMPTY `ShortcutHelpSheet` body passed and no rendered
  /// evidence existed on either layout. This opens the real sheet and reads its rows back out
  /// of the live accessibility tree.
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
      XCTAssertTrue(
        helpControl.waitForExistence(timeout: 10),
        "Neither route into the shortcut help sheet exists on this destination: ⌘/ did not "
          + "reach the app and nothing named 'gridShortcutHelpControl' is on a primary surface.")
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

    // Exactly the ACTIVE catalog, in the order it renders. Pinned here as literals because a UI
    // test cannot see the app's types; the `everyRowCarriesItsRenderedIdentifier` test in
    // `ShortcutHelpSheetTests` binds this same list to `ShortcutCatalog.activeEntries`, so a
    // catalog change breaks one of the two loudly rather than drifting silently.
    let expected = [
      "shortcutHelpRow.arrowUp", "shortcutHelpRow.arrowDown", "shortcutHelpRow.arrowLeft",
      "shortcutHelpRow.arrowRight", "shortcutHelpRow.openSpaceEnter", "shortcutHelpRow.pick",
      "shortcutHelpRow.dislike", "shortcutHelpRow.clear", "shortcutHelpRow.shiftAdvance",
      "shortcutHelpRow.tag", "shortcutHelpRow.undo", "shortcutHelpRow.help",
      "shortcutHelpRow.zoomStep", "shortcutHelpRow.sceneToggle", "shortcutHelpRow.groupMode",
    ]

    // A `List` only materialises the rows it has laid out, so the sheet is TRAVERSED and every
    // row read while it happens to be on screen — never "scroll until row N appears", which is
    // what the 20:50 gate run caught: one momentum swipe carried `dislike` and `clear` past the
    // viewport, and a per-row search that has already overshot can only burn its budget going
    // further down (13 of 15 found, the two skipped ones stranded above). Slow swipes to keep
    // each step short, a harvest between every one of them, and a second pass back UP for
    // anything the downward pass still flew over.
    let scroller: XCUIElement
    if app.collectionViews.firstMatch.exists {
      scroller = app.collectionViews.firstMatch
    } else if app.tables.firstMatch.exists {
      scroller = app.tables.firstMatch
    } else {
      scroller = app
    }
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

    guard let lastRow = expected.last else {
      XCTFail("The expected-row list is empty — nothing to traverse to.")
      return
    }
    harvestVisibleRows()
    var downSwipes = 0
    while downSwipes < 20 && (rendered[lastRow] == nil || rendered.count < expected.count) {
      scroller.swipeUp(velocity: .slow)
      downSwipes += 1
      harvestVisibleRows()
    }
    // The end of the sheet was reached — that is what makes "found N of 15" a statement about
    // the SHEET rather than about how far the scroll happened to get.
    XCTAssertNotNil(
      rendered[lastRow],
      "The traverse never reached the sheet's last row (\(lastRow)) in \(downSwipes) swipes; "
        + "found \(rendered.count) of \(expected.count): \(rendered.keys.sorted()).")

    var upSwipes = 0
    while upSwipes < 20 && rendered.count < expected.count {
      scroller.swipeDown(velocity: .slow)
      upSwipes += 1
      harvestVisibleRows()
    }
    let missing = expected.filter { rendered[$0] == nil }

    let end = XCUIScreen.main.screenshot()
    let endAttachment = XCTAttachment(screenshot: end)
    endAttachment.name = "shortcut-help-sheet-scrolled"
    endAttachment.lifetime = .keepAlways
    add(endAttachment)

    XCTAssertEqual(
      missing, [],
      "Rows the sheet never rendered, in a traverse that DID reach its last row. Opened via "
        + "\(openedVia); found \(rendered.count) of \(expected.count) in \(downSwipes) swipes "
        + "down and \(upSwipes) back up.")

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
        + "\(rendered.count) rendered rows in \(downSwipes)+\(upSwipes) swipes · captured "
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
