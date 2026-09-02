import Foundation
import XCTest

/// IMGMGR-347 acceptance, on the real thing: a LOOSE photograph can be put INTO an existing
/// scene from the grid the reader is looking at, and the row that offers it is never a control
/// that does nothing.
///
/// The owner's device pass (TestFlight 0.11.0 (14)) found the opposite — "when a single photo is
/// selected the three dots menu: 'merge into..' is not doing anything" — because every scene-edit
/// row needs a MEMBER of an open scene as its subject and a loose photograph is not one. So both
/// halves are driven here: the row states its reason while there is nothing to absorb, and it
/// really absorbs when there is.
///
/// Written RED first: before the implementation, `gridMoreMenu.more.absorbScene` did not exist
/// and both tests failed on its absence.
///
/// Makes NO device-idiom decision — every step keys off an observed element and both destinations
/// run the same assertions.
final class SceneAbsorbUITests: OrientationPinnedUITestCase {

  private func launchedSceneApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestEnterSceneMode"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else.")
    return app
  }

  private func openMoreMenu(_ app: XCUIApplication) {
    let more = app.descendants(matching: .any)["gridMoreMenu"]
    XCTAssertTrue(
      more.waitForExistence(timeout: 10), "Nothing named 'gridMoreMenu' is on the action bar.")
    more.tap()
  }

  /// The whole gesture, by identifier: focus a loose photograph, open the More menu, choose the
  /// scene, and read the app's own count of absorb requests off the fixture probe — the transport
  /// is an actor, so the request reaching the server is only observable where it is published.
  func testAbsorbsAFocusedLoosePhotographIntoAScene() throws {
    let app = launchedSceneApp()

    // The fixture's stream is loose, loose, scene 5000, loose, loose — so tile 1 is a photograph
    // that belongs to no scene, and 5000 is the scene of the same folder it can join.
    let loose = app.descendants(matching: .any)["gridTile-1"].firstMatch
    XCTAssertTrue(
      loose.waitForExistence(timeout: 20),
      "The fixture's first loose photograph is not on screen — Scene mode never loaded.")
    loose.tap()

    openMoreMenu(app)
    let row = app.descendants(matching: .any)["gridMoreMenu.more.absorbScene"]
    XCTAssertTrue(
      row.waitForExistence(timeout: 10),
      "The More menu offers no way to put a loose photograph into a scene.")
    XCTAssertTrue(
      row.isEnabled,
      "The absorb row is disabled with a loose photograph focused and a scene in the same "
        + "folder on screen — label: '\(row.label)'.")
    row.tap()

    let target = app.descendants(matching: .any)["sceneAbsorbTarget-5000"].firstMatch
    XCTAssertTrue(
      target.waitForExistence(timeout: 10),
      "The picker did not offer the folder's own scene as a target.")
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "absorb-picker-open"
    attachment.lifetime = .keepAlways
    add(attachment)
    target.tap()

    let probe = app.descendants(matching: .any)["debugProbe.absorb"]
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value MATCHES %@", "absorbRequests=[1-9][0-9]*"),
      object: probe)
    let outcome = XCTWaiter().wait(for: [expectation], timeout: 15)
    XCTAssertEqual(
      outcome, .completed,
      "Choosing a scene sent no absorb request. The probe's value stayed at "
        + "\(probe.exists ? String(describing: probe.value) : "<absent>").")
  }

  /// The other half of the AC: while there is nothing to absorb the row is still THERE and still
  /// says why — the failure the owner hit was a row that looked available and did nothing.
  func testTheAbsorbRowStatesItsReasonWhenNoLoosePhotographIsFocused() throws {
    let app = launchedSceneApp()
    openMoreMenu(app)

    let row = app.descendants(matching: .any)["gridMoreMenu.more.absorbScene"]
    XCTAssertTrue(
      row.waitForExistence(timeout: 10),
      "The absorb row disappears when it cannot act — it must state its reason instead.")
    XCTAssertFalse(
      row.isEnabled,
      "The absorb row is enabled with nothing focused, so tapping it can only do nothing.")
    XCTAssertTrue(
      row.label.localizedCaseInsensitiveContains("loose"),
      "The disabled absorb row does not say what is missing. Label: '\(row.label)'")
    // Positive control for the reading above: the menu really did render, so the label came from
    // a row on screen rather than from an element that does not exist.
    XCTAssertTrue(
      app.descendants(matching: .any)["gridMoreMenu.more.status"].exists,
      "Positive control failed: the More menu is not on screen, so the label read above is "
        + "vacuous.")
  }
}
