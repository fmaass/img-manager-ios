import XCTest

/// IMGMGR-509: reaching the Compact options row (`GridOptionsRow`) and the controls INSIDE it.
///
/// The row is an accessibility container with its own identifier (`.contain` first, then
/// `gridOptionsRow` — the IMGMGR-280 order), so its controls keep their identifiers and a query
/// can be scoped to it. Scoping is the point: a control found app-wide would still pass if it
/// moved to the navigation bar or into the bar's "More" overflow, which is exactly the
/// regression IMGMGR-462 moved Triage into the row to end.
extension XCTestCase {
  static var optionsRowIdentifier: String { "gridOptionsRow" }

  /// The row's controls as `ShellToolbarLayout.compactOptionsRow` declares them, in order —
  /// Arrange, the funnel, Triage (IMGMGR-464 removed the trailing "?").
  static var optionsRowControlIdentifiers: [String] {
    ["gridArrangeControl", "gridFilterControl", "gridTriageButton"]
  }

  func optionsRow(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)[Self.optionsRowIdentifier].firstMatch
  }

  /// `identifier`, looked up inside the options row only.
  func optionsRowControl(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    optionsRow(app).descendants(matching: .any)[identifier].firstMatch
  }

  /// The way into Triage, inside the options row (IMGMGR-462) — what every Triage UI test taps.
  func gridTriageEntry(_ app: XCUIApplication) -> XCUIElement {
    optionsRowControl(app, "gridTriageButton")
  }
}
