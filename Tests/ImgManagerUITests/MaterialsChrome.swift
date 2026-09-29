import XCTest

/// WP28 P4 (IMGMGR-451): the chrome handles the materials suite and the touch-target test share.
/// Each one addresses a control the way the P1-P3 tests established on iOS 26.5: system controls
/// by label (they do not carry the SwiftUI identifier), the app's own controls by identifier.
extension XCTestCase {

  /// Fixture folder 1's names: the tree name, and at Compact also the summary leaf "stub" (see
  /// `InspectorSummaryUITests.folderOneSummaryName` for why Compact can show either).
  static let materialsFolderOneNames = ["2026-08-27 — Stub Shoot", "stub"]

  /// The grid's title for a shown folder nobody names yet — the app's `WorkspaceTitle.fallback`
  /// (final audit F1). Spelled here because a UI-test bundle runs out of process and cannot
  /// import the app module.
  static let workspaceFallbackTitle = "Shoot"

  /// The five grid view options, on the Compact options row or the Regular grid bar.
  static let gridViewOptionIdentifiers = [
    "gridFilterControl",
    "gridSortControl",
    "gridGroupControl",
    "gridZoomControl",
    "gridShortcutHelpControl",
  ]

  /// The bottom action bar, by identifier (Clear, which folds into More, is not listed).
  static let gridActionBarIdentifiers = [
    "gridPickButton",
    "gridDislikeButton",
    "gridUndoButton",
    "gridTagButton",
    "gridMoreMenu",
  ]

  func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  /// Info on the grid's bar, by identifier OR label ("Info", or "Info, 1 filter active").
  func gridInfoControl(_ app: XCUIApplication) -> XCUIElement {
    app.navigationBars.buttons
      .matching(
        NSPredicate(format: "identifier == 'inspectorChromeButton' OR label BEGINSWITH 'Info'")
      )
      .firstMatch
  }

  /// The grid's title-menu trigger, matched by its exact label: the title itself at Regular,
  /// "<title>, Actions Menu" on the iOS 26.5 Compact bar (P3, gate on 0d2d057). A button first,
  /// then static text — the first query that finds one within `timeout` wins.
  func gridTitleMenuTrigger(
    _ app: XCUIApplication, names: [String], timeout: TimeInterval = 15
  ) -> XCUIElement {
    let labels = names.flatMap { [$0, "\($0), Actions Menu"] }
    let button = app.navigationBars.buttons
      .matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    if button.waitForExistence(timeout: timeout) { return button }
    return app.navigationBars.staticTexts
      .matching(NSPredicate(format: "label IN %@", labels)).firstMatch
  }

  /// The title menu's "Shoot Summary" row.
  func shootSummaryMenuRow(_ app: XCUIApplication) -> XCUIElement {
    app.buttons
      .matching(
        NSPredicate(format: "identifier == 'shootSummaryTitleMenuRow' OR label == 'Shoot Summary'")
      )
      .firstMatch
  }
}
