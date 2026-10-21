import UIKit
import XCTest

/// WP28 P2 (IMGMGR-449) acceptance (AC3): the Regular shell's sidebar and grid bar.
///
/// (a) IMGMGR-549 (R3-2): the sidebar is Untouched · Pinned · Recent · Library — the Untouched
///     header above its rows, "Library" below them and above the tree's tier rows, and no
///     standing "Shoots" header (ruling a);
/// (b) nothing in the app is a navigation rail (no identifier or label contains "rail");
/// (c) removed by R3-18 (IMGMGR-550) with the toolbar search itself; its absence is
///     `GridToolbarUITests.testTheRegularShellCarriesNoSearch`;
/// (d) moved to `GridToolbarUITests` by WP29 P1 (IMGMGR-452): the six named bar screenshots and
///     the collapsed all-hittable contract now ride the bar's own acceptance tests, beside the
///     order, cluster and title assertions the new bar adds.
/// (e) IMGMGR-478: a sidebar hidden with the system toggle has a visible way back on the GRID's
///     bar (`regularSidebarToggle`, "Show Sidebar"), and the choice survives a kill + relaunch in
///     both directions, at Regular-3 and at Regular-2. The iPhone destination is Compact, where
///     the same two tests assert the toggle is never built — they do not skip, so the
///     destination's skip count is unchanged.
///
/// Layouts are reached the way `Regular3CollapsedChromeUITests` reaches them: landscape and the
/// app's measured window width against the resolver's pin for Regular-3, portrait for Regular-2.
/// No device-idiom test: the iPhone destination is Compact in both orientations, and every test
/// here records that and returns rather than asserting a layout the device cannot resolve.
///
/// Launch fixture: `-UITestStubGrid` (DEBUG-only `DebugStubTransport`); with
/// `-UITestStubSkipAutoSelect` the app stops at the home. Its Untouched members are folders 23, 5
/// and 3, newest first; the Incoming tier holds folder 1 beside the `2026` container (id 2).
final class RegularSidebarShellUITests: OrientationPinnedUITestCase {

  /// LANDSCAPE: Regular-3, which most of this file is about. The Regular-2 test turns the device
  /// to portrait itself; the base returns it to portrait after every test either way.
  override class var pinnedOrientation: UIDeviceOrientation { .landscapeLeft }

  /// Mirrors `LayoutResolver.regular3Threshold` (joined by
  /// `LayoutPresentationTests.theRegular3WidthPinMatchesTheUITestLiteral`).
  private static let regular3WidthThreshold: CGFloat = 1197

  // MARK: - (a) Untouched above Library

  func testTheSidebarListsUntouchedAboveLibraryAndLibraryAboveTheTiers() throws {
    let app = try launched(.regular3, home: true)

    let untouched = app.descendants(matching: .any)["untouchedSection"].firstMatch
    let library = app.descendants(matching: .any)["sidebarSectionLibrary"].firstMatch
    XCTAssertTrue(
      untouched.waitForExistence(timeout: 15), "The sidebar has no \"Untouched\" section header.")
    XCTAssertEqual(untouched.label, "Untouched")
    XCTAssertTrue(
      library.waitForExistence(timeout: 15),
      "The sidebar has no \"Library\" section header (board iPad-Library-v2).")
    XCTAssertEqual(library.label, "Library")

    let members = [23, 5, 3].map { folderID in
      app.descendants(matching: .any)["untouchedRow-\(folderID)"].firstMatch
    }
    for (index, row) in members.enumerated() {
      XCTAssertTrue(row.exists, "Untouched member #\(index + 1) has no row in the sidebar.")
    }
    for tier in ["Incoming", "Edits", "Archive"] {
      XCTAssertTrue(
        app.descendants(matching: .any)["folderTreeTier-\(tier)"].firstMatch.exists,
        "The \(tier) tier row is not in the sidebar under Library.")
    }
    // Ruling a: no standing "Shoots" header — asserted after the headers above were found.
    XCTAssertFalse(
      app.descendants(matching: .any)["sidebarSectionShoots"].firstMatch.exists,
      "The sidebar still carries the standing \"Shoots\" header.")

    // Order, top to bottom: the Untouched header and rows, Library, the tiers.
    let firstTier = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertLessThan(
      untouched.frame.minY, members[0].frame.minY, "\"Untouched\" does not sit above its rows.")
    XCTAssertLessThan(
      members[2].frame.minY, library.frame.minY,
      "\"Library\" does not sit below the Untouched rows.")
    XCTAssertLessThan(
      library.frame.minY, firstTier.frame.minY, "\"Library\" does not sit above the tier rows.")
    attach(named: "IMGMGR-549-sidebar-untouched-library")
  }

  // MARK: - (b) No rail

  func testNoElementIsANavigationRail() throws {
    let app = try launched(.regular3)
    // Positive control: the sidebar and the grid are really on screen, so a zero below is a
    // statement about the rendered app rather than about a blank one.
    let tierRow = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(
      tierRow.waitForExistence(timeout: 15),
      "Positive control failed: the sidebar's tier row is not on screen.")
    assertNoRailElement(in: app, context: "Regular-3 collapsed")
  }

  // MARK: - (e) The hidden sidebar's way back

  func testRegular3HiddenSidebarComesBackFromTheGridBarAndSurvivesARelaunch() {
    assertHiddenSidebarRoundTrip(.regular3)
  }

  func testRegular2HiddenSidebarComesBackFromTheGridBarAndSurvivesARelaunch() {
    assertHiddenSidebarRoundTrip(.regular2)
  }

  /// Launch 1 (the fixture forgets any remembered state): shown, and no grid-bar toggle → hide
  /// with the system toggle → the grid bar's toggle is there, labelled "Show Sidebar" → it brings
  /// the sidebar back → hide again. Launch 2 (`-UITestKeepSidebarMemory`): still hidden, the
  /// toggle restores it. Launch 3 (keeping memory): shown — the restore was remembered too, and
  /// the simulator is left on the shown sidebar every other suite expects.
  private func assertHiddenSidebarRoundTrip(_ layout: Layout) {
    let tag = layout == .regular3 ? "r3" : "r2"
    var app = launchForSidebarMemory(layout, keepMemory: false)
    guard resolvesForSidebarMemory(layout, app) else {
      assertCompactHasNoSidebarToggle(app)
      return
    }

    XCTAssertTrue(
      waitForSidebar(shown: true, in: app),
      "\(tag): the sidebar is not shown on a fresh fixture launch.")
    XCTAssertFalse(
      gridBarSidebarToggle(app).exists,
      "\(tag): the grid bar carries a sidebar toggle while the sidebar shows — the system toggle "
        + "is on the sidebar's own bar, so this one would duplicate it.")

    hideWithSystemToggle(in: app, tag: tag)
    assertGridBarToggleRestores(in: app, tag: "\(tag) launch 1")
    hideWithSystemToggle(in: app, tag: tag)
    XCTAssertTrue(
      gridBarSidebarToggle(app).waitForExistence(timeout: 10),
      "\(tag): the grid bar's toggle did not come back when the sidebar was hidden again.")
    attach(named: "IMGMGR-478-\(tag)-hidden")

    // Let the flag's write settle before the kill, then relaunch on the same storage.
    Thread.sleep(forTimeInterval: 1.0)
    app.terminate()
    app = launchForSidebarMemory(layout, keepMemory: true)
    XCTAssertTrue(
      waitForSidebar(shown: false, in: app),
      "\(tag): the sidebar hidden before the relaunch came back SHOWN — the choice was not "
        + "remembered.")
    attach(named: "IMGMGR-478-\(tag)-relaunched-hidden")
    assertGridBarToggleRestores(in: app, tag: "\(tag) launch 2")

    Thread.sleep(forTimeInterval: 1.0)
    app.terminate()
    app = launchForSidebarMemory(layout, keepMemory: true)
    XCTAssertTrue(
      waitForSidebar(shown: true, in: app),
      "\(tag): the sidebar restored before the relaunch came back HIDDEN.")
    XCTAssertFalse(
      gridBarSidebarToggle(app).exists,
      "\(tag): the grid bar's toggle is on the bar after a relaunch with the sidebar shown.")
  }

  /// The toggle is on the GRID's bar, labelled "Show Sidebar", hittable, and brings the sidebar
  /// back — after which it leaves the bar.
  private func assertGridBarToggleRestores(in app: XCUIApplication, tag: String) {
    let toggle = gridBarSidebarToggle(app)
    guard toggle.waitForExistence(timeout: 10) else {
      XCTFail(
        "\(tag): the sidebar is hidden and the grid's bar carries no sidebar toggle — the owner's "
          + "report on build 20 (IMGMGR-478). Bar buttons: \(barButtonNames(in: app))")
      return
    }
    XCTAssertEqual(toggle.label, "Show Sidebar", "\(tag): the toggle does not say what it does.")
    XCTAssertTrue(toggle.isHittable, "\(tag): the grid bar's sidebar toggle is not hittable.")
    let info = gridInfoControl(app)
    let center = CGPoint(x: toggle.frame.midX, y: toggle.frame.midY)
    let bar = app.navigationBars.allElementsBoundByIndex.first { $0.frame.contains(center) }
    XCTAssertNotNil(bar, "\(tag): the sidebar toggle sits on no navigation bar.")
    if let bar, info.exists {
      XCTAssertTrue(
        bar.frame.contains(CGPoint(x: info.frame.midX, y: info.frame.midY)),
        "\(tag): the sidebar toggle is not on the grid's bar (the one carrying Info).")
      XCTAssertLessThan(
        toggle.frame.minX, info.frame.minX,
        "\(tag): the sidebar toggle is not in the bar's leading slot, ahead of Info.")
    }
    let system = app.buttons.matching(identifier: "ToggleSidebar").firstMatch
    print(
      "IMGMGR-478-SYSTEM-TOGGLE \(tag): exists=\(system.exists) "
        + "hittable=\(system.exists && system.isHittable) toggle=\(toggle.frame)")

    toggle.tap()
    XCTAssertTrue(
      waitForSidebar(shown: true, in: app),
      "\(tag): the grid bar's \"Show Sidebar\" did not bring the sidebar back.")
    XCTAssertTrue(
      toggle.waitForNonExistence(timeout: 10),
      "\(tag): the grid bar's toggle stayed on the bar with the sidebar shown.")
  }

  /// "Hide via the top-left toggle": the system's own control (`ToggleSidebar`, the identifier
  /// `ChromeCensus` also knows it by), falling back to its label for an OS that drops the id. The
  /// HITTABLE match, since the system may keep a second, off-screen copy for the other state.
  private func hideWithSystemToggle(in app: XCUIApplication, tag: String) {
    let predicate = NSPredicate(
      format: "identifier == 'ToggleSidebar' OR (label == 'Hide Sidebar' AND identifier != %@)",
      Self.sidebarToggleIdentifier)
    let matches = app.buttons.matching(predicate)
    _ = matches.firstMatch.waitForExistence(timeout: 10)
    let candidates = matches.allElementsBoundByIndex
    guard let system = candidates.first(where: { candidate in candidate.isHittable }) else {
      XCTFail(
        "\(tag): no hittable system sidebar toggle to hide the sidebar with. Bar buttons: "
          + barButtonNames(in: app))
      return
    }
    system.tap()
    XCTAssertTrue(
      waitForSidebar(shown: false, in: app),
      "\(tag): the system toggle did not hide the sidebar.")
  }

  /// The Library header, the one sidebar header that renders whatever the sections hold, stands
  /// for the column: shown means on screen and hittable. Polled, because the column animates.
  private func waitForSidebar(shown: Bool, in app: XCUIApplication) -> Bool {
    let header = app.descendants(matching: .any)["sidebarSectionLibrary"].firstMatch
    let deadline = Date().addingTimeInterval(10)
    repeat {
      let onScreen = header.exists && header.isHittable && header.frame.minX >= 0
      if onScreen == shown { return true }
      Thread.sleep(forTimeInterval: 0.5)
    } while Date() < deadline
    return false
  }

  private static let sidebarToggleIdentifier = "regularSidebarToggle"

  private func gridBarSidebarToggle(_ app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(identifier: Self.sidebarToggleIdentifier).firstMatch
  }

  private func barButtonNames(in app: XCUIApplication) -> String {
    let buttons = app.navigationBars.buttons.allElementsBoundByIndex
    return buttons.map { button in
      button.identifier.isEmpty ? button.label : "\(button.identifier)(\(button.label))"
    }.joined(separator: ", ")
  }

  /// The fixture launch for (e). Launch 1 omits `-UITestKeepSidebarMemory`, so the app forgets
  /// whatever an earlier test left (`DebugStubLaunch.resetSidebarMemoryUnlessKept`); the
  /// relaunches pass it, so they read what the launch before them stored.
  private func launchForSidebarMemory(_ layout: Layout, keepMemory: Bool) -> XCUIApplication {
    let orientation: UIDeviceOrientation = layout == .regular2 ? .portrait : .landscapeLeft
    XCUIDevice.shared.orientation = orientation
    var arguments = ["-UITestStubGrid"]
    if keepMemory { arguments.append("-UITestKeepSidebarMemory") }
    let app = XCUIApplication()
    app.launchArguments = arguments
    app.launch()
    XCUIDevice.shared.orientation = orientation
    _ = app.windows.firstMatch.waitForExistence(timeout: 30)
    Thread.sleep(forTimeInterval: 2.0)
    return app
  }

  /// `launched(_:)`'s layout gate, as a verdict rather than a skip.
  private func resolvesForSidebarMemory(_ layout: Layout, _ app: XCUIApplication) -> Bool {
    let width = app.frame.size.width
    let resolves: Bool
    switch layout {
    case .regular3:
      resolves = width >= Self.regular3WidthThreshold
    case .regular2:
      resolves = width < Self.regular3WidthThreshold && width >= Self.compactShellWidthCeiling
    }
    guard resolves else { return false }
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "The DEBUG fixture composition never rendered (sign-in, blank, or a failed stub).")
    Thread.sleep(forTimeInterval: 1.0)
    return true
  }

  /// Not the layout under test (the iPhone destination, Compact in both orientations): the tab
  /// shell must be what renders — the positive control, read off the screen, never the idiom —
  /// and no grid-bar sidebar toggle is ever built there
  /// (`SidebarVisibilityMemory.showsGridBarToggle`). `rendersCompactShell` is not the check: its
  /// width ceiling is a portrait one, and the Regular-3 test runs in landscape.
  private func assertCompactHasNoSidebarToggle(_ app: XCUIApplication) {
    print("IMGMGR-478 window=\(app.frame.size): not Regular here; asserting Compact instead.")
    XCTAssertTrue(
      app.tabBars.firstMatch.waitForExistence(timeout: 30),
      "IMGMGR-478 window=\(app.frame.size) resolves to neither the Regular layout under test nor "
        + "the Compact tab shell.")
    XCTAssertFalse(gridBarSidebarToggle(app).exists, "Compact carries the sidebar toggle.")
  }

  // MARK: - Helpers

  private enum Layout {
    case regular2
    case regular3
  }

  /// The fixture launch plus the layout gate. Throws `XCTSkip`, with the measured window, when the
  /// window does not resolve to `layout` on this destination (the iPhone is Compact in both
  /// orientations), so a destination without the layout reads as skipped, never as passed.
  /// `home` stops the app at the home (`-UITestStubSkipAutoSelect`); `inspectorShown` launches
  /// Regular-3 expanded (`-UITestInspectorShown`).
  private func launched(
    _ layout: Layout, home: Bool = false, inspectorShown: Bool = false
  ) throws -> XCUIApplication {
    let orientation: UIDeviceOrientation = layout == .regular2 ? .portrait : .landscapeLeft
    XCUIDevice.shared.orientation = orientation
    var arguments = ["-UITestStubGrid"]
    if home { arguments.append("-UITestStubSkipAutoSelect") }
    if inspectorShown { arguments.append("-UITestInspectorShown") }
    let app = XCUIApplication()
    app.launchArguments = arguments
    app.launch()
    // Again after launch — the sequence known to take on these destinations
    // (`RegularThreeScreenshotUITests`).
    XCUIDevice.shared.orientation = orientation

    // The layout gate FIRST: on the iPhone destination the tree is not on the launch tab, so a
    // readiness wait for it would fail there instead of recording that the layout is absent.
    _ = app.windows.firstMatch.waitForExistence(timeout: 30)
    // The rotation's layout pass, then the resolver's `.onGeometryChange` reaction to it.
    Thread.sleep(forTimeInterval: 2.0)
    let width = app.frame.size.width
    let resolves: Bool
    switch layout {
    case .regular3:
      resolves = width >= Self.regular3WidthThreshold
    case .regular2:
      // Below the Regular-3 pin and above the Compact tab shell (`CompactTabs.swift`).
      resolves = width < Self.regular3WidthThreshold && width >= Self.compactShellWidthCeiling
    }
    guard resolves else {
      throw XCTSkip("IMGMGR-449 window=\(app.frame.size) does not resolve to \(layout) here.")
    }

    let ready: XCUIElement
    if home {
      ready = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    } else {
      ready = app.buttons["Dislike"]
    }
    XCTAssertTrue(
      ready.waitForExistence(timeout: 30),
      "The DEBUG fixture composition never rendered (sign-in, blank, or a failed stub).")
    // The bar settles after the content that fills the pane under it.
    Thread.sleep(forTimeInterval: 1.0)
    return app
  }

  private func assertNoRailElement(in app: XCUIApplication, context: String) {
    let rail = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier CONTAINS[c] 'rail' OR label CONTAINS[c] 'rail'"))
    let count = rail.count
    if count > 0 {
      print("IMGMGR-449-RAIL \(context): \(rail.allElementsBoundByIndex.map(\.debugDescription))")
    }
    XCTAssertEqual(count, 0, "\(context): an element names itself a rail (p4128 draws none).")
  }

  private func attach(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
