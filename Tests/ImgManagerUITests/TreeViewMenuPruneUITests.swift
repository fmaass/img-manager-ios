import XCTest

/// WP29 P2 (IMGMGR-453): Hide mirrored archive left the grid's More menu. Its one home is the
/// tree's View menu (`folderTreeViewMenu`: the Regular sidebar, the Compact Library tab), which
/// renders the same declared entry on the same preference key.
///
/// This probes the move on both destinations: More carries no prune row, and the tree's View menu
/// carries exactly one. That the row, once flipped, hides the fixture's mirrored archive branch and
/// brings it back is `ArchivePruneUITests`, which drives this same View-menu row on both
/// destinations and is unchanged by the move.
final class TreeViewMenuPruneUITests: OrientationPinnedUITestCase {

  private let prune = "gridMoreMenu.more.pruneMirroredArchive"

  func testThePruneRowLivesInTheTreeViewMenuAndNotInMore() throws {
    let app = XCUIApplication()
    // Pinned OFF for this launch, as `ArchivePruneUITests` does; nothing is toggled here.
    app.launchArguments = ["-grid.pruneMirroredArchive", "<false/>", "-UITestStubGrid"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid.")

    // More: its Status row is the positive control for the two absences.
    let status = app.descendants(matching: .any)["gridMoreMenu.more.status"]
    XCTAssertTrue(
      openMoreMenu(in: app, revealing: status, timeout: 10),
      "The More menu did not present its Status row, so the absence checks would be vacuous.")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: prune).count, 0,
      "The grid's More menu still carries the archive prune.")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "gridMoreMenu.more.density").count, 0,
      "The grid's More menu still carries Density.")
    attach("tree-prune-more-without-prune")
    // Close the menu with a tap on the status-bar strip, which carries no control.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).tap()
    XCTAssertTrue(status.waitForNonExistence(timeout: 5), "The More menu did not close.")

    // The tree's View menu: exactly one prune row.
    showLibraryIfCompact(app)
    let viewMenu = app.descendants(matching: .any)["folderTreeViewMenu"].firstMatch
    XCTAssertTrue(
      viewMenu.waitForExistence(timeout: 10), "The tree exposes no View menu at this width.")
    let entry = app.descendants(matching: .any)[prune].firstMatch
    XCTAssertTrue(
      openPresentation(viewMenu, revealing: entry, timeout: 10),
      "The tree's View menu does not render '\(prune)'.")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: prune).count, 1,
      "Not exactly one '\(prune)' while the tree's View menu is open.")
    attach("tree-prune-view-menu")
  }

  private func attach(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
