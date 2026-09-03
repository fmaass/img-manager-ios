import XCTest

/// IMGMGR-350 P3 acceptance: a shoot row states the readiness the SERVER served for it, in the
/// same string table the queue sections and the widget use (`ReadinessSection.title`).
///
/// Driven through the production composition against the DEBUG fixture, whose summaries are
/// keyed onto the ids the tree actually renders (P3's fixture renumbering — before it, the join
/// was empty on every row and a suite like this would have proved nothing).
///
/// Runs on BOTH gate destinations and asserts nothing idiom-shaped: the row anatomy is one
/// component on both idioms (WP16 P5).
///
/// Launch fixture: `-UITestStubGrid` plus `-UITestStubSkipAutoSelect`, so the app stops at the
/// home. Incoming's root shoot is id 1, whose summary carries `review_in_progress`; the year
/// container id 2 has no summary and must therefore carry no badge.
final class FolderTreeReadinessBadgeUITests: OrientationPinnedUITestCase {

  func testAShootRowStatesTheServedReadinessAndAContainerStatesNone() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"]
    app.launch()

    let incoming = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(reveal(incoming, in: app), "The Incoming tier branch never appeared.")
    incoming.tap()

    // The row first: every assertion below is about it, so its absence is its own failure.
    let shootRow = app.descendants(matching: .any)["folderRow-1"].firstMatch
    XCTAssertTrue(reveal(shootRow, in: app), "The fixture's root shoot row never appeared.")

    let badge = app.descendants(matching: .any)["folderReadiness-1"].firstMatch
    XCTAssertTrue(
      badge.waitForExistence(timeout: 15),
      "A shoot row carried no readiness badge. The row joins /api/folder-summaries by folder_id "
        + "and renders the served value's title (IMGMGR-350 P3).")
    XCTAssertEqual(
      badge.label, "Review in progress",
      "The badge must say what the SERVER served for this folder (review_in_progress), worded by "
        + "the one string table the queue and the widget share — never a value derived from the "
        + "row's own counts.")
    attach(named: "P3-shoot-row-readiness-badge")

    // The container is the control: it is not a shoot, has no summary, and must carry no badge —
    // asserted after its own row is found, so the absence cannot be an unrendered row.
    let container = app.descendants(matching: .any)["folderContainer-2"].firstMatch
    XCTAssertTrue(reveal(container, in: app), "The container row never appeared.")
    XCTAssertFalse(
      app.descendants(matching: .any)["folderReadiness-2"].firstMatch.exists,
      "A container row carries a readiness badge. Readiness is a SHOOT's state; a folder of "
        + "folders has no summary and none may be invented for it.")
    attach(named: "P3-container-row-has-no-badge")
  }

  /// Scrolls the home list until `element` is on screen, in BOTH directions — the same helper the
  /// sibling folder-tree suites carry, copied rather than extracted for the reason they give.
  private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 8) -> Bool {
    if element.waitForExistence(timeout: 15), element.isHittable { return true }
    let firstList = app.collectionViews.firstMatch
    let scroller: XCUIElement = firstList.exists ? firstList : app
    for _ in 0..<swipes {
      scroller.swipeUp()
      if element.exists, element.isHittable { return true }
    }
    for _ in 0..<(swipes * 2) {
      scroller.swipeDown()
      if element.exists, element.isHittable { return true }
    }
    return element.exists && element.isHittable
  }

  private func attach(named name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let size = screenshot.image.size
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(name)-\(Int(size.width))x\(Int(size.height))"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
