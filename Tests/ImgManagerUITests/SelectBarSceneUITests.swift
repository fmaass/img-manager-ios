import Foundation
import UIKit
import XCTest

/// WP29 P4 (IMGMGR-455) acceptance: the Select bar's Scene ▸ runs the SHIPPED focus-derived scene
/// edits, enabled only when the selection agrees with the focused subject (plan Decision 5).
///
/// Fixture: the stream is loose 1, loose 2, scene 5000, loose 8, loose 9; scene 5000's band is
/// 3…7 then a plain tail. `f` = 4 (a NON-first member, so Split is legal), `m` = 5. Member 3
/// is never tapped: the band's close handle overlays the leading member
/// (`LoupeFilmstripScopeUITests`).
///
/// The touch path to an eligible state is the reader's own: a tap in browse moves the focus, a
/// long-press enters Select with that photograph selected and leaves the focus alone, and further
/// taps in Select toggle membership (GridStore `tapTile` / `longPressTile`).
///
/// Makes NO device-idiom decision — every step keys off an observed element or the window's
/// measured width, and both destinations run the same assertions.
final class SelectBarSceneUITests: OrientationPinnedUITestCase {

  private static let focusedMember = 4
  private static let otherMember = 5
  private static let regular3WidthThreshold: CGFloat = 1197
  private static let rows = [
    "selectBar.scene.merge", "selectBar.scene.split", "selectBar.scene.extract",
    "selectBar.scene.absorb",
  ]

  // MARK: - (a) non-eligible, flat browse

  func testSceneRowsArePresentAndDisabledOnAFlatSelection() throws {
    let app = launched(["-UITestStubGrid"])
    enterSelectFromTheGridBar(app)
    let first = element(app, "gridTile-1")
    XCTAssertTrue(first.waitForExistence(timeout: 15), "No grid tile to select.")
    first.tap()
    XCTAssertEqual(app.staticTexts["selectModeCaption"].label, "1 selected")

    assertAllRowsDisabled(app, state: "flat browse, one tile selected")
  }

  // MARK: - (b) non-eligible, Scene mode, focus and selection DISAGREE

  func testSceneRowsAreDisabledWhenTheSelectionDisagreesWithTheFocus() throws {
    let app = launched(["-UITestStubGrid", "-UITestEnterSceneMode"])
    expandTheFixtureScene(app)
    focus(Self.focusedMember, in: app)
    // Long-press ANOTHER member: Select with {m}, the focus still on f.
    longPress(Self.otherMember, in: app)
    XCTAssertEqual(app.staticTexts["selectModeCaption"].label, "1 selected")

    assertAllRowsDisabled(
      app, state: "focus \(Self.focusedMember), selection {\(Self.otherMember)}")
  }

  // MARK: - (c) eligible, via the touch path

  func testSplitIsEnabledAndSubmitsFromTheTouchPath() throws {
    let app = launched(["-UITestStubGrid", "-UITestEnterSceneMode"])
    expandTheFixtureScene(app)
    focus(Self.focusedMember, in: app)
    longPress(Self.focusedMember, in: app)
    XCTAssertEqual(app.staticTexts["selectModeCaption"].label, "1 selected")

    let split = element(app, "selectBar.scene.split")
    XCTAssertTrue(openSceneMenu(in: app, revealing: split, timeout: 10), "Scene ▸ has no Split.")
    capture("select-bar-scene-eligible-split")
    XCTAssertTrue(split.isEnabled, "Split here is disabled on S == {f}, f a non-first member.")
    XCTAssertTrue(
      element(app, "selectBar.scene.extract").isEnabled,
      "Extract selected is disabled on S == {f} ⊆ X.")
    split.tap()

    assertProbeRecords(
      app, "split(stackID: 5000, atImageID: \(Self.focusedMember))", what: "Split here")
  }

  func testExtractIsEnabledAndSubmitsFromTheTouchPath() throws {
    let app = launched(["-UITestStubGrid", "-UITestEnterSceneMode"])
    expandTheFixtureScene(app)
    focus(Self.focusedMember, in: app)
    longPress(Self.focusedMember, in: app)
    element(app, "gridTile-\(Self.otherMember)").tap()
    XCTAssertEqual(app.staticTexts["selectModeCaption"].label, "2 selected")

    let extract = element(app, "selectBar.scene.extract")
    XCTAssertTrue(
      openSceneMenu(in: app, revealing: extract, timeout: 10), "Scene ▸ has no Extract.")
    capture("select-bar-scene-eligible-extract")
    XCTAssertTrue(extract.isEnabled, "Extract selected is disabled on S == {f, m} ⊆ X.")
    extract.tap()

    // The wire call only: `focusedImageID` is coordinator metadata the service call omits, and
    // is covered by the unit coordinator-seam tests (`SceneSelectionAgreementTests`).
    assertProbeRecords(
      app, "extract(stackID: 5000, imageIDs: [\(Self.focusedMember), \(Self.otherMember)])",
      what: "Extract selected")
  }

  // MARK: - (d) reachability at every width

  /// Portrait and landscape: on the iPad those are Regular-2 and Regular-3 (the latter with the
  /// inspector EXPANDED, the narrowest grid column); on the iPhone both are Compact, where More
  /// must be on the bar.
  func testEverySelectBarControlIsReachableAtEveryWidth() throws {
    for (configuration, orientation) in [
      ("portrait", UIDeviceOrientation.portrait), ("landscape", .landscapeLeft),
    ] {
      XCUIDevice.shared.orientation = orientation
      let app = launched(["-UITestStubGrid"])
      XCUIDevice.shared.orientation = orientation
      Thread.sleep(forTimeInterval: 1.5)
      let width = app.frame.size.width
      let compact = width < Self.compactShellWidthCeiling
      var state = compact ? "compact-\(configuration)" : "regular2"
      if width >= Self.regular3WidthThreshold {
        state = "regular3-expanded"
        let info = gridInfoControl(app)
        XCTAssertTrue(info.waitForExistence(timeout: 10), "\(state): no Info control.")
        info.tap()
        XCTAssertTrue(
          app.buttons["Stats"].waitForExistence(timeout: 10),
          "\(state): Info did not expand the inspector.")
        Thread.sleep(forTimeInterval: 1.0)
      }
      enterSelectFromTheGridBar(app)
      let first = element(app, "gridTile-1")
      if first.waitForExistence(timeout: 10) { first.tap() }
      Thread.sleep(forTimeInterval: 0.5)
      capture("select-bar-\(state)")

      var hittable = ["gridPickButton", "gridDislikeButton", "gridTagButton", "selectBarSceneMenu"]
      if element(app, "gridClearButton").exists { hittable.append("gridClearButton") }
      if compact { hittable.append("gridMoreMenu") }
      for identifier in hittable {
        let control = element(app, identifier)
        XCTAssertTrue(control.waitForExistence(timeout: 5), "\(state): \(identifier) is missing.")
        XCTAssertFalse(control.frame.isEmpty, "\(state): \(identifier) has an empty frame.")
        XCTAssertTrue(
          app.frame.contains(control.frame),
          "\(state): \(identifier) at \(control.frame) is outside the window \(app.frame).")
        XCTAssertTrue(control.isHittable, "\(state): \(identifier) has no reachable hit region.")
      }
      // Undo stays disabled until a mark commits, so it is held to its frame, not its hit test.
      let undo = element(app, "gridUndoButton")
      XCTAssertTrue(undo.waitForExistence(timeout: 5), "\(state): Undo is missing.")
      XCTAssertTrue(
        app.frame.contains(undo.frame),
        "\(state): Undo at \(undo.frame) is outside the window \(app.frame).")
      app.terminate()
    }
  }

  // MARK: - Helpers

  private func launched(_ arguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = arguments
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else.")
    return app
  }

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  private func expandTheFixtureScene(_ app: XCUIApplication) {
    let handle = element(app, "sceneHandle-5000")
    XCTAssertTrue(handle.waitForExistence(timeout: 15), "The fixture scene's handle is missing.")
    handle.tap()
    XCTAssertTrue(
      element(app, "gridTile-\(Self.otherMember)").waitForExistence(timeout: 20),
      "Opening the scene did not put its members on screen.")
  }

  /// A browse tap moves the focus; a tap on the ALREADY-focused tile would open the loupe, so a
  /// loupe that opened is closed again — the focus is then where it had to be.
  private func focus(_ imageID: Int, in app: XCUIApplication) {
    let tile = element(app, "gridTile-\(imageID)")
    XCTAssertTrue(tile.waitForExistence(timeout: 10), "gridTile-\(imageID) is not on screen.")
    tile.tap()
    let close = app.buttons["loupeClose"]
    if close.waitForExistence(timeout: 1) { close.tap() }
  }

  private func longPress(_ imageID: Int, in app: XCUIApplication) {
    element(app, "gridTile-\(imageID)").press(forDuration: 1.0)
    XCTAssertTrue(
      app.staticTexts["selectModeCaption"].waitForExistence(timeout: 10),
      "Long-pressing gridTile-\(imageID) did not enter Select.")
  }

  private func assertAllRowsDisabled(_ app: XCUIApplication, state: String) {
    XCTAssertTrue(
      openSceneMenu(in: app, revealing: element(app, Self.rows[0]), timeout: 10),
      "\(state): Scene ▸ did not present its rows.")
    capture("select-bar-scene-disabled-\(state.prefix(10))")
    for identifier in Self.rows {
      let row = element(app, identifier)
      XCTAssertTrue(row.exists, "\(state): \(identifier) is not in Scene ▸.")
      XCTAssertFalse(
        row.isEnabled, "\(state): \(identifier) is enabled on a non-eligible selection.")
    }
  }

  private func assertProbeRecords(_ app: XCUIApplication, _ call: String, what: String) {
    let probe = element(app, "debugProbe.sceneEdit")
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value CONTAINS %@", call), object: probe)
    let outcome = XCTWaiter().wait(for: [expectation], timeout: 15)
    XCTAssertEqual(
      outcome, .completed,
      "\(what) did not send `\(call)`. The probe read "
        + "\(probe.exists ? String(describing: probe.value) : "<absent>").")
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

extension XCTestCase {
  /// WP29 P1's Select, on the grid's own navigation bar at every width, opened through the shared
  /// presentation opener (IMGMGR-404).
  func enterSelectFromTheGridBar(
    _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    let select = app.navigationBars.descendants(matching: .any)["gridSelectCommand"].firstMatch
    XCTAssertTrue(
      select.waitForExistence(timeout: 15), "No 'gridSelectCommand' on the navigation bar.",
      file: file, line: line)
    XCTAssertTrue(
      openPresentation(select, revealing: app.staticTexts["selectModeCaption"], timeout: 15),
      "The grid bar's Select did not enter Select mode.", file: file, line: line)
  }
}
