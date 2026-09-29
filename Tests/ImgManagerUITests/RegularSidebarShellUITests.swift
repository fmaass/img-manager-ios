import UIKit
import XCTest

/// WP28 P2 (IMGMGR-449) acceptance (AC3): the Regular shell's sidebar, toolbar search and grid
/// bar.
///
/// (a) the sidebar names two sections — "Shoots" above the pinned Needs-review rows, "Library"
///     above the tree's tier rows;
/// (b) nothing in the app is a navigation rail (no identifier or label contains "rail");
/// (c) the toolbar search is a button that expands to a field, and typing filters the tree;
/// (d) moved to `GridToolbarUITests` by WP29 P1 (IMGMGR-452): the six named bar screenshots and
///     the collapsed all-hittable contract now ride the bar's own acceptance tests, beside the
///     order, cluster and title assertions the new bar adds.
///
/// Layouts are reached the way `Regular3CollapsedChromeUITests` reaches them: landscape and the
/// app's measured window width against the resolver's pin for Regular-3, portrait for Regular-2.
/// No device-idiom test: the iPhone destination is Compact in both orientations, and every test
/// here records that and returns rather than asserting a layout the device cannot resolve.
///
/// Launch fixture: `-UITestStubGrid` (DEBUG-only `DebugStubTransport`); with
/// `-UITestStubSkipAutoSelect` the app stops at the home. Its Needs-review members are folders 1
/// and 21; the Incoming tier holds folder 1 beside the `2026` container (id 2) over
/// `2026-09-14 — Wandern` (id 3).
final class RegularSidebarShellUITests: OrientationPinnedUITestCase {

  /// LANDSCAPE: Regular-3, which most of this file is about. The Regular-2 test turns the device
  /// to portrait itself; the base returns it to portrait after every test either way.
  override class var pinnedOrientation: UIDeviceOrientation { .landscapeLeft }

  /// Mirrors `LayoutResolver.regular3Threshold` (joined by
  /// `LayoutPresentationTests.theRegular3WidthPinMatchesTheUITestLiteral`).
  private static let regular3WidthThreshold: CGFloat = 1197

  // MARK: - (a) Shoots and Library

  func testTheSidebarNamesShootsAboveNeedsReviewAndLibraryAboveTheTiers() throws {
    let app = try launched(.regular3, home: true)

    let shoots = app.descendants(matching: .any)["sidebarSectionShoots"].firstMatch
    let library = app.descendants(matching: .any)["sidebarSectionLibrary"].firstMatch
    XCTAssertTrue(
      shoots.waitForExistence(timeout: 15),
      "The sidebar has no \"Shoots\" section header (board iPad-Library-v2).")
    XCTAssertEqual(shoots.label, "Shoots")
    XCTAssertTrue(
      library.waitForExistence(timeout: 15),
      "The sidebar has no \"Library\" section header (board iPad-Library-v2).")
    XCTAssertEqual(library.label, "Library")

    let needsReview = app.descendants(matching: .any)["needsReviewSection"].firstMatch
    XCTAssertTrue(needsReview.exists, "The pinned Needs-review section is gone from the sidebar.")
    for folderID in [1, 21] {
      XCTAssertTrue(
        app.descendants(matching: .any)["needsReviewRow-\(folderID)"].firstMatch.exists,
        "Needs-review member \(folderID) has no row under Shoots.")
    }
    for tier in ["Incoming", "Edits", "Archive"] {
      XCTAssertTrue(
        app.descendants(matching: .any)["folderTreeTier-\(tier)"].firstMatch.exists,
        "The \(tier) tier row is not in the sidebar under Library.")
    }

    // Order, top to bottom: Shoots, the Needs-review header and rows, Library, the tiers.
    let lastMember = app.descendants(matching: .any)["needsReviewRow-21"].firstMatch
    let firstTier = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertLessThan(
      shoots.frame.minY, needsReview.frame.minY,
      "\"Shoots\" does not sit above the Needs-review header.")
    XCTAssertLessThan(
      lastMember.frame.minY, library.frame.minY,
      "\"Library\" does not sit below the Needs-review rows.")
    XCTAssertLessThan(
      library.frame.minY, firstTier.frame.minY, "\"Library\" does not sit above the tier rows.")
    attach(named: "IMGMGR-449-sidebar-shoots-library")
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

  // MARK: - (c) Toolbar search

  func testTheToolbarSearchExpandsToAFieldAndTypingFiltersTheTree() throws {
    let app = try launched(.regular3, home: true)

    // The inline field is gone: the toolbar search is the one search surface at Regular.
    XCTAssertFalse(
      app.textFields["folderTreeSearchField"].exists,
      "The tree still renders its inline search field beside the toolbar search.")
    // Positive control for the filter below: the row it must remove is there before it runs.
    let tier = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(tier.waitForExistence(timeout: 15), "The Incoming tier never appeared.")
    let rootShoot = app.descendants(matching: .any)["folderRow-1"].firstMatch
    if !rootShoot.exists { tier.tap() }
    XCTAssertTrue(
      rootShoot.waitForExistence(timeout: 10),
      "Positive control failed: Incoming's root shoot (folder 1) is not in the tree.")

    guard let field = expandRegularToolbarSearch(app, context: "Regular-3 collapsed (c)") else {
      XCTFail(
        "The toolbar search did not expand to a field: no hittable Search button and no search "
          + "field took a tap (`RootView.regularShell`).")
      return
    }

    // No return: submitting unfocuses the minimised field (see `clearFocusedSearchField`).
    field.typeText("zzzz-no-such-folder")
    let noMatches = app.descendants(matching: .any)["folderTreeNoMatches"].firstMatch
    XCTAssertTrue(
      noMatches.waitForExistence(timeout: 10),
      "A search matching nothing produced no empty state — the sidebar tree is not filtered by "
        + "the toolbar search.")

    clearFocusedSearchField(field)
    XCTAssertTrue(searchFieldIsCleared(field), "The no-match term was not cleared.")
    field.typeText("wandern")
    XCTAssertTrue(
      rootShoot.waitForNonExistence(timeout: 10),
      "A shoot whose name does not contain the term stayed in the tree.")
    let match = app.descendants(matching: .any)["folderRow-3"].firstMatch
    XCTAssertTrue(
      match.waitForExistence(timeout: 10), "The matching shoot is not in the filtered tree.")
    attach(named: "IMGMGR-449-toolbar-search-filters-tree")
  }

  // MARK: - The docked loupe keeps its chrome

  /// The toolbar search rides the GRID's bar, never the docked loupe's (the loupe chrome is out of
  /// P2's scope): absent while the loupe is docked in the grid's place, back once it closes.
  func testTheToolbarSearchIsAbsentOverTheDockedLoupeAndBackAfterIt() throws {
    let app = try launched(.regular3)
    let search = regularToolbarSearchButton(app)
    XCTAssertTrue(
      search.waitForExistence(timeout: 10),
      "Positive control failed: the grid's bar carries no toolbar search before the loupe opens.")

    let close = app.buttons["loupeClose"]
    let tile = app.descendants(matching: .any).matching(identifier: "gridTile-1").firstMatch
    XCTAssertTrue(tile.waitForExistence(timeout: 15), "The fixture's first tile never appeared.")
    // `GridStore.tapTile`: a tap on an unfocused tile moves focus, a tap on the focused one opens.
    for _ in 0..<3 where !close.exists {
      tile.tap()
      _ = close.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(close.exists, "Tapping gridTile-1 never opened the docked loupe.")
    XCTAssertFalse(search.exists, "A toolbar search control shows over the docked loupe.")
    XCTAssertFalse(
      app.searchFields.firstMatch.exists, "A search field shows over the docked loupe.")
    attach(named: "IMGMGR-449-docked-loupe-no-search")

    close.tap()
    XCTAssertTrue(
      close.waitForNonExistence(timeout: 10), "The docked loupe did not close from loupeClose.")
    XCTAssertTrue(
      search.waitForExistence(timeout: 10),
      "The toolbar search did not come back on the grid's bar after the loupe closed.")
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
