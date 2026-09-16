import Foundation
import XCTest

/// WP13 P5a (IMGMGR-221) acceptance, on the real thing: the More menu's decided set is RENDERED,
/// and the two entries a wrong implementation would leave inert actually change the screen.
///
/// The unit suite proves the declarations dispatch (`GridViewMoreMenuTests`); this proves the
/// menu a reader opens contains those declarations and that pressing them does something
/// visible. Both matter — a correct table that the body never renders is exactly the failure
/// mode the P4 diff gate caught in the help sheet.
///
/// Makes NO device-idiom decision (plan invariant (i)): every step keys off an observed element,
/// and it asserts the same things on the phone and the iPad destination.
final class GridMoreMenuUITests: OrientationPinnedUITestCase {

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else (sign-in screen, blank screen, or a "
        + "failed stub composition).")
    return app
  }

  /// How many elements on screen carry `title` as their own words, counted the two ways the
  /// accessibility tree can expose a menu section header — as static text and as an element
  /// whose identifier defaults to its label. Either is proof the header rendered; a header that
  /// SwiftUI dropped is 0 both ways.
  private func headerCount(_ title: String, in app: XCUIApplication) -> Int {
    let byLabel = app.staticTexts.matching(NSPredicate(format: "label == %@", title)).count
    let byIdentifier = app.descendants(matching: .any).matching(identifier: title).count
    return byLabel + byIdentifier
  }

  /// A plate element, however the accessibility tree happens to expose it: as its own element
  /// with the shipped identifier, or — if SwiftUI folded it into the tile — as the filename's
  /// own static text. Either is proof the plate rendered; neither existing is proof it did not.
  private func platesAreVisible(in app: XCUIApplication) -> Bool {
    let byIdentifier = app.descendants(matching: .any)
      .matching(identifier: "tileFilenamePlate").count
    return byIdentifier > 0 || app.staticTexts["STUB_0001.jpg"].exists
  }

  func testMoreMenuShowsTheDecidedSet() throws {
    let app = launchedApp()
    // Read BEFORE presenting: the More control publishes which `ActionBarMetrics` tier
    // `ViewThatFits` actually chose, so this test states the width fact instead of inferring it.
    let tier = (app.descendants(matching: .any)["gridMoreMenu"].value as? String) ?? ""
    let folded = tier.contains("folded")

    // EXACTLY the decided set, read off the rendered menu by the identifiers the entries ship
    // with. "Download…" is deliberately absent (owner decision 3) and is asserted absent with
    // the five present entries above it as the positive control.
    let expected = [
      "gridSelectCommand", "gridMoreMenu.more.copyForLightroom",
      "gridMoreMenu.more.filenamePlates",
      // IMGMGR-261: the picks-in-groups switch lives in THIS menu — the app's existing
      // view-options surface — and never in a settings panel of its own.
      "gridMoreMenu.more.picksInGroups", "gridMoreMenu.more.density",
      "gridMoreMenu.more.status",
      // WP13 P11 (IMGMGR-220): the multi-window entry point, rendered on BOTH idioms and in
      // every case — the built-product probe decided only whether project.yml needed the
      // capability key, never whether the affordance exists.
      "gridMoreMenu.more.openInNewWindow",
    ]
    // The open itself (IMGMGR-404): the first declared entry is what says the menu presented at
    // all, so it is waited for through the shared opener; the loop below is unchanged.
    XCTAssertTrue(
      openMoreMenu(in: app, revealing: app.descendants(matching: .any)[expected[0]], timeout: 5),
      "The More menu does not render '\(expected[0])'.")
    for identifier in expected {
      let entry = app.descendants(matching: .any)[identifier]
      XCTAssertTrue(
        entry.waitForExistence(timeout: 5),
        "The More menu does not render '\(identifier)'.")
    }

    // The Clear row's IDENTITY depends on whether this column folded the bar's Clear into the
    // menu (WP13 P1) — a width fact, so the test READS the tier off P1's own fixture probe (the
    // More control stamps `tier=<name>` into its accessibility value under -UITestStubGrid)
    // rather than assuming a surface.
    //
    // The first version of this check compared "a `gridMoreMenu.more.clearMark` exists" against
    // "a `gridClearButton` exists" app-wide and required exactly one — which FAILED on the
    // 01:24 gate run reporting `menu-clear=true, folded-clear=true`. That was the assertion
    // being wrong, not the app: unfolded, `gridClearButton` is the BAR's Clear control, which is
    // still in the hierarchy behind the presented menu. The invariant that actually matters is
    // below, and it holds on both sides of the fold.
    let clearButtons = app.descendants(matching: .any).matching(identifier: "gridClearButton")
    XCTAssertEqual(
      clearButtons.count, 1,
      "Exactly one 'gridClearButton' may exist at a time — the BAR's when the bar is wide "
        + "enough, the MENU row's when it folds, never both (tier=\(tier)).")

    let menuClearExists = app.descendants(matching: .any)["gridMoreMenu.more.clearMark"].exists
    XCTAssertEqual(
      menuClearExists, !folded,
      "The menu's own Clear row must be present exactly when the bar did NOT fold its Clear "
        + "into the menu (tier=\(tier), folded=\(folded), menu-clear=\(menuClearExists)).")

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "more-menu-open"
    attachment.lifetime = .keepAlways
    add(attachment)

    let downloadEntries = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS[c] %@", "download")).count
    XCTAssertEqual(
      downloadEntries, 0,
      "The More menu offers a download entry — decision 3 keeps downloads loupe-Share-only.")

    XCTContext.runActivity(
      named: "More menu rendered \(expected.count) declared entries · captured "
        + "\(screenshot.image.size)"
    ) { _ in }
  }

  func testFilenamePlatesToggleOnAndOff() throws {
    let app = launchedApp()

    XCTAssertFalse(
      platesAreVisible(in: app), "Filename plates are on before anything turned them on.")
    let before = XCUIScreen.main.screenshot()
    let beforeAttachment = XCTAttachment(screenshot: before)
    beforeAttachment.name = "filename-plates-off"
    beforeAttachment.lifetime = .keepAlways
    add(beforeAttachment)

    let toggle = app.descendants(matching: .any)["gridMoreMenu.more.filenamePlates"]
    XCTAssertTrue(
      openMoreMenu(in: app, revealing: toggle, timeout: 5),
      "No Filename plates entry in the menu.")
    toggle.tap()

    // Positive control in the same check: the grid is still there, so "plates visible" below is
    // about the plates and not about an empty screen.
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 10),
      "Positive control failed: the grid is gone after toggling the plates.")
    var appeared = false
    for _ in 0..<20 where !appeared {
      appeared = platesAreVisible(in: app)
      if !appeared { Thread.sleep(forTimeInterval: 0.25) }
    }
    XCTAssertTrue(
      appeared, "Turning Filename plates ON did not put any filename on a tile.")

    let on = XCUIScreen.main.screenshot()
    let onAttachment = XCTAttachment(screenshot: on)
    onAttachment.name = "filename-plates-on"
    onAttachment.lifetime = .keepAlways
    add(onAttachment)

    let toggleAgain = app.descendants(matching: .any)["gridMoreMenu.more.filenamePlates"]
    XCTAssertTrue(openMoreMenu(in: app, revealing: toggleAgain, timeout: 5))
    toggleAgain.tap()
    XCTAssertTrue(app.buttons["Dislike"].waitForExistence(timeout: 10))
    var gone = false
    for _ in 0..<20 where !gone {
      gone = !platesAreVisible(in: app)
      if !gone { Thread.sleep(forTimeInterval: 0.25) }
    }
    XCTAssertTrue(gone, "Turning Filename plates OFF left them on the tiles.")

    XCTContext.runActivity(named: "Plates toggled on and back off · captured \(on.image.size)") {
      _ in
    }
  }

  func testStatusSheetIsReadOnly() throws {
    let app = launchedApp()

    let statusEntry = app.descendants(matching: .any)["gridMoreMenu.more.status"]
    XCTAssertTrue(
      openMoreMenu(in: app, revealing: statusEntry, timeout: 5), "No Status entry in the menu.")
    statusEntry.tap()

    let statusBar = app.navigationBars["Status"]
    XCTAssertTrue(
      statusBar.waitForExistence(timeout: 15), "The Status sheet never came up.")

    // Positive control for the 0-hit assertions below: the sheet really did render its rows.
    let localRow = app.descendants(matching: .any)["statusRow.store.local"]
    XCTAssertTrue(
      localRow.waitForExistence(timeout: 10),
      "The Status sheet rendered no store row, so the 'no mutating control' checks below would "
        + "pass vacuously.")

    for verb in ["Reindex", "Re-index", "Run now", "Start"] {
      XCTAssertFalse(
        app.buttons[verb].exists,
        "The Status sheet offers a '\(verb)' control — it is a read-only surface.")
    }

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "status-sheet"
    attachment.lifetime = .keepAlways
    add(attachment)

    // Every rendered clock names its zone (estate ADR-0007). Read off the sheet, not the model.
    let zoneRows = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "Europe/Zurich")).count
    XCTAssertGreaterThan(
      zoneRows, 0, "No rendered timestamp on the Status sheet names its time zone.")

    app.buttons["Done"].tap()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 10), "Done did not close the sheet.")

    XCTContext.runActivity(
      named: "Status sheet read-only · \(zoneRows) zone-labelled elements · captured "
        + "\(screenshot.image.size)"
    ) { _ in }
  }

  /// WP16 P4 (IMGMGR-297, p3332 decision 3): the eleven decided entries read as LABELLED groups.
  /// The unit suite proves the partition and that `entries` is derived from it
  /// (`GridMoreMenuSectionsTests`); this proves the labels reach the menu a reader opens, which a
  /// correct declaration the body never renders would not.
  ///
  /// "Marks" is asserted rather than any of the four because it is the one section title that is
  /// not a word this app already puts on screen ("Scene" is a grouping row title,
  /// `GridView.rowTitle(for:)`), so the before/after pair below attributes the hit to THIS menu.
  ///
  /// If SwiftUI presents a `Menu`'s `Section` headers headerless on an idiom, this fails there.
  /// That failure is the phase's declared-deviation pivot (plan §Phase 4 "Known unknown"), to be
  /// named in the report and ticketed — never relaxed here, and never faked with a disabled row.
  func testMoreMenuGroupsItsEntriesUnderSectionHeaders() throws {
    let app = launchedApp()
    let header = "Marks"

    XCTAssertEqual(
      headerCount(header, in: app), 0,
      "'\(header)' is already on screen before the More menu opened, so the hit below would not "
        + "be attributable to the menu's own section header.")

    // Positive control for the header assertion: the menu really did present its rows, so a
    // headerless result below is about the HEADERS and not about a menu that never opened.
    let known = app.descendants(matching: .any)["gridMoreMenu.more.status"]
    XCTAssertTrue(
      openMoreMenu(in: app, revealing: known, timeout: 5),
      "The More menu did not present its Status row, so the section-header check would be "
        + "vacuous.")

    let observed = ["Marks", "View", "Shoot", "Scene"]
      .map { "\($0)=\(headerCount($0, in: app))" }
      .joined(separator: ", ")
    XCTAssertGreaterThan(
      headerCount(header, in: app), 0,
      "The opened More menu renders no '\(header)' section header (observed: \(observed)). "
        + "SwiftUI presented the sections headerless on this idiom — the phase's declared "
        + "deviation, not a test to relax.")

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "more-menu-sections"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTContext.runActivity(
      named: "More menu section headers · \(observed) · captured \(screenshot.image.size)"
    ) { _ in }
  }
}
