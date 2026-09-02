import XCTest

/// WP16 P5 (p3332 decision 2, IMGMGR-296) acceptance: the Folders tree's SHOOT rows carry the
/// drawer-row anatomy the queue cards already have — a cover thumbnail and a count subline —
/// and its CONTAINER rows carry neither, because they are not shoots and have no cover.
///
/// What makes this test a falsifier rather than a description (the plan's item (d)): the
/// thumbnail asserted is the PLACEHOLDER, which the row renders before any image arrives, so the
/// assertion never depends on a network fetch completing inside the gate. A build that skipped
/// the thumbnail entirely fails the presence leg; a build that put a thumbnail on every row
/// fails the absence leg; and the container's own `folderContainer-2` is asserted FIRST as the
/// positive control (LSN-0033), so "the thumbnail was absent" can never be the row itself never
/// having been rendered.
///
/// Runs on BOTH gate destinations and asserts nothing idiom-shaped — the tree is one component
/// on both idioms since P6 (IMGMGR-216).
///
/// Launch fixture: `-UITestStubGrid` (DEBUG-only `DebugStubTransport`, never in a Release
/// archive) plus `-UITestStubSkipAutoSelect`, so the app stops at the home (IMGMGR-350: the tree
/// IS the home, and the tier is Incoming). That fixture's incoming tier is a root shoot
/// `2026-08-27 — Stub Shoot` (id 1, `descendant_image_count` 12) beside the container `2026`
/// (id 2, kind `other`), whose own subtree holds the nested shoots id 3 and 5.
final class FolderTreeRowAnatomyUITests: OrientationPinnedUITestCase {

  func testShootRowsCarryACoverAndSublineAndContainerRowsCarryNeither() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"]
    app.launch()

    let localTier = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(reveal(localTier, in: app), "The Incoming tier branch never appeared.")
    localTier.tap()

    // The shoot row itself first: everything below is an assertion ABOUT this row, so its
    // absence has to be reported as its own failure rather than as a missing thumbnail.
    let shootRow = app.descendants(matching: .any)["folderRow-1"].firstMatch
    XCTAssertTrue(
      reveal(shootRow, in: app),
      "The fixture's root shoot row never appeared under the Incoming tier branch.")

    let cover = app.descendants(matching: .any)["folderRowThumbnail-1"].firstMatch
    XCTAssertTrue(
      cover.waitForExistence(timeout: 10),
      "A shoot row rendered no cover thumbnail. The placeholder is drawn before any image "
        + "arrives, so this is the row's anatomy failing, never a slow fetch (IMGMGR-296).")

    let subline = app.descendants(matching: .any)["folderRowSubline-1"].firstMatch
    XCTAssertTrue(
      subline.waitForExistence(timeout: 10),
      "A shoot row rendered no count subline — decision 2's anatomy is name over count, not a "
        + "trailing number.")
    XCTAssertEqual(
      subline.label, "12 photos",
      "The subline must state the server's own descendant_image_count for this shoot (12), "
        + "never a number the client rolled up itself.")
    attach(named: "P5-tree-shoot-row-cover-and-subline")

    // The container row, and the positive control that it was found at all before its two
    // absences are read as evidence of anything.
    let container = app.descendants(matching: .any)["folderContainer-2"].firstMatch
    XCTAssertTrue(
      reveal(container, in: app),
      "The container row never appeared, so the absences asserted below would prove nothing.")
    XCTAssertFalse(
      app.descendants(matching: .any)["folderRowThumbnail-2"].firstMatch.exists,
      "A container row carries a cover thumbnail. Decision 2 says shoot rows: a container is "
        + "not a shoot and has no cover to show.")
    XCTAssertFalse(
      app.descendants(matching: .any)["folderRowSubline-2"].firstMatch.exists,
      "A container row carries a count subline — containers keep their trailing count, which "
        + "is the layout this phase left alone.")
    attach(named: "P5-tree-container-row-unchanged")
  }

  /// Scrolls the home list until `element` is on screen, in BOTH directions: the search field
  /// sits above the rows, so an up-only scan walks past what it is looking for and never comes
  /// back (observed in gate run 1cfa3f4). Deliberately a copy of the sibling folder-tree tests'
  /// helper rather than a shared extraction — extracting it would edit two shipped UI-test files
  /// this phase is not otherwise touching.
  private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 8) -> Bool {
    if element.waitForExistence(timeout: 15), element.isHittable { return true }
    // SwiftUI's `List` is a collection view; the queue is the first one on both idioms. Falling
    // back to the app itself keeps the helper working if that ever stops being true.
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

  /// Screenshots are retained as XCTAttachments, which land in the run's `.xcresult` bundle under
  /// the gate's own DerivedData — the size suffix distinguishes the iPhone destination's capture
  /// from the iPad's without asking the app anything idiom-shaped.
  private func attach(named name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let size = screenshot.image.size
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(name)-\(Int(size.width))x\(Int(size.height))"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
