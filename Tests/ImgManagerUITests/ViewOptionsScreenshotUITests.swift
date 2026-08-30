import XCTest

/// WP13 P4 (IMGMGR-215) acceptance, on the real thing: the ticket's own AC is "primary-surface
/// controls for group/scene and zoom on BOTH idioms". The falsifiable form of that is —
/// the two controls are reachable and hittable WITHOUT opening any overflow menu, whatever
/// layout this destination resolves to. Before this phase they were
/// `ToolbarItem(placement: .secondaryAction)`, i.e. reachable only after tapping the nav bar's
/// `OverflowBarButtonItem` (verified live on the iPhone 17 Pro simulator, 2026-08-30 — see
/// `.phase-ledger.md`), so this test was RED for the right reason before the change and is
/// GREEN only because the controls moved out of the overflow.
///
/// Deliberately makes NO device-idiom decision (plan invariant (i)): it asserts the same thing
/// on both destinations and lets the layout put the controls wherever that layout puts them —
/// Compact's options row or Regular's `.primaryAction` toolbar.
final class ViewOptionsScreenshotUITests: XCTestCase {

  func testGroupAndZoomAreOnAPrimarySurface() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else (sign-in screen, blank screen, or a "
        + "failed stub composition).")

    let group = app.descendants(matching: .any)["gridGroupControl"]
    let zoom = app.descendants(matching: .any)["gridZoomControl"]

    XCTAssertTrue(
      group.waitForExistence(timeout: 10),
      "The Group control is not on a primary surface — nothing named 'gridGroupControl' is in "
        + "the hierarchy without opening an overflow menu.")
    XCTAssertTrue(
      zoom.waitForExistence(timeout: 10),
      "The Zoom control is not on a primary surface — nothing named 'gridZoomControl' is in "
        + "the hierarchy without opening an overflow menu.")
    XCTAssertTrue(group.isHittable, "The Group control exists but cannot be tapped where it is.")
    XCTAssertTrue(zoom.isHittable, "The Zoom control exists but cannot be tapped where it is.")

    // Value-in-label: the state must be readable WITHOUT opening anything. Both controls are
    // menus, so their rendered label is what a reader sees at rest.
    XCTAssertTrue(
      group.label.contains("Group:"),
      "Group control label '\(group.label)' does not carry its current value.")
    XCTAssertTrue(
      zoom.label.contains("Zoom:"),
      "Zoom control label '\(zoom.label)' does not carry its current value.")

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "view-options-primary-surface"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTContext.runActivity(
      named: "Group label: '\(group.label)' · Zoom label: '\(zoom.label)' · captured "
        + "\(screenshot.image.size)"
    ) { _ in }
  }
}
