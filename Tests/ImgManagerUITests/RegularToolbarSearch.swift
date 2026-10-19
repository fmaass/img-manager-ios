import XCTest

/// WP28 P2 (IMGMGR-449) shipped a Regular toolbar search; R3-18 (IMGMGR-550) removed it. What is
/// left is the one query its absence is asserted with (`GridToolbarUITests`) and the census
/// prints that still record it (`Regular3CollapsedChromeUITests`, `InspectorSummaryUITests`). The
/// system button carried no app identifier, so it is addressed by its label.
extension XCTestCase {

  /// Any button labelled or identified "Search" — the minimised toolbar search while it existed.
  func regularToolbarSearchButton(_ app: XCUIApplication) -> XCUIElement {
    app.buttons
      .matching(NSPredicate(format: "label ==[c] 'Search' OR identifier ==[c] 'Search'"))
      .firstMatch
  }
}
