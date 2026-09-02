import XCTest

/// WP13 P2 (IMGMGR-222): the retained visual evidence the phase's Verification asks for — the
/// Dislike Lock mode row carrying its OWN caption, the Dislike control presented as the latched
/// one and Pick left plain, and the chrome twin ("Lock Dislike") present on the Dislike button.
/// Captured on whatever destination runs it, so the iPhone leg is the `.compact` capture the plan
/// names and the iPad leg is the same assertions at Regular-2.
///
/// The lock is entered through the DEBUG `-UITestLatchDislikeLock` launch hook rather than a
/// gesture, for the reason P1 already established for Select: a 350 ms double tap is not a
/// gesture XCUITest can time reliably against a control, and a context-menu item inside a popover
/// is not addressable by label or identifier on every idiom. The hook calls the very same
/// `GridStore.lockFromMenu(.dislike)` the shipped "Lock Dislike" command calls, so what is
/// captured is the shipped state reached through a shipped entry point, not a test-only mode.
final class DislikeLockScreenshotUITests: OrientationPinnedUITestCase {

  private func launchLatchedOnDislike() -> XCUIApplication {
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestLatchDislikeLock"]
    app.launch()
    // Again after launch: a sibling screenshot suite rotates post-launch, and this is the
    // sequence known to take on these destinations.
    XCUIDevice.shared.orientation = .portrait
    return app
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// What the harness can actually SEE, recorded BEFORE anything asserts — a bare failure on a
  /// caption label says nothing about which row rendered, at what size, in what tree.
  private func recordLockGeometry(_ app: XCUIApplication, controls: [(String, XCUIElement)]) {
    XCTContext.runActivity(named: "Dislike Lock geometry") { activity in
      var report = "orientation=\(XCUIDevice.shared.orientation.rawValue)\n"
      report += "app frame=\(app.frame)\n"
      var anomalous = false
      for (name, element) in controls {
        let exists = element.exists
        let frame = exists ? element.frame : .zero
        if !exists || frame.width < 1 || frame.height < 1 { anomalous = true }
        report += "\(name): exists=\(exists) enabled=\(exists && element.isEnabled) "
        report += "selected=\(exists && element.isSelected) frame=\(frame)\n"
      }
      let geometry = XCTAttachment(string: report)
      geometry.name = "dislike-lock-geometry"
      geometry.lifetime = .keepAlways
      activity.add(geometry)
      if anomalous {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "element-tree-dislike-lock"
        tree.lifetime = .keepAlways
        activity.add(tree)
      }
    }
  }

  func testDislikeLockModeRowStatesItsOwnCaptionAndLightsOnlyDislike() throws {
    let app = launchLatchedOnDislike()

    let caption = app.staticTexts["lockModeCaption"]
    XCTAssertTrue(
      caption.waitForExistence(timeout: 30),
      "Dislike Lock is latched but no mode row is on screen — a lock with no persistent row is "
        + "exactly the undiscoverable mode the persistent-chrome rule forbids.")

    // Attached before the assertions, so a red run keeps the picture that explains it.
    capture("Dislike-Lock-mode-row")

    XCTAssertEqual(
      caption.label, "Dislike Lock — tap photos to apply Dislike",
      "The mode row must state the LATCHED VERB's own caption. Rendering Pick Lock's caption "
        + "while Dislike is latched would tell the reader the wrong mark is about to be applied.")

    let pick = app.buttons["gridPickButton"]
    let dislike = app.buttons["gridDislikeButton"]
    let done = app.buttons["lockModeDone"]
    for control in [pick, dislike] {
      XCTAssertTrue(control.waitForExistence(timeout: 10), "A latch control is missing.")
    }
    recordLockGeometry(
      app, controls: [("Pick", pick), ("Dislike", dislike), ("Done", done), ("caption", caption)])

    // The unmistakable visual-state pair, at the RENDERED level: only the latched control is
    // selected. Both lit would state the mode without saying which mark a tap applies.
    XCTAssertTrue(
      dislike.isSelected,
      "The latched Dislike control must carry the selected trait — see the geometry attachment.")
    XCTAssertFalse(
      pick.isSelected, "Pick must stay plain while Dislike is the latched control.")

    // The way out is chrome, not a remembered gesture.
    XCTAssertTrue(done.waitForExistence(timeout: 10), "The lock mode row has no Done control.")
    XCTAssertTrue(done.isHittable, "Done has no reachable hit region.")
    done.tap()
    XCTAssertFalse(
      caption.waitForExistence(timeout: 5),
      "Done left the lock latched: the mode row is still on screen.")
    capture("Dislike-Lock-exited-via-Done")
  }

  /// The latched WIRING, through the production surface rather than the store: with Dislike
  /// latched, an ordinary single tap on a tile must commit a mark. Undo is the observable — it is
  /// disabled until a mark commits, so a latch that applies nothing leaves it disabled and turns
  /// this red.
  func testALatchedDislikeTapCommitsAMarkThroughTheShippedLane() throws {
    let app = launchLatchedOnDislike()

    let caption = app.staticTexts["lockModeCaption"]
    XCTAssertTrue(caption.waitForExistence(timeout: 30), "No lock mode row.")

    let undo = app.buttons["gridUndoButton"]
    XCTAssertTrue(undo.waitForExistence(timeout: 10), "The grid bar has no Undo control.")
    XCTAssertFalse(undo.isEnabled, "Nothing has been written yet, so there is nothing to undo.")

    // Addressed by the fixture's own ids (`DebugStubTransport` serves 1...12), never by bound
    // index: one tile surfaces as several accessibility elements.
    let tile = app.descendants(matching: .any).matching(identifier: "gridTile-1").firstMatch
    XCTAssertTrue(tile.waitForExistence(timeout: 10), "No grid tiles to mark.")
    tile.tap()

    let undoBecameAvailable = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: undo)
    let outcome = XCTWaiter().wait(for: [undoBecameAvailable], timeout: 15)
    XCTAssertEqual(
      outcome, .completed,
      "A tap while Dislike Lock is latched committed nothing: Undo never became available, so "
        + "the latched drag-across lane is not wired to the mark lane for this verb.")
    capture("Dislike-Lock-tap-applied")
  }
}
