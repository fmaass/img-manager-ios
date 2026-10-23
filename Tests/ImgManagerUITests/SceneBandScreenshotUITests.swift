import XCTest

/// WP14 lane B acceptance on the real thing: the scene handle (IMGMGR-240; WP442 P12: it PUSHES
/// the scene screen now), the ✓N pick count on the card (IMGMGR-241), and the picks a card holds
/// (IMGMGR-261).
///
/// Makes NO device-idiom decision. Where the app's own behaviour differs by layout — the inline
/// picks ship on Regular only, a measured product decision — this test READS the decision the
/// app published (`sceneCard`'s DEBUG probe value) and asserts BOTH branches, rather than
/// guessing at a destination. That is the same discipline `GridMoreMenuUITests` uses for the
/// action bar's fold tier.
final class SceneBandScreenshotUITests: OrientationPinnedUITestCase {

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

    // IMGMGR-240: a REAL control, named — not a chevron that looks like one, and not a gesture
    // the reader has to discover. IMGMGR-542 (R3-22): it opens and closes the scene's peek band
    // (a card tap pushes), so it names that action in its closed state.
    let handle = app.descendants(matching: .any)["sceneHandle-5000"].firstMatch
    XCTAssertTrue(
      handle.waitForExistence(timeout: 10),
      "The scene has no open handle — opening is gesture-only again.")
    XCTAssertTrue(handle.isHittable, "The open handle exists but cannot be tapped where it is.")
    XCTAssertEqual(
      handle.label, "Show this scene's photos", "The handle does not name what it does.")
    XCTAssertEqual(handle.value as? String, "closed", "The handle does not state its band state.")

    // IMGMGR-261. The probe is used to OBSERVE which layout this destination resolved to, and for
    // nothing else — the expectation below is this test's own, written out here:
    //
    //     compact  -> no inline picks (badge-only card, the measured pivot)
    //     regular* -> inline picks, because the launch argument turned the switch on
    //
    // Deriving the expectation from the probe's `inlinePicks=` half instead would be circular:
    // that half IS the app's answer, so a pivot changed to draw the strip on Compact (or nowhere
    // at all) would move the probe and the expectation together and this test would still pass.
    // The `layout=` half cannot do that — it reports the resolved `LayoutMode`, which sits
    // upstream of the pivot — so a pivot change now breaks the pair below.
    let probe = (card.value as? String) ?? ""
    XCTAssertTrue(
      probe.contains("layout="),
      "The scene card published no layout probe — the branch assertion below would be vacuous.")
    let isCompact = probe.contains("layout=compact")
    let expectsInlinePicks = !isCompact
    // The pivot itself, pinned: the app's own decision must equal this test's table. This is the
    // assertion that a pivot change has to come through.
    XCTAssertEqual(
      probe.contains("inlinePicks=true"), expectsInlinePicks,
      "The app's inline-picks pivot disagrees with this test's own table (compact -> off, "
        + "regular -> on with the switch on). Probe: '\(probe)'")
    let strip = app.descendants(matching: .any)["sceneInlinePicks-5000"].firstMatch
    if expectsInlinePicks {
      XCTAssertTrue(
        strip.waitForExistence(timeout: 10),
        "This layout is not compact, so the inline picks are expected and none are drawn. "
          + "Probe: '\(probe)'")
      XCTAssertTrue(
        strip.label.contains("2 picked"),
        "The inline strip does not describe what it shows. Label: '\(strip.label)'")
      // DISPLAY-ONLY (ADR-0005): what is drawn inside the card is NOT a tile. `gridTile-<id>` is
      // the identifier every real, markable, selectable cell carries, and member 3 is one of the
      // two picks this strip is drawing — so its absence here is the boundary, stated in the
      // hierarchy. (`isHittable` cannot say this: XCUITest derives hittability from the
      // accessibility tree, not from SwiftUI's `allowsHitTesting`, so it answers true for a view
      // that refuses every gesture. The 06:38 iPad leg is where that assertion was wrong.)
      XCTAssertFalse(
        app.descendants(matching: .any)["gridTile-3"].exists,
        "A member drawn inside a collapsed card became a real tile.")
    } else {
      XCTAssertFalse(
        strip.exists,
        "Compact must keep the badge-only card (measured pivot). Probe: '\(probe)'")
    }
    attach(name: "scene-card-badges-and-handle")

    // WP442 P12: opening PUSHES the scene screen — its members, each an ordinary tile, under
    // the title "Scene · 41 photos". IMGMGR-542: the card pushes; the chevron peeks.
    pushScene(app, 5000)
    // IMGMGR-481: the hierarchy as it stood right after the tap, so a lost tap is attributable
    // (was the handle covered, or did the push never happen?) rather than a bare timeout.
    let afterTap = XCTAttachment(string: app.debugDescription)
    afterTap.name = "scene-handle-after-first-tap-hierarchy"
    afterTap.lifetime = .keepAlways
    add(afterTap)
    let member = app.descendants(matching: .any)["gridTile-3"].firstMatch
    XCTAssertTrue(
      member.waitForExistence(timeout: 15),
      "Opening the scene did not put its members on screen.")
    XCTAssertTrue(
      app.descendants(matching: .any).matching(
        NSPredicate(
          format: "label == %@ OR identifier == %@", "Scene · 41 photos", "Scene · 41 photos")
      ).firstMatch.waitForExistence(timeout: 10),
      "The pushed screen is not titled with the scene's photo count.")
    XCTAssertFalse(
      app.descendants(matching: .any)["sceneCard"].firstMatch.exists,
      "The card is still on screen inside its own scene.")
    attach(name: "scene-screen-pushed")

    // ...and Back really returns to the stream, so the push is a navigation, not an overlay.
    let regularBack = app.buttons["sceneBackButton"]
    if regularBack.exists {
      regularBack.tap()
    } else {
      app.navigationBars.buttons.element(boundBy: 0).tap()
    }
    XCTAssertTrue(
      app.descendants(matching: .any)["sceneCard"].firstMatch.waitForExistence(timeout: 15),
      "Back did not bring the card back.")
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
