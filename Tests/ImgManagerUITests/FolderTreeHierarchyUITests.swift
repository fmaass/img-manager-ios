import XCTest

/// P7 (IMGMGR-217) acceptance, driven through the PRODUCTION composition rather than an extracted
/// helper — the same discipline P6's browse test was rebuilt around (its diff-gate round 1,
/// blocker 2). `FolderTreeModelTests` pins the pure decisions; only this one mounts the sidebar,
/// opens a CONTAINER that is not itself a shoot, reaches a shoot two levels down, filters the
/// tree from the search field and taps through to the grid.
///
/// Nothing here can pass against the pre-P7 flat list: that list rendered shoot leaves only, so
/// no container row, no nested row and no expand control existed to find, and there was no search
/// field at all.
///
/// Runs on BOTH gate destinations and asserts nothing idiom-shaped — the iPad run is the
/// Regular-3 evidence, the iPhone run the Compact evidence, and the retained attachments are the
/// phase's screenshots.
///
/// Launch fixture: `-UITestStubGrid` (DEBUG-only `DebugStubTransport`, never in a Release
/// archive) plus `-UITestStubSkipAutoSelect`, so the app stops at the queue. That fixture's tree
/// is `2026-08-27 — Stub Shoot` (id 1, a root-level shoot) beside `2026` (id 2, a container) over
/// `2026-09-14 — Wandern` (id 3) over `template` (id 4).
final class FolderTreeHierarchyUITests: OrientationPinnedUITestCase {

  func testTheTreeNestsTwoLevelsAndTheSearchFieldFiltersIt() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"]
    app.launch()

    let disclosure = app.descendants(matching: .any)["foldersDisclosure"].firstMatch
    XCTAssertTrue(reveal(disclosure, in: app), "The Folders disclosure never became reachable.")
    let localTier = app.descendants(matching: .any)["folderTreeTier-Local"].firstMatch
    if !localTier.exists {
      disclosure.tap()
    }
    XCTAssertTrue(reveal(localTier, in: app), "The Local tier branch never appeared.")
    localTier.tap()

    // Level one: a folder that is NOT a shoot, which is exactly what the pre-P7 list dropped —
    // and its expand control, which is a separate button from the row's own tap target.
    let expander = app.descendants(matching: .any)["folderDisclose-2"].firstMatch
    XCTAssertTrue(
      reveal(expander, in: app),
      "The container's expand control never appeared — the sidebar is still rendering a flat "
        + "list of shoot leaves rather than the server's folder hierarchy (IMGMGR-217).")
    expander.tap()

    // Level two: the shoot underneath it.
    let nested = app.descendants(matching: .any)["folderRow-3"].firstMatch
    XCTAssertTrue(
      reveal(nested, in: app),
      "Expanding the container revealed no nested shoot — the tree is not two levels deep.")
    attach(named: "P7-tree-two-levels")

    let field = app.textFields["folderTreeSearchField"].firstMatch
    XCTAssertTrue(reveal(field, in: app), "The folder search field never appeared.")

    // A term nothing matches produces the empty state. This runs FIRST as the positive control
    // (LSN-0033) for the absence asserted next: "the row was gone" cannot then be the list
    // merely never having built it.
    field.tap()
    field.typeText("zzzz-no-such-folder\n")
    XCTAssertTrue(
      app.descendants(matching: .any)["folderTreeNoMatches"].firstMatch.waitForExistence(
        timeout: 10),
      "A search matching nothing produced no empty state — the filter is not running at all.")
    attach(named: "P7-tree-search-no-matches")

    app.descendants(matching: .any)["folderTreeSearchClear"].firstMatch.tap()
    XCTAssertTrue(reveal(field, in: app), "The search field vanished after being cleared.")
    field.tap()
    field.typeText("wandern\n")

    // The filter really ran: the non-matching shoot is gone, the match survives, and the match's
    // ancestor is still there to show where it lives.
    XCTAssertTrue(
      app.descendants(matching: .any)["folderRow-1"].firstMatch.waitForNonExistence(timeout: 10),
      "A shoot whose name does not contain the search term stayed in the tree.")
    XCTAssertTrue(
      app.descendants(matching: .any)["folderRow-3"].firstMatch.waitForExistence(timeout: 10),
      "The matching shoot disappeared with everything else — the filter dropped its own hit.")
    XCTAssertTrue(
      app.descendants(matching: .any)["folderContainer-2"].firstMatch.exists,
      "The match's ancestor was pruned away, so the hit is shown with no context.")
    attach(named: "P7-tree-search-applied")

    // Selection still lands in the SAME grid contract, from a row two levels down.
    let target = app.descendants(matching: .any)["folderRow-3"].firstMatch
    XCTAssertTrue(reveal(target, in: app), "The nested shoot was not reachable to tap.")
    target.tap()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Tapping a nested folder-tree row never reached the grid — every row must enter the SAME "
        + "grid through GridStore.selectShoot(folderID:sourceTier:).")
    attach(named: "P7-grid-reached-from-a-nested-shoot")
  }

  /// Scrolls the queue list until `element` is on screen, in BOTH directions: the Folders
  /// disclosure sits below the readiness sections, but its own search field sits above the rows,
  /// so an up-only scan walks past what it is looking for and never comes back (observed in gate
  /// run 1cfa3f4).
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
