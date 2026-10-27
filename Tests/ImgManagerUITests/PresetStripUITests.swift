import XCTest

/// IMGMGR-658: the Presets row, the Looks panel's second row, against the DEBUG stub server
/// (`-UITestStubPresets`: four presets, one favourite, a render that stays pending). The row
/// opens collapsed to its Favourites, "All" expands it to every group, and a chip's tap shows
/// the render's progress state.
final class PresetStripUITests: LooksStripUITestCase {
  private static let favourite = "a1b2c3d4e5f6"
  private static let approximate = "b2c3d4e5f6a1"
  private static let mono = "c3d4e5f6a1b2"

  private func chip(_ app: XCUIApplication, _ presetID: String) -> XCUIElement {
    element(app, "loupePresetChip-\(presetID)")
  }

  private func openPresets() -> XCUIApplication {
    let app = launchIntoTheLoupe(extraArguments: ["-UITestStubPresets"])
    openStrip(app)
    XCTAssertTrue(
      element(app, "loupePresetsRow").waitForExistence(timeout: 15),
      "The Presets row never appeared under the Looks strip.")
    return app
  }

  func testPresetsRowIsVisibleAndAllExpandsPastTheFavourites() {
    let app = openPresets()
    XCTAssertTrue(
      chip(app, Self.favourite).waitForExistence(timeout: 10), "The favourite has no chip.")
    XCTAssertFalse(chip(app, Self.mono).exists, "The row did not open collapsed to Favourites.")

    let all = element(app, "loupePresetsAll")
    XCTAssertTrue(all.waitForExistence(timeout: 5), "The collapsed row offers no \"All\".")
    press(all)

    XCTAssertTrue(
      chip(app, Self.mono).waitForExistence(timeout: 10), "\"All\" did not expand the row.")
    XCTAssertFalse(all.exists, "\"All\" stayed after the row expanded.")
    let approximate = chip(app, Self.approximate)
    XCTAssertTrue(approximate.exists, "The approximate preset has no chip.")
    XCTAssertTrue(
      approximate.label.contains("approximate: look table not applied"),
      "The approximate chip's label does not name its reason: \(approximate.label)")
  }

  func testTappingAPresetShowsTheRenderInProgress() {
    let app = openPresets()
    let favourite = chip(app, Self.favourite)
    XCTAssertTrue(favourite.waitForExistence(timeout: 10), "The favourite has no chip.")
    XCTAssertEqual(favourite.value as? String ?? "", "", "A chip was busy before any tap.")

    press(favourite)

    XCTAssertTrue(
      waitFor(favourite, "value IN %@", ["Requested", "Rendering"], timeout: 10),
      "The tapped chip never showed the render in progress: \(String(describing: favourite.value))")
    XCTAssertTrue(
      element(app, "loupePresetStatus").waitForExistence(timeout: 5),
      "The row shows no rendering status for the tapped preset.")
  }
}
