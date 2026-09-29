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
///
/// WP29 P2 (IMGMGR-453): Group and Zoom are rows of the Arrange popover now, so the control this
/// asserts on a primary surface is `gridArrangeControl`. The current value is no longer in a
/// label: it is Arrange's "Active"/"Off" value and the popover's checked rows.
final class ViewOptionsScreenshotUITests: OrientationPinnedUITestCase {

  func testArrangeIsOnAPrimarySurface() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else (sign-in screen, blank screen, or a "
        + "failed stub composition).")

    let arrange = app.descendants(matching: .any)["gridArrangeControl"]
    XCTAssertTrue(
      arrange.waitForExistence(timeout: 10),
      "The Arrange control is not on a primary surface — nothing named 'gridArrangeControl' is "
        + "in the hierarchy without opening an overflow menu.")
    XCTAssertTrue(arrange.isHittable, "The Arrange control exists but cannot be tapped.")

    // The other half of "primary surface": no toolbar overflow chevron, with the action bar's
    // Dislike button as the positive control (LSN-0033).
    XCTAssertTrue(
      app.buttons["Dislike"].exists,
      "Positive control failed: the Dislike button is gone, so the 0-hit overflow check below "
        + "would pass vacuously.")
    XCTAssertFalse(
      app.buttons["OverflowBarButtonItem"].exists,
      "A toolbar overflow chevron is still present — something is back in `.secondaryAction`.")

    // The word stays visible, and the arrangement state is readable at rest.
    XCTAssertTrue(
      arrange.label.contains("Arrange"),
      "Arrange control label '\(arrange.label)' does not say 'Arrange'.")
    XCTAssertEqual(arrange.value as? String, "Off", "Arrange reads active at launch.")

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "view-options-primary-surface"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
