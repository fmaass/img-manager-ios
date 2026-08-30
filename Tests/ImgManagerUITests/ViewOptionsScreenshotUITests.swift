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
  /// evidence existed on Compact at all. This opens the real sheet on whichever destination it
  /// runs on and reads the rows out of the live accessibility tree.
  ///
  /// Blocker 2's other half rides here too: on a destination with no options row — Regular,
  /// i.e. the iPad leg — the sheet is opened by PRESSING ⌘/, which dispatches through
  /// `AppCommands`' own declaration rather than calling the store. A no-op `run` closure on
  /// that declaration fails this test.
  ///
  /// Branches on an OBSERVED element, never on the device idiom: `userInterfaceIdiom` is
  /// grep-banned across `Sources/` AND `Tests/` by the gate (`bin/mac-gate.sh`), and the plan's
  /// invariant (i) is that no test makes an idiom decision.
  func testShortcutHelpSheetListsEveryActiveShortcut() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else (sign-in screen, blank screen, or a "
        + "failed stub composition).")

    let helpControl = app.descendants(matching: .any)["gridShortcutHelpControl"]
    let openedVia: String
    if helpControl.waitForExistence(timeout: 5) {
      // Compact: the options row's own chrome path — the only route into the sheet on a
      // destination with neither a menu bar nor (necessarily) a hardware keyboard.
      helpControl.tap()
      openedVia = "the options row's Keyboard-shortcuts button (Compact chrome path)"
    } else {
      // Regular: no options row exists here, so this is the declared key equivalent itself.
      app.typeKey("/", modifierFlags: .command)
      openedVia = "the ⌘/ key equivalent, dispatched through AppCommands"
    }

    // The sheet's own rendered chrome. NOT an identifier on the sheet container: one set there
    // overrides its descendants' (the `GridOptionsRow` lesson, `GridView.swift`), which would
    // make the rows below unaddressable.
    XCTAssertTrue(
      app.navigationBars["Keyboard shortcuts"].waitForExistence(timeout: 10),
      "The shortcut help sheet never came up after opening it via \(openedVia).")

    // Exactly the ACTIVE catalog, as rendered. Pinned here as literals because a UI test cannot
    // see the app's types; `ShortcutHelpSheetTests.everyRowCarriesItsRenderedIdentifier` binds
    // this same list to `ShortcutCatalog.activeEntries`, so a catalog change breaks one of the
    // two loudly rather than silently drifting.
    let expected: Set<String> = [
      "shortcutHelpRow.arrowUp", "shortcutHelpRow.arrowDown", "shortcutHelpRow.arrowLeft",
      "shortcutHelpRow.arrowRight", "shortcutHelpRow.openSpaceEnter", "shortcutHelpRow.pick",
      "shortcutHelpRow.dislike", "shortcutHelpRow.clear", "shortcutHelpRow.shiftAdvance",
      "shortcutHelpRow.tag", "shortcutHelpRow.undo", "shortcutHelpRow.help",
      "shortcutHelpRow.zoomStep", "shortcutHelpRow.sceneToggle", "shortcutHelpRow.groupMode",
    ]

    // A `List` only materializes what it has laid out, so the rows are collected across scrolls
    // rather than read once — the count assertion below is about the SHEET, not about how much
    // of it happens to fit on this destination's screen.
    let rowQuery = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "shortcutHelpRow."))
    var rendered: [String: String] = [:]
    var passesWithoutANewRow = 0
    var scrolls = 0
    while scrolls < 10 && passesWithoutANewRow < 2 && rendered.count < expected.count {
      let before = rendered.count
      for row in rowQuery.allElementsBoundByIndex {
        // A row can surface twice — the cell and the combined element inside it — and only one
        // of the two carries the text. Keep the richer label rather than whichever came last.
        let label = row.label
        if label.count >= (rendered[row.identifier]?.count ?? 0) {
          rendered[row.identifier] = label
        }
      }
      passesWithoutANewRow = rendered.count == before ? passesWithoutANewRow + 1 : 0
      if rendered.count < expected.count {
        app.swipeUp()
        scrolls += 1
      }
    }

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "shortcut-help-sheet"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertEqual(
      Set(rendered.keys), expected,
      "The rendered help sheet is not the active catalog. Opened via \(openedVia); found "
        + "\(rendered.count) rows: \(rendered.keys.sorted()).")

    // The rows a reader came for, asserted on the RENDERED text rather than on the model that
    // produced it: the ⌘ discovery half is the whole point of the sheet.
    for (identifier, key) in [
      ("shortcutHelpRow.help", "? or ⌘/"),
      ("shortcutHelpRow.zoomStep", "⌘1 … ⌘6"),
      ("shortcutHelpRow.sceneToggle", "⌘⇧G"),
      ("shortcutHelpRow.groupMode", "⌃⌘1 · ⌃⌘2"),
    ] {
      let label = rendered[identifier] ?? ""
      XCTAssertTrue(
        label.contains(key),
        "Rendered row \(identifier) reads '\(label)' — it does not show its key '\(key)'.")
    }

    XCTContext.runActivity(
      named: "Opened via \(openedVia) · \(rendered.count) rendered rows · captured "
        + "\(screenshot.image.size)"
    ) { _ in }
  }
}
