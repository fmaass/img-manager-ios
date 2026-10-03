import XCTest

/// IMGMGR-509: the Compact options row (`GridOptionsRow`) still fits its controls when the text
/// is large. The row holds THREE controls today — Arrange, the funnel, Triage
/// (`ShellToolbarLayout.compactOptionsRow`; IMGMGR-464 removed the trailing "?") — and the row
/// keeps each one on a single truncating line rather than adapting to icon-only, so what is
/// pinned is that every one of them is inside the row, wholly on screen, hittable, and carries a
/// hit frame of at least 44 x 44 pt at an accessibility text size.
///
/// WIDTH, stated plainly: this runs at the gate's iPhone width only — the iPhone 17 Pro
/// destination (`bin/mac-gate.sh`, `MAC_GATE_IPHONE_TYPE`), 402 pt portrait. The narrowest width
/// the app supports, 375 pt (iPhone SE), is NOT exercised by the gate: it has no such
/// destination, and adding one is a Mac-side simulator change outside this test. That gap is
/// recorded on IMGMGR-509. The assertions read measured frames against the measured window, so
/// they would run unchanged on a narrower destination. The text size is set the way the system
/// itself reads it, the `UIPreferredContentSizeCategoryName` default on the launch arguments, and
/// a default-size launch first is the positive control that the setting took effect at all.
final class OptionsRowFitUITests: OrientationPinnedUITestCase {

  /// AX3: three steps into the accessibility sizes, well past the first one the AC names.
  private static let accessibilityTextSize = "UICTContentSizeCategoryAccessibilityXL"

  func testEveryOptionsRowControlFitsWithA44PointHitRegionAtAnAccessibilityTextSize() throws {
    // Positive control: the same control at the default text size, so a launch argument the
    // system ignored cannot pass as "fits at large text".
    let standard = launchGrid(extraArguments: [])
    guard rendersCompactShell(standard) else {
      throw XCTSkip("Regular width: the options row is Compact-only (`GridChromeRows`).")
    }
    let standardArrange = optionsRowControl(standard, "gridArrangeControl")
    XCTAssertTrue(
      standardArrange.waitForExistence(timeout: 30),
      "No 'gridArrangeControl' inside 'gridOptionsRow' at the default text size.")
    let standardHeight = standardArrange.frame.height
    standard.terminate()

    let app = launchGrid(
      extraArguments: ["-UIPreferredContentSizeCategoryName", Self.accessibilityTextSize])
    let row = optionsRow(app)
    XCTAssertTrue(row.waitForExistence(timeout: 30), "The pushed grid has no 'gridOptionsRow'.")
    let window = app.windows.firstMatch.frame
    attach(name: "options-row-ax3-\(Int(window.width))pt")

    let arrange = optionsRowControl(app, "gridArrangeControl")
    XCTAssertTrue(arrange.waitForExistence(timeout: 15), "No Arrange inside the options row.")
    XCTAssertGreaterThan(
      arrange.frame.height, standardHeight,
      "Arrange is no taller at \(Self.accessibilityTextSize) than at the default size "
        + "(\(standardHeight) pt), so the text size never took effect and this proves nothing.")

    // The row's controls are exactly the declared three: a fourth would be a control this proof
    // does not cover, and a missing one could not be measured.
    XCTAssertEqual(
      row.descendants(matching: .button).count, Self.optionsRowControlIdentifiers.count,
      "The options row does not hold exactly \(Self.optionsRowControlIdentifiers).")

    // Half a point of tolerance for the fractional frames XCUITest reports.
    let rowBand = row.frame.insetBy(dx: -0.5, dy: -0.5)
    let screen = window.insetBy(dx: -0.5, dy: -0.5)
    for identifier in Self.optionsRowControlIdentifiers {
      let control = optionsRowControl(app, identifier)
      XCTAssertTrue(
        control.waitForExistence(timeout: 10), "'\(identifier)' is not inside 'gridOptionsRow'.")
      let frame = control.frame
      XCTAssertTrue(control.isHittable, "'\(identifier)' is not hittable (frame \(frame)).")
      XCTAssertGreaterThanOrEqual(
        frame.width, 44, "'\(identifier)' is narrower than 44 pt (frame \(frame)).")
      XCTAssertGreaterThanOrEqual(
        frame.height, 44, "'\(identifier)' is shorter than 44 pt (frame \(frame)).")
      XCTAssertTrue(
        screen.contains(frame),
        "'\(identifier)' runs off the \(window.width) pt window (frame \(frame)).")
      XCTAssertTrue(
        rowBand.contains(frame),
        "'\(identifier)' (frame \(frame)) lies outside the options row (frame \(row.frame)).")
    }
  }

  private func launchGrid(extraArguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"] + extraArguments
    app.launch()
    return app
  }

  private func attach(name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
