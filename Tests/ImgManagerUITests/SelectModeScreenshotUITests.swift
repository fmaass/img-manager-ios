import XCTest

/// WP13 P1 (IMGMGR-212, and the shipped defect IMGMGR-223): the retained visual evidence the
/// phase's Verification asks for — the Select mode row at ZERO and at a non-zero count, the four
/// selection-consuming controls refusing then live, and every bar control reachable — captured in
/// BOTH iPad configurations, portrait (Regular-2) and landscape (Regular-3), because those are
/// two different layouts and only one of them was ever being checked.
///
/// Select is entered through the DEBUG `-UITestEnterSelectMode` launch hook rather than a
/// gesture: on Regular-3 the tile long press never arrives (the grid's own pointer-drag
/// recognizer claims it) and the More menu's popover items are not addressable from XCUITest by
/// label or by identifier — three gate runs established both. The hook calls the very same
/// `GridStore.enterSelectExplicitly()` the More menu's command calls, so what is captured is the
/// shipped state reached through the shipped entry point, not a test-only mode.
final class SelectModeScreenshotUITests: OrientationPinnedUITestCase {

  private func launchInSelectMode(landscape: Bool) -> XCUIApplication {
    XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestEnterSelectMode"]
    app.launch()
    // Again after launch: the sibling screenshot test rotates post-launch and that is the
    // sequence known to take on this destination.
    XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
    return app
  }

  private func tile(_ imageID: Int, in app: XCUIApplication) -> XCUIElement {
    // Addressed by the fixture's own ids (`DebugStubTransport` serves 1...12), never by bound
    // index: one tile surfaces as several accessibility elements, so an index-addressed pair can
    // be the same photograph twice — selecting it and then deselecting it.
    app.descendants(matching: .any).matching(identifier: "gridTile-\(imageID)").firstMatch
  }

  /// What the harness can actually SEE of the bar, recorded BEFORE anything asserts reachability.
  /// A bare "Activation point invalid and no suggested hit points based on element frame" says
  /// nothing about which control, at what size, in what tree — this makes a red run decisive
  /// instead of another round of hypotheses.
  private func recordBarGeometry(
    _ app: XCUIApplication, configuration: String, tierProbe: String,
    controls: [(String, XCUIElement)]
  ) {
    XCTContext.runActivity(named: "Action-bar geometry (\(configuration))") { activity in
      var report = "configuration=\(configuration)\n"
      report += "orientation=\(XCUIDevice.shared.orientation.rawValue)\n"
      report += "app frame=\(app.frame)\n"
      // The tier the app itself says it rendered, stamped on the More control by the DEBUG
      // fixture — so a red run names the chosen layout instead of leaving it to be inferred
      // from the pixel deltas between control origins.
      report += "chosen \(tierProbe.isEmpty ? "tier=<probe missing>" : tierProbe)\n"
      var anomalous = false
      for (name, element) in controls {
        let exists = element.exists
        let frame = exists ? element.frame : .zero
        if !exists || frame.width < 1 || frame.height < 1 { anomalous = true }
        report += "\(name): exists=\(exists) enabled=\(exists && element.isEnabled) "
        report += "frame=\(frame)\n"
      }
      let geometry = XCTAttachment(string: report)
      geometry.name = "action-bar-geometry-\(configuration)"
      geometry.lifetime = .keepAlways
      activity.add(geometry)
      // Only on an anomaly, because the whole tree is large: it is the artefact that names the
      // real container an element ended up inside.
      if anomalous {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "element-tree-\(configuration)"
        tree.lifetime = .keepAlways
        activity.add(tree)
      }
    }
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testSelectModeRowCountsAndGatesTheMarkControls() throws {
    // BOTH iPad configurations. Portrait is Regular-2 (the grid is the wide content surface),
    // landscape is Regular-3 (the grid is the middle column of three) — different widths, and
    // the bar has to hold up in both. On the iPhone destination both are Compact, so the run is
    // simply the same assertions twice.
    for (configuration, landscape) in [("portrait", false), ("landscape", true)] {
      let app = launchInSelectMode(landscape: landscape)
      assertSelectModeRow(in: app, configuration: configuration)
      app.terminate()
    }
  }

  private func assertSelectModeRow(in app: XCUIApplication, configuration: String) {
    let caption = app.staticTexts["selectModeCaption"]
    XCTAssertTrue(
      caption.waitForExistence(timeout: 30),
      "\(configuration): Select mode is active but no mode row is on screen — the only way out "
        + "would be the More menu, which is the discoverability defect this phase closes.")

    let pick = app.buttons["gridPickButton"]
    let dislike = app.buttons["gridDislikeButton"]
    let undo = app.buttons["gridUndoButton"]
    let tag = app.buttons["gridTagButton"]
    let more = app.buttons["gridMoreMenu"]
    for control in [pick, dislike, undo, tag, more] {
      XCTAssertTrue(
        control.waitForExistence(timeout: 10),
        "\(configuration): a control is missing from the bar.")
    }

    // Clear is in the BAR when the column is wide enough and inside the MORE MENU when it is not
    // (`ActionBarMetrics.layout(forWidth:)` folds it below the six-control floor). Both are
    // chrome, neither is gesture-only, and which one this configuration renders is a width fact,
    // so the test resolves the control rather than assuming its surface.
    let clear = app.buttons["gridClearButton"]
    let clearIsInTheBar = clear.waitForExistence(timeout: 5)

    // ZERO selected: the row states the count rather than hiding it behind an instruction, and
    // every selection-consuming control refuses. This is IMGMGR-223's UI half.
    XCTAssertEqual(
      caption.label, "0 selected", "\(configuration): an explicit Select entry starts empty.")
    XCTAssertFalse(pick.isEnabled, "\(configuration): Pick must refuse an empty selection.")
    XCTAssertFalse(dislike.isEnabled, "\(configuration): Dislike must refuse an empty selection.")
    XCTAssertFalse(tag.isEnabled, "\(configuration): Tag must refuse an empty selection.")
    if clearIsInTheBar {
      XCTAssertFalse(clear.isEnabled, "\(configuration): Clear must refuse an empty selection.")
    }
    capture("Select-mode-row-zero-selected-\(configuration)")

    let firstTile = tile(1, in: app)
    let secondTile = tile(2, in: app)
    XCTAssertTrue(
      firstTile.waitForExistence(timeout: 10), "\(configuration): no grid tiles to select.")
    firstTile.tap()
    XCTAssertEqual(
      caption.label, "1 selected",
      "\(configuration): tapping a tile in Select mode must select it.")
    XCTAssertTrue(
      secondTile.waitForExistence(timeout: 5), "\(configuration): the second tile is missing.")
    secondTile.tap()

    // Attached BEFORE the assertions below, so the run keeps its visual evidence whatever the
    // verdict is — a failing capture is the more interesting one.
    capture("Select-mode-row-two-selected-\(configuration)")

    XCTAssertEqual(
      caption.label, "2 selected",
      "\(configuration): the mode row must state the count of what the next mark would write to.")
    XCTAssertTrue(
      pick.isEnabled,
      "\(configuration): Pick must be live in Select mode — it is the whole point of the phase; "
        + "only Pick LOCK entry stays disabled there.")
    XCTAssertTrue(dislike.isEnabled, "\(configuration): Dislike must be live on a selection.")
    XCTAssertTrue(tag.isEnabled, "\(configuration): Tag must be live on a selection.")

    var barControls = [("Pick", pick), ("Dislike", dislike), ("Tag", tag), ("More", more)]
    if clearIsInTheBar {
      XCTAssertTrue(clear.isEnabled, "\(configuration): Clear must be live on a selection.")
      barControls.append(("Clear", clear))
    }
    recordBarGeometry(
      app, configuration: configuration, tierProbe: (more.value as? String) ?? "",
      controls: barControls + [("Undo", undo), ("selectModeCaption", caption)])

    // Reachability, not just presence: `ActionBarMetrics` claims each tier keeps every control
    // at 44 pt in the width that selects it, and this is that claim at the rendered level. Undo
    // is excluded only because it is legitimately disabled until a mark commits — the
    // Clear-wiring test reaches it in its enabled state.
    for (name, control) in barControls {
      XCTAssertFalse(
        control.frame.isEmpty,
        "\(configuration): \(name) is rendered with an empty frame — see the "
          + "action-bar-geometry and element-tree attachments for the tree it ended up in.")
      // Containment, not merely non-emptiness: the landscape failure had a perfectly non-empty
      // 47×38.5 frame at x = -13.5, i.e. hanging off the window's left edge, which is what
      // "Activation point invalid and no suggested hit points" actually means. A bar wider than
      // its column overflows symmetrically, so this is the assertion that names it.
      XCTAssertTrue(
        app.frame.contains(control.frame),
        "\(configuration): \(name) is laid out at \(control.frame), outside the window "
          + "\(app.frame) — the bar is wider than the column it was given.")
      XCTAssertTrue(
        control.isHittable, "\(configuration): \(name) has no reachable hit region.")
    }

    // The folded half of the same contract: a narrower column MOVES Clear into the More menu, it
    // never removes the control.
    if !clearIsInTheBar {
      XCTAssertTrue(
        openPresentation(more, revealing: clear, timeout: 5),
        "\(configuration): Clear is in neither the bar nor the More menu — the fold dropped a "
          + "control instead of relocating it.")
      XCTAssertTrue(clear.isEnabled, "\(configuration): the folded Clear must be live too.")
      capture("Select-mode-folded-clear-\(configuration)")
      more.tap()
    }
  }

  /// The Clear control's WIRING, through the production button rather than the store: pressing
  /// the bar's Clear must actually drive the shipped mutation lane. Undo is the observable — it
  /// is disabled until a mark commits, so a Clear that is missing, inert, or wired to nothing
  /// leaves Undo disabled and turns this red. WHICH state Clear writes is pinned where it cannot
  /// drift instead: the button and `clearAppliesToTheSelectionFromTheGridBar` both read
  /// `ActionBarMarkControl.clear.state`, so there is no second declaration to disagree.
  /// Portrait only, deliberately: this is about the wiring, not about the layout tiers.
  func testClearControlInTheGridBarDrivesTheMarkLane() throws {
    let app = launchInSelectMode(landscape: false)

    let caption = app.staticTexts["selectModeCaption"]
    XCTAssertTrue(caption.waitForExistence(timeout: 30), "No Select mode row.")

    let clear = app.buttons["gridClearButton"]
    let undo = app.buttons["gridUndoButton"]
    XCTAssertTrue(clear.waitForExistence(timeout: 10), "The grid bar has no Clear control.")
    XCTAssertTrue(undo.waitForExistence(timeout: 10), "The grid bar has no Undo control.")
    XCTAssertFalse(undo.isEnabled, "Nothing has been written yet, so there is nothing to undo.")

    let firstTile = tile(1, in: app)
    XCTAssertTrue(firstTile.waitForExistence(timeout: 10), "No grid tiles to select.")
    firstTile.tap()
    XCTAssertEqual(caption.label, "1 selected", "Tapping a tile in Select mode must select it.")
    XCTAssertTrue(clear.isEnabled, "Clear must be live on a non-empty selection.")

    clear.tap()

    // `XCTWaiter` rather than `waitForExpectations(timeout:handler:)`: that handler closure
    // captures the test case itself, which Swift 6 refuses to send across the waiter's isolation
    // boundary (non-Sendable `XCTestCase`). Waiting for a result value needs no closure at all,
    // and the diagnostic message survives.
    let undoBecameAvailable = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: undo)
    let outcome = XCTWaiter().wait(for: [undoBecameAvailable], timeout: 15)
    XCTAssertEqual(
      outcome, .completed,
      "Tapping the bar's Clear committed nothing: Undo never became available, so that control "
        + "is not wired to the mark lane.")
    XCTAssertTrue(undo.isHittable, "Undo has no reachable hit region once it is enabled.")
  }
}
