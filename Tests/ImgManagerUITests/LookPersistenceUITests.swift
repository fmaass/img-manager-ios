import XCTest

/// IMGMGR-544 (P16b, AC2): an applied look persists. Apply saves it through the DEBUG stub, whose
/// saved looks belong to the transport and outlive the process (`DebugStubTransport.savedLooks`);
/// a NEW process launched with `-UITestKeepStubLooks` must read it back — the grid tile's look
/// glyph and the loupe's chip and looked render, not anything the first process held in memory.
///
/// The photograph is `gridTile-2`, not `gridTile-1`: the fixture marks every third photograph
/// `has_edit` starting with the first, and an edited photograph never renders a look (its tile
/// shows the pencil, never the look glyph), so the first tile could not show what this proves.
final class LookPersistenceUITests: LooksStripUITestCase {

  private let tileID = "gridTile-2"
  private let chipText = "Warm Film · 100 %"
  private let lookedLabel = "Photograph, look Warm Film"

  func testAnAppliedLookSurvivesARelaunch() throws {
    let app = launchIntoTheLoupe(tile: tileID)
    let image = element(app, "loupeImage")
    XCTAssertTrue(
      waitFor(image, "label == %@", "Photograph", timeout: 15),
      "The loupe never painted the unlooked photograph: '\(image.label)'.")
    XCTAssertFalse(element(app, "loupeLookChip").exists, "A look was saved before Apply.")

    openStrip(app)
    let warm = element(app, "loupeLookTile-warm-film")
    XCTAssertTrue(warm.waitForExistence(timeout: 10), "The strip has no Warm Film tile.")
    press(warm)
    XCTAssertTrue(waitFor(warm, "value == %@", "Selected"), "Warm Film is not selected.")
    let apply = element(app, "loupeLooksApply")
    XCTAssertTrue(waitFor(apply, "isEnabled == true"), "Apply is not live with a look chosen.")
    press(apply)
    XCTAssertTrue(
      waitFor(element(app, "loupeLooksStrip"), "exists == false", timeout: 15),
      "Apply left the strip up.")
    assertSavedLookInTheLoupe(app, "after Apply")

    app.buttons["loupeBack"].tap()
    assertLookGlyph(app, "after leaving the loupe")

    app.terminate()
    app.launchArguments += ["-UITestKeepStubLooks"]
    app.launch()
    assertLookGlyph(app, "after the relaunch")
    openLoupe(app, tile: tileID)
    assertSavedLookInTheLoupe(app, "after the relaunch")
  }

  private func assertSavedLookInTheLoupe(_ app: XCUIApplication, _ when: String) {
    let chip = element(app, "loupeLookChip")
    XCTAssertTrue(
      waitFor(chip, "label == %@", chipText, timeout: 15),
      "No saved-look chip \(when): '\(chip.exists ? chip.label : "<absent>")'.")
    let image = element(app, "loupeImage")
    XCTAssertTrue(
      waitFor(image, "label == %@", lookedLabel, timeout: 15),
      "The loupe does not render the saved look \(when): '\(image.label)'.")
  }

  private func assertLookGlyph(_ app: XCUIApplication, _ when: String) {
    let tile = element(app, tileID)
    XCTAssertTrue(tile.waitForExistence(timeout: 30), "\(tileID) is not on the grid \(when).")
    XCTAssertTrue(
      waitFor(tile, "value BEGINSWITH 'badges=' AND value CONTAINS 'look'", timeout: 20),
      "\(tileID) shows no look glyph \(when): '\(String(describing: tile.value))'.")
  }
}
