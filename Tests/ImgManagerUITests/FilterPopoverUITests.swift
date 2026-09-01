import XCTest

/// WP16 P3 (IMGMGR-295), design record [/link/3332] decision 1: **filtering reaches the grid.**
/// A funnel in the grid's chrome, carrying the active-filter dot, opening a popover whose every
/// row states the count that row would deliver before it is applied.
///
/// **RED at `9a370a1`, three times over**, and this file COMPILES against that tree (it names no
/// app symbol — only XCUITest and identifier strings), so it can be run as a genuine RED gate:
///   1. nothing named `gridFilterControl` is in the hierarchy at all, so every test fails at its
///      first `waitForExistence`;
///   2. no `filterPopoverRow-*` element exists, so the row assertions have nothing to read; and
///   3. even once the control exists, `DebugStubTransport` at `9a370a1` answers `/api/facets`
///      with ONE mark row (`pick`, 3) and no `rating`, `ext` or `has_master` — so the `>= 4`
///      row's count would be 0 and `ratingRowCountIsPositive` fails. That third RED is the
///      fixture-expansion work item's own (B9); it closes only when the fixture is expanded.
///
/// Makes NO device-idiom decision (plan invariant (i)): every step keys off an OBSERVED element,
/// so the same assertions run against Regular's `.primaryAction` toolbar and against Compact's
/// persistent options row. The `gridShortcutHelpControl` leg is the "the row did not overflow"
/// contract on Compact and the "the fifth toolbar item did not push anything into the chevron"
/// contract on Regular — one assertion, both meanings, no branch.
final class FilterPopoverUITests: XCTestCase {

  /// Device orientation is simulator-global and survives across test classes (the lesson
  /// `ViewOptionsScreenshotUITests` records). Pinned on the way in AND restored on the way out.
  override func setUp() {
    super.setUp()
    XCUIDevice.shared.orientation = .portrait
  }

  override func tearDown() {
    XCUIDevice.shared.orientation = .portrait
    super.tearDown()
  }

  /// Launched with the inspector suppressed on purpose: decision 1 is about filtering WITHOUT the
  /// inspector, and WP16 P2 moved the facets trigger out of it, so the counts these rows state
  /// must arrive on a screen the Stats tab was never on.
  private func launchedApp(landscape: Bool = false) -> XCUIApplication {
    if landscape { XCUIDevice.shared.orientation = .landscapeLeft }
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestInspectorHidden"]
    app.launch()
    XCTAssertTrue(
      app.descendants(matching: .any)["gridDislikeButton"].waitForExistence(timeout: 30),
      "Action bar (gridDislikeButton) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else (sign-in, blank, or a failed stub).")
    if landscape {
      // The rotation's own layout pass, then the resolver's `.onGeometryChange` reaction to it —
      // the same settle this target's siblings wait out before reading geometry-dependent state.
      Thread.sleep(forTimeInterval: 2.0)
    }
    return app
  }

  private func funnel(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["gridFilterControl"]
  }

  private func row(_ app: XCUIApplication, _ field: String, _ value: String) -> XCUIElement {
    app.descendants(matching: .any)["filterPopoverRow-\(field)-\(value)"]
  }

  /// A row publishes its live count as its accessibility VALUE, so the number is readable without
  /// parsing a rendered label (and without asserting a locale's own digit grouping).
  private func count(of element: XCUIElement) -> Int? {
    guard let value = element.value as? String else { return nil }
    return Int(value)
  }

  // MARK: - The funnel is chrome, and it cost nothing that was already there

  func testTheFunnelIsOnAPrimarySurfaceAndNothingWasPushedIntoAnOverflowChevron() {
    let app = launchedApp()

    let filter = funnel(app)
    XCTAssertTrue(
      filter.waitForExistence(timeout: 10),
      "The filter funnel is not on a primary surface — nothing named 'gridFilterControl' is in "
        + "the hierarchy without opening an overflow menu. Decision 1 puts filtering in the "
        + "grid's own chrome.")
    XCTAssertTrue(filter.isHittable, "The funnel exists but cannot be tapped where it is.")

    // The named risk of this phase: the funnel is a FIFTH `.primaryAction` item on Regular and a
    // fifth control on Compact's options row. Both failure modes are one assertion each.
    XCTAssertTrue(
      app.descendants(matching: .any)["gridShortcutHelpControl"].isHittable,
      "The shortcut-help control is no longer hittable once the funnel joined its surface — on "
        + "Compact the options row overflowed, on Regular the toolbar collapsed. Either way a "
        + "shipped control was displaced by decision 1, which the parity table forbids.")

    // Positive control in the same check (LSN-0033), so the 0-hit assertion below cannot pass
    // vacuously on a blank or crashed screen.
    XCTAssertTrue(
      app.descendants(matching: .any)["gridDislikeButton"].exists,
      "Positive control failed: the action bar is gone, so the 0-hit overflow check below would "
        + "pass vacuously.")
    XCTAssertFalse(
      app.buttons["OverflowBarButtonItem"].exists,
      "A toolbar overflow chevron appeared once the funnel joined the primary surface — a "
        + "view-option control is now reachable only behind it, the exact regression "
        + "SortGroupScreenshotUITests was written to catch.")
  }

  // MARK: - Every row states the count it would deliver

  func testTheOpenPopoverShowsTheDeclaredRowsEachWithALiveCount() {
    let app = launchedApp(landscape: true)

    // The precondition decision 1 is about: no inspector on screen, so these counts cannot have
    // been fetched by the Stats tab appearing.
    XCTAssertFalse(
      app.buttons["Stats"].exists,
      "The inspector is on screen, so this test would not be observing filtering that reached "
        + "the grid on its own.")
    XCTAssertTrue(
      app.descendants(matching: .any)["gridDislikeButton"].exists,
      "Positive control failed: the grid is gone, so the absence check above is vacuous.")

    let filter = funnel(app)
    XCTAssertTrue(filter.waitForExistence(timeout: 10), "No 'gridFilterControl' in the hierarchy.")
    filter.tap()

    let rating4 = row(app, "rating", "4")
    XCTAssertTrue(
      rating4.waitForExistence(timeout: 10),
      "The open popover has no '>= 4' rating row — decision 1's '>=stars' rows are missing.")
    XCTAssertEqual(
      rating4.label, "≥ 4",
      "The rating row is not labelled with the '>=' it actually applies (`rating_min`).")
    let rating4Count = count(of: rating4)
    XCTAssertNotNil(
      rating4Count,
      "The '>= 4' row states no numeric count (value: \(String(describing: rating4.value))). "
        + "Decision 1 asks for the LIVE result count on each row before applying.")
    // The fixture-expansion RED (B9): at `9a370a1` the stub sends no `rating` dimension at all,
    // so this is 0 and this assertion is what the expanded fixture closes.
    XCTAssertGreaterThan(
      rating4Count ?? 0, 0,
      "The '>= 4' row states 0 against the DEBUG fixture. Either the fixture still answers "
        + "/api/facets with the one-row response, or the suffix sum is not being computed.")

    let unmarked = row(app, "mark", "none")
    XCTAssertTrue(
      unmarked.waitForExistence(timeout: 5),
      "The popover has no 'Unmarked' row — the tri-state mark row is not tri-state.")
    XCTAssertEqual(unmarked.label, "Unmarked")
    XCTAssertNotNil(count(of: unmarked), "The 'Unmarked' row states no numeric count.")

    let edited = row(app, "hasMaster", "true")
    XCTAssertTrue(
      edited.waitForExistence(timeout: 5),
      "The popover has no 'Edited in Lightroom' row (decision 2 resolves Edited to `has_master`).")
    XCTAssertEqual(edited.label, "Edited in Lightroom")
    XCTAssertNotNil(count(of: edited), "The 'Edited in Lightroom' row states no numeric count.")

    // Type takes its values from the response (`ext` is a free-form string in the contract, with
    // no vocabulary to declare from), so the row is addressed by the fixture's own value.
    let type = row(app, "ext", "jpg")
    XCTAssertTrue(
      type.waitForExistence(timeout: 5),
      "The popover has no Type row for the fixture's own file type.")
    XCTAssertNotNil(count(of: type), "The Type row states no numeric count.")

    // B7: no Camera row, and no `camera_preview_only` substituted for one.
    XCTAssertEqual(
      app.descendants(matching: .any).matching(
        identifier: "filterPopoverRow-cameraPreviewOnly-true"
      ).count, 0,
      "A `camera_preview_only` row is standing in for the Camera row decision 1 omits (B7).")

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "P3-popover-marks"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTContext.runActivity(
      named: ">=4: \(String(describing: rating4.value)) · Unmarked: "
        + "\(String(describing: unmarked.value)) · Edited: \(String(describing: edited.value)) "
        + "· Type: \(String(describing: type.value)) · captured \(screenshot.image.size)"
    ) { _ in }
  }

  /// B2, asserted on the ENABLED STATE rather than on absence: a named row whose dimension has no
  /// results renders a live 0 and is not tappable — it never vanishes, because a named row that
  /// disappears is the opposite of a live count.
  func testAZeroCountRowIsRenderedDisabledRatherThanOmitted() {
    let app = launchedApp(landscape: true)

    let filter = funnel(app)
    XCTAssertTrue(filter.waitForExistence(timeout: 10), "No 'gridFilterControl' in the hierarchy.")
    filter.tap()

    // The fixture answers `mark` with all three states and a ZERO among them (B9), so this row is
    // a real live zero rather than a contrived one.
    let dislike = row(app, "mark", "dislike")
    XCTAssertTrue(
      dislike.waitForExistence(timeout: 10),
      "The zero-count Dislike row was OMITTED from the popover. B2: a declared row renders its "
        + "live 0, it never vanishes.")
    XCTAssertEqual(
      count(of: dislike), 0,
      "The Dislike row does not state the fixture's own zero (value: "
        + "\(String(describing: dislike.value))).")
    XCTAssertFalse(
      dislike.isEnabled,
      "The zero-count Dislike row is still tappable — applying it would empty the grid, which is "
        + "why B2 renders a 0-count row disabled.")

    // Positive control for that enabled-state reading: a row WITH results on the same surface
    // is enabled, so `isEnabled == false` above reports this row, not a dead hierarchy.
    let unmarked = row(app, "mark", "none")
    XCTAssertTrue(unmarked.exists, "Positive control failed: the mark section is not on screen.")
    XCTAssertTrue(
      unmarked.isEnabled,
      "Positive control failed: the Unmarked row is disabled too, so the disabled assertion "
        + "above proves nothing about the zero-count rule.")
  }

  // MARK: - The tap routes through the shipped filter lane, and the dot follows it

  func testTappingARatingRowAppliesTheFilterAndTheFunnelGainsAndLosesItsDot() {
    let app = launchedApp(landscape: true)

    let filter = funnel(app)
    XCTAssertTrue(filter.waitForExistence(timeout: 10), "No 'gridFilterControl' in the hierarchy.")
    XCTAssertEqual(
      filter.value as? String, "Off",
      "The funnel reports an active filter at launch, before anything was applied.")

    filter.tap()
    let rating4 = row(app, "rating", "4")
    XCTAssertTrue(rating4.waitForExistence(timeout: 10), "The popover has no '>= 4' row.")
    rating4.tap()

    // The popover closes on the tap, and the funnel — reading the SAME
    // `InspectorFacetFilters.activeCount` predicate the Info button uses — gains its dot.
    let active = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Active"), object: funnel(app))
    XCTAssertEqual(
      XCTWaiter().wait(for: [active], timeout: 10), .completed,
      "Tapping '>= 4' did not put the funnel into its active-filter state — the tap did not "
        + "reach `GridStore.applyFacetFilter`, or the dot reads a different predicate than the "
        + "filter it indicates.")

    let filtered = XCUIScreen.main.screenshot()
    let filteredAttachment = XCTAttachment(screenshot: filtered)
    filteredAttachment.name = "P3-funnel-active-dot"
    filteredAttachment.lifetime = .keepAlways
    add(filteredAttachment)

    // Second tap on the SAME row clears the dimension (one value per dimension — the shipped
    // chip semantics), and the dot goes with it.
    funnel(app).tap()
    let rating4Again = row(app, "rating", "4")
    XCTAssertTrue(
      rating4Again.waitForExistence(timeout: 10),
      "The popover did not reopen, so the second-tap-clears rule could not be exercised.")
    rating4Again.tap()

    let cleared = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Off"), object: funnel(app))
    XCTAssertEqual(
      XCTWaiter().wait(for: [cleared], timeout: 10), .completed,
      "Tapping the already-active '>= 4' row did not clear it — the funnel still reports an "
        + "active filter, so the popover and the filter it applies have drifted apart.")
  }
}
