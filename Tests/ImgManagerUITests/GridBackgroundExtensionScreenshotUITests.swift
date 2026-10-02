import UIKit
import XCTest

/// IMGMGR-469 (p4128 D1/D6; ADR-N1 Amendment 1): at Regular-3 with the inspector collapsed, the
/// grid's photographs continue — mirrored and blurred by the system — under the floating sidebar.
///
/// The retained screenshot `IMGMGR-469-regular3-collapsed-grid-under-sidebar` IS the evidence.
/// No assertion here can tell the extension from its absence: `.backgroundExtensionEffect()`
/// moves no layout and adds no accessibility element, so every frame XCUITest can read — the
/// tiles, the scroll view, the sidebar — is the same with and without it. The geometry is
/// printed beside the capture (`IMGMGR-469-GEOMETRY`) as a record, never asserted. What IS
/// asserted is the state the screenshot claims to show: Regular-3, inspector collapsed, the
/// sidebar on screen beside a populated grid — so the capture cannot silently be of something
/// else.
///
/// Makes no device-idiom decision: Regular-3 is identified by the app's measured window width
/// against the resolver's pin, as `Regular3CollapsedChromeUITests` does; the iPhone destination
/// skips with its measured window.
final class GridBackgroundExtensionScreenshotUITests: OrientationPinnedUITestCase {

  /// LANDSCAPE: what puts the iPad destination at Regular-3.
  override class var pinnedOrientation: UIDeviceOrientation { .landscapeLeft }

  /// Mirrors `LayoutResolver.regular3Threshold`, as `Regular3CollapsedChromeUITests` does
  /// (`LayoutPresentationTests.theRegular3WidthPinMatchesTheUITestLiteral` keeps that literal
  /// honest; this one is the same number).
  private static let regular3WidthThreshold: CGFloat = 1197

  func testRegular3CollapsedGridContinuesUnderTheSidebar() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    // Again after launch: the sequence known to take on these destinations
    // (`RegularThreeScreenshotUITests`).
    XCUIDevice.shared.orientation = .landscapeLeft

    let dislike = app.buttons["Dislike"]
    XCTAssertTrue(
      dislike.waitForExistence(timeout: 30),
      "Action bar (Dislike) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else (sign-in, blank, or a failed stub).")

    // The layout gate, waited on rather than slept through: a window whose LONGER side is below
    // the pin can never be Regular-3 (the iPhone destination), so it skips at once; otherwise
    // the window width is re-read until the landscape layout has taken, each pass waiting on the
    // action bar being hittable.
    let window = app.frame.size
    guard max(window.width, window.height) >= Self.regular3WidthThreshold else {
      throw XCTSkip(
        "IMGMGR-469 window=\(window): below the Regular-3 pin "
          + "(\(Self.regular3WidthThreshold)) in either orientation — no Regular-3 here")
    }
    let deadline = Date(timeIntervalSinceNow: 10)
    let pin = Self.regular3WidthThreshold
    while app.frame.size.width < pin && deadline.timeIntervalSinceNow > 0 {
      let settled = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "isHittable == true"), object: dislike)
      _ = XCTWaiter().wait(for: [settled], timeout: 1)
    }
    // A destination that CAN be Regular-3 and never gets there is a failure, not a skip: a skip
    // here would leave a green run without the screenshot this test exists to capture.
    guard app.frame.size.width >= Self.regular3WidthThreshold else {
      XCTFail(
        "IMGMGR-469 window=\(app.frame.size): landscape never reached the Regular-3 pin "
          + "(\(Self.regular3WidthThreshold))")
      return
    }

    // Inspector collapsed — the launch state at Regular-3 (IMGMGR-390). `Stats` is the
    // inspector's own segment; the hittable action bar is the positive control for the absence.
    XCTAssertFalse(
      app.buttons["Stats"].exists,
      "Regular-3 launched with the inspector expanded — this capture needs the collapsed state.")
    XCTAssertTrue(
      dislike.isHittable,
      "Positive control failed: the action bar is gone, so the absence check above is vacuous.")

    // The sidebar is on screen, floating beside the grid: the surface the photographs continue
    // under.
    let sidebarRow = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    let sidebarUp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isHittable == true"), object: sidebarRow)
    XCTAssertEqual(
      XCTWaiter().wait(for: [sidebarUp], timeout: 10), .completed,
      "The sidebar's tier row never became hittable — the collapsed Regular-3 workspace shows "
        + "the sidebar beside the grid, and without it there is nothing to extend under.")

    // A populated grid: the first photograph's tile is on screen.
    let firstTile = app.descendants(matching: .any)["gridTile-1"].firstMatch
    let tileUp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isHittable == true"), object: firstTile)
    XCTAssertEqual(
      XCTWaiter().wait(for: [tileUp], timeout: 10), .completed,
      "`gridTile-1` never became hittable — the grid is not populated, so the capture would "
        + "show nothing continuing under the sidebar.")

    let grid = app.scrollViews.containing(.any, identifier: "gridTile-1").firstMatch
    print(
      "IMGMGR-469-GEOMETRY window=\(app.frame.size) sidebarRow=\(sidebarRow.frame) "
        + "grid=\(grid.exists ? String(describing: grid.frame) : "<absent>") "
        + "firstTile=\(firstTile.frame)")

    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "IMGMGR-469-regular3-collapsed-grid-under-sidebar"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
