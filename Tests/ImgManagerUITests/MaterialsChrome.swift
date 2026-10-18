import XCTest

/// WP28 P4 (IMGMGR-451): the chrome handles the materials suite and the touch-target test share.
/// Each one addresses a control the way the P1-P3 tests established on iOS 26.5: system controls
/// by label (they do not carry the SwiftUI identifier), the app's own controls by identifier.
extension XCTestCase {

  /// Fixture folder 1's names: the tree name, and at Compact also the summary leaf "stub" (see
  /// `InspectorSummaryUITests.folderOneSummaryName` for why Compact can show either).
  static let materialsFolderOneNames = ["2026-08-27 — Stub Shoot", "stub"]

  /// WP29 P1 (IMGMGR-452): every label the grid's title-menu trigger is accepted under, as one
  /// ICU pattern (matched whole by `MATCHES`): one of `names`, then optionally the Regular
  /// breadcrumb's subtitle (for ANY folder's counts, since the system may fold the subtitle into
  /// the trigger's label), then optionally ", Actions Menu" (the iOS 26.5 Compact form). Any
  /// other suffix is not the trigger. No names matches nothing.
  ///
  /// IMGMGR-539 (R3-11): the subtitle is rebuilt from `GridBreadcrumb.subtitle`'s CLOSED
  /// vocabulary, in its order — "N photo(s)", then optionally " · N pick(s)", " · N edited",
  /// " · untouched", " · N mark(s) not in Lightroom" — with grouped digits only. An unknown
  /// segment (an unmarked or dislike count), a reordered one or a malformed number is not the
  /// trigger.
  static func titleMenuLabelPattern(_ names: [String]) -> String {
    guard !names.isEmpty else { return "(?!)" }
    let alternatives = names.map { NSRegularExpression.escapedPattern(for: $0) }
    return "(?:\(alternatives.joined(separator: "|")))(?:, \(titleSubtitlePattern))?"
      + "(?:, Actions Menu)?"
  }

  /// The subtitle group of `titleMenuLabelPattern` (R3-11's closed vocabulary).
  static var titleSubtitlePattern: String {
    let count = "[0-9]{1,3}(?:,[0-9]{3})*"
    return "\(count) photos?(?: · \(count) picks?)?(?: · \(count) edited)?(?: · untouched)?"
      + "(?: · \(count) marks? not in Lightroom)?"
  }

  /// `titleMenuLabelPattern` for a label already read (the census walks snapshots).
  static func isTitleMenuLabel(_ label: String, names: [String]) -> Bool {
    let pattern = "^" + titleMenuLabelPattern(names) + "$"
    return label.range(of: pattern, options: .regularExpression) != nil
  }

  /// The grid's title for a shown folder nobody names yet — the app's `WorkspaceTitle.fallback`
  /// (final audit F1). Spelled here because a UI-test bundle runs out of process and cannot
  /// import the app module.
  static let workspaceFallbackTitle = "Shoot"

  /// The grid view options on the Compact options row. WP29 P1 (IMGMGR-452): at Regular "?"
  /// left the bar — see `regularGridBarIdentifiers`. WP29 P2 (IMGMGR-453): Arrange replaced Sort,
  /// Group and Zoom. IMGMGR-464 (WP32 P2): "?" left the options row too (owner ruling
  /// 2026-10-02).
  static let gridViewOptionIdentifiers = [
    "gridArrangeControl",
    "gridFilterControl",
  ]

  /// The Compact bottom action bar, by identifier (Clear, which folds into More, is not listed).
  static let gridActionBarIdentifiers = [
    "gridPickButton",
    "gridTapToPickToggle",
    "gridDislikeButton",
    "gridUndoButton",
    "gridTagButton",
    "gridMoreMenu",
  ]

  /// WP29 P1 (IMGMGR-452): the Regular grid bar's own app items after Info (the system search
  /// carries no identifier of the app's).
  static let regularGridBarIdentifiers = [
    "gridSelectCommand",
    "gridFilterControl",
    "gridArrangeControl",
    "gridMoreMenu",
  ]

  /// WP29 P1: the Regular bottom action bar — More moved to the grid bar, and Clear never folds
  /// there (`ActionBarMetrics.regularTiers`), so it is listed.
  static let regularActionBarIdentifiers = [
    "gridPickButton",
    "gridTapToPickToggle",
    "gridDislikeButton",
    "gridClearButton",
    "gridUndoButton",
    "gridTagButton",
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
    let pattern = Self.titleMenuLabelPattern(names)
    let button = app.navigationBars.buttons
      .matching(NSPredicate(format: "label MATCHES %@", pattern)).firstMatch
    if button.waitForExistence(timeout: timeout) { return button }
    return app.navigationBars.staticTexts
      .matching(NSPredicate(format: "label MATCHES %@", pattern)).firstMatch
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
