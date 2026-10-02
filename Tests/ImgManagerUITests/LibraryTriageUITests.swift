import XCTest

/// WP31 P3 (IMGMGR-462) acceptance: on the iPhone the Library tab reaches Triage in at most two
/// taps — the shoot row, then `gridTriageButton` (plan AC 3).
///
/// The walk starts from the tree's REAL launch state: `-UITestStubGrid` plus
/// `-UITestStubSkipAutoSelect` (the launch `CompactTabShellUITests` uses), so nothing is
/// auto-opened and no fixture pre-expands a row. Every tap after the tab selection is counted,
/// including any the tree would need to show the row. Before IMGMGR-462 every tier launched
/// closed, so the fixture's root shoot (`folderRow-1`, the Incoming tier's root-level
/// `2026-08-27 — Stub Shoot`) was not on screen until the tier was tapped — three taps, and this
/// test failed at the row's absence. The product now opens Incoming at Compact
/// (`FolderTreeState.applyCompactLaunchOpening`), and Triage sits in the grid's Compact options
/// row, where a long title cannot push it into the navigation bar's overflow.
///
/// Compact only: at Regular the tree is the split's sidebar and Triage has no entry (the iPad
/// culls in the loupe), so the test skips there with that reason.
final class LibraryTriageUITests: OrientationPinnedUITestCase {

  func testTheLibraryTabReachesTriageInTwoTaps() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"]
    app.launch()
    guard rendersCompactShell(app) else {
      throw XCTSkip("Regular width: the Library tab and Triage are Compact-only.")
    }
    selectCompactTab(app, title: CompactTabTitle.library)

    // Every tap from here on goes through this, so the count is the walk's, not a claim.
    var taps = 0
    func tap(_ target: XCUIElement) {
      taps += 1
      target.tap()
    }

    // (1) The shoot row, as the Library tab shows it at launch: present AND tappable with no
    // tier tap and no scroll in between.
    let shootRow = element(app, "folderRow-1")
    XCTAssertTrue(
      shootRow.waitForExistence(timeout: 30),
      "The fixture's root shoot (folderRow-1) is not on the Library tab at launch — the Incoming "
        + "tier opened closed, so reaching the shoot costs a tier tap first (IMGMGR-462).")
    XCTAssertTrue(
      shootRow.isHittable, "The fixture's root shoot is in the tree but not tappable at launch.")
    attach(named: "IMGMGR-462-library-at-launch")
    tap(shootRow)

    // (2) The grid's Triage entry (IMGMGR-460), on the grid the row pushed — in the Compact
    // options row since IMGMGR-462. This grid is titled by the tree's long name ("2026-08-27 —
    // Stub Shoot"), the title that pushed a bar-hosted Triage into the bar's "More" overflow,
    // so the entry must be hittable as it stands: no overflow opened, no tap spent.
    let entry = app.descendants(matching: .any)["gridTriageButton"].firstMatch
    XCTAssertTrue(
      entry.waitForExistence(timeout: 30),
      "The shoot row did not reach a grid carrying 'gridTriageButton'.")
    XCTAssertTrue(waitFor("isEnabled == true", entry), "Triage is disabled on a populated grid.")
    XCTAssertTrue(
      entry.isHittable,
      "'gridTriageButton' is not hittable on the long-titled Library grid without opening the "
        + "bar's \"More\" overflow.")
    tap(entry)

    XCTAssertTrue(
      element(app, "triagePick").waitForExistence(timeout: 15),
      "Triage did not open from the Library tab's grid (no 'triagePick').")
    attach(named: "IMGMGR-462-triage-reached")
    XCTAssertLessThanOrEqual(
      taps, 2, "Library → Triage took \(taps) taps after the tab selection; AC 3 allows 2.")
  }

  // MARK: - Shared

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func waitFor(_ format: String, _ element: XCUIElement, timeout: TimeInterval = 10)
    -> Bool
  {
    let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
    return XCTWaiter.wait(for: [done], timeout: timeout) == .completed
  }

  private func attach(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
