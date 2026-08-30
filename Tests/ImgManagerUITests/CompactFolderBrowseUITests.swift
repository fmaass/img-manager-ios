import XCTest

/// P6 (IMGMGR-216) acceptance, driven through the PRODUCTION composition rather than an
/// extracted helper (diff-gate round 1, blocker 2). The value tests in `FolderTreeSectionTests`
/// pin the two pure decisions; only this one fails if `RootView.sidebar` goes back to handing
/// `QueueView` a `nil` tree on Compact, because only this one actually mounts the sidebar, finds
/// the disclosure, expands a tier and taps a shoot row through to the grid.
///
/// Runs on BOTH gate destinations and asserts nothing idiom-shaped: it tolerates the disclosure
/// already being open (Compact opens itself) or closed (Regular stays collapsed, D13) and opens
/// it from chrome if needed — there is no gesture-only path here to begin with. The iPhone
/// destination's run is the one that is RED if the Compact browse surface disappears.
///
/// Launch fixture: `-UITestStubGrid` (DEBUG-only `DebugStubTransport`, never in a Release
/// archive) plus `-UITestStubSkipAutoSelect`, so the app stops at the queue instead of being
/// auto-navigated into the grid. The stub's folder tree is one `kind: "dated"` node, id 1.
final class CompactFolderBrowseUITests: XCTestCase {
  private let stubShootRow = "folderRow-1"

  func testFolderTreeReachesAShootAndEntersTheGrid() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"]
    app.launch()

    let disclosure = app.descendants(matching: .any)["foldersDisclosure"].firstMatch
    XCTAssertTrue(
      reveal(disclosure, in: app),
      "The Folders disclosure never became reachable in the queue. On Compact this is the only "
        + "browse surface beyond the queue cards (IMGMGR-216); a nil tree section is exactly the "
        + "defect this phase fixed.")
    attach(named: "P6-queue-folders-disclosure")

    let localTier = app.descendants(matching: .any)["folderTreeTier-Local"].firstMatch
    if !localTier.exists {
      disclosure.tap()
    }
    XCTAssertTrue(
      reveal(localTier, in: app),
      "The Local tier branch never appeared under the Folders disclosure — the folder tree "
        + "loaded no shoot rows from GET /api/folders.")

    localTier.tap()
    let shootRow = app.descendants(matching: .any)[stubShootRow].firstMatch
    XCTAssertTrue(
      reveal(shootRow, in: app),
      "The fixture shoot row (\(stubShootRow)) never appeared under the Local tier branch.")
    attach(named: "P6-folders-expanded-shoot-reachable")

    shootRow.tap()

    // The grid's action bar is the same element the shipped Regular-3 screenshot test waits on:
    // its presence means selectShoot() completed and the grid is showing the shoot's images.
    let dislikeButton = app.buttons["Dislike"]
    XCTAssertTrue(
      dislikeButton.waitForExistence(timeout: 30),
      "Tapping a folder-tree row never reached the grid — the tree must enter the SAME grid the "
        + "queue cards enter, through GridStore.selectShoot(folderID:sourceTier:).")
    attach(named: "P6-grid-reached-from-folders")
  }

  /// Scrolls the queue list until `element` is on screen. The Folders disclosure sits BELOW the
  /// readiness sections by design, so it is off-screen at launch on a phone.
  private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 10) -> Bool {
    if element.waitForExistence(timeout: 15), element.isHittable { return true }
    // SwiftUI's `List` is a collection view; the queue is the first one on both idioms. Falling
    // back to the app itself keeps the helper working if that ever stops being true.
    let firstList = app.collectionViews.firstMatch
    let scroller: XCUIElement = firstList.exists ? firstList : app
    for _ in 0..<swipes {
      scroller.swipeUp()
      if element.exists, element.isHittable { return true }
    }
    return element.exists && element.isHittable
  }

  /// Screenshots are retained as XCTAttachments, which land in the run's `.xcresult` bundle
  /// under the gate's own DerivedData — the size suffix distinguishes the iPhone destination's
  /// capture from the iPad's without asking the app anything idiom-shaped.
  private func attach(named name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let size = screenshot.image.size
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(name)-\(Int(size.width))x\(Int(size.height))"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
