import XCTest

/// WP14 lane B acceptance on the real thing: the in-place member band and its handle
/// (IMGMGR-240), the ✓N pick count on a collapsed card (IMGMGR-241), and the picks a collapsed
/// scene holds (IMGMGR-261).
///
/// Makes NO device-idiom decision. Where the app's own behaviour differs by layout — the inline
/// picks ship on Regular only, a measured product decision — this test READS the decision the
/// app published (`sceneCard`'s DEBUG probe value) and asserts BOTH branches, rather than
/// guessing at a destination. That is the same discipline `GridMoreMenuUITests` uses for the
/// action bar's fold tier.
final class SceneBandScreenshotUITests: XCTestCase {

  /// PORTRAIT, pinned in and out — device orientation is simulator-global and survives across
  /// test classes (see `ViewOptionsScreenshotUITests` for the run this rule came from).
  override func setUp() {
    super.setUp()
    XCUIDevice.shared.orientation = .portrait
  }

  override func tearDown() {
    XCUIDevice.shared.orientation = .portrait
    super.tearDown()
  }

  func testSceneCardBadgesHandleAndBandOnOpen() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestEnterSceneMode"]
    app.launch()

    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else.")

    let card = app.descendants(matching: .any)["sceneCard"].firstMatch
    XCTAssertTrue(
      card.waitForExistence(timeout: 20),
      "No scene card is on screen — the fixture never entered Scene mode with data.")

    // IMGMGR-241: the card states a pick COUNT. Its two picked members are a fixture fact, so a
    // card announcing a flag (or nothing) fails here.
    XCTAssertTrue(
      card.label.contains("2 picked"),
      "The collapsed card does not announce its pick count. Label: '\(card.label)'")

    // IMGMGR-240: a REAL control, named, with its state readable at rest — not a chevron that
    // looks like one, and not a gesture the reader has to discover.
    let handle = app.descendants(matching: .any)["sceneHandle-5000"].firstMatch
    XCTAssertTrue(
      handle.waitForExistence(timeout: 10),
      "The scene has no expand handle — expansion is gesture-only again.")
    XCTAssertTrue(handle.isHittable, "The expand handle exists but cannot be tapped where it is.")
    XCTAssertEqual(
      handle.label, "Open scene", "The handle does not name what it does while closed.")
    XCTAssertEqual(
      (handle.value as? String) ?? "", "Closed",
      "The handle does not carry its open/closed state.")

    // IMGMGR-261: the app publishes which branch it took; assert THAT branch, whichever it is.
    let probe = (card.value as? String) ?? ""
    XCTAssertTrue(
      probe.contains("layout="),
      "The scene card published no layout probe — the branch assertion below would be vacuous.")
    let strip = app.descendants(matching: .any)["sceneInlinePicks-5000"].firstMatch
    if probe.contains("inlinePicks=true") {
      XCTAssertTrue(
        strip.waitForExistence(timeout: 10),
        "Regular ships the inline picks and none are drawn. Probe: '\(probe)'")
      XCTAssertTrue(
        strip.label.contains("2 picked"),
        "The inline strip does not describe what it shows. Label: '\(strip.label)'")
      // DISPLAY-ONLY (ADR-0005): the strip is never a target — the card stays one tap that
      // opens the group.
      XCTAssertFalse(
        strip.isHittable,
        "The inline picks are hit-testable — a collapsed scene's member became a target.")
    } else {
      XCTAssertFalse(
        strip.exists,
        "Compact must keep the badge-only card (measured pivot). Probe: '\(probe)'")
    }
    attach(name: "scene-card-badges-and-handle")

    // Opening SWAPS: the card leaves and its members take its place, each an ordinary tile.
    handle.tap()
    let member = app.descendants(matching: .any)["gridTile-3"].firstMatch
    XCTAssertTrue(
      member.waitForExistence(timeout: 15),
      "Opening the scene did not put its members on screen.")
    XCTAssertFalse(
      app.descendants(matching: .any)["sceneCard"].firstMatch.exists,
      "The card is still on screen beside its own members — the band did not replace it.")

    // The band keeps a way back, on the band itself: the handle moved onto the leading member.
    let bandHandle = app.descendants(matching: .any)["sceneHandle-5000"].firstMatch
    XCTAssertTrue(
      bandHandle.waitForExistence(timeout: 10),
      "The open band has no control — the only way to close the scene left with the card.")
    XCTAssertEqual(
      bandHandle.label, "Close scene", "The band's handle does not name the way back.")
    XCTAssertEqual(
      (bandHandle.value as? String) ?? "", "Open",
      "The band's handle does not carry its open state.")
    attach(name: "scene-band-open")

    // ...and it really closes, so the control is wired rather than merely present.
    bandHandle.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["sceneCard"].firstMatch.waitForExistence(timeout: 15),
      "Closing the band did not bring the card back.")
  }

  private func attach(name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTContext.runActivity(named: "\(name) size \(screenshot.image.size)") { _ in }
  }
}
