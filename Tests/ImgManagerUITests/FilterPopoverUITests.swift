import XCTest

/// WP16 P3 (IMGMGR-295), design record [/link/3332] decision 1: **filtering reaches the grid.**
/// A funnel in the grid's chrome, carrying the active-filter dot, opening a popover whose every
/// row states the count that row would deliver before it is applied.
///
/// **RED at `9a370a1`**, and this file COMPILES against that tree (it names no app symbol — only
/// XCUITest and identifier strings), so it can be run as a genuine RED gate: nothing named
/// `gridFilterControl` is in the hierarchy, so every test fails at its first `waitForExistence`,
/// and no `filterPopoverRow-*` element exists, so the row assertions have nothing to read.
///
/// **What this RED does NOT witness (diff-gate round 1, B2).** An earlier version of this comment
/// claimed a third, independent RED for the fixture expansion — that the `>= 4` row's count would
/// read 0 against the old one-row stub. That is false. With no funnel and no rows in the tree,
/// the count assertion fails on a MISSING ELEMENT whatever the fixture holds, so it cannot
/// discriminate a thin fixture from an absent surface. The fixture expansion has no isolated RED;
/// `DebugStubFacetsFixtureTests` pins its shape post hoc and says so in its own doc comment.
///
/// **WP21 P2 (IMGMGR-376 / -339) extends this file**, in the same both-destination idiom and for
/// the same reason: the new assertions name only identifier strings and literals, so they compile
/// against the pre-change tree and fail on it — `filterPopoverRow-camera-*` is in no hierarchy at
/// `87497ce` (no Camera declaration exists), and the scene card's spoken sentence carries no
/// "edited" clause there, so `testTheSceneCardsPencilCarriesTheEditedCount` fails on the label it
/// reads. Neither RED needs an app symbol.
///
/// Makes NO device-idiom decision (plan invariant (i)): every step keys off an OBSERVED element,
/// so the same assertions run against Regular's `.primaryAction` toolbar and against Compact's
/// persistent options row. The displaced-control leg is `gridShortcutHelpControl` — "the row did
/// not overflow" — on Compact, and since WP29 P1 `gridMoreMenu` — "nothing was pushed into the
/// chevron" — on Regular; the branch keys off the observed shell (`rendersCompactShell`).
final class FilterPopoverUITests: OrientationPinnedUITestCase {

  /// Launched with the inspector off screen on purpose: decision 1 is about filtering WITHOUT the
  /// inspector, and WP16 P2 moved the facets trigger out of it, so the counts these rows state
  /// must arrive on a screen the Stats tab was never on. That took a launch argument of its own
  /// until IMGMGR-390 made the collapsed workspace the LAUNCH state — a plain launch is now
  /// exactly the screen this file needs, at every width.
  private func launchedApp(landscape: Bool = false) -> XCUIApplication {
    if landscape { XCUIDevice.shared.orientation = .landscapeLeft }
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
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

    // The named risk of this phase, asserted unconditionally again: the funnel joined a surface
    // that already carried the shortcut-help control — Regular's toolbar and Compact's options
    // row both — and that shipped control must still be reachable on whichever one this
    // destination renders. On Compact this IS the "the options row did not overflow" check the
    // plan asks for; on Regular it is the "nothing was pushed into the chevron" half.
    //
    // (WP16 P3 briefly removed the Regular copy as the plan's pre-decided pivot and this
    // assertion was softened to match. Both are reverted: the pivot cost a shipped control its
    // only Regular route and failed `ViewOptionsScreenshotUITests`, while WP16 P2's two-column
    // Regular-3 is what actually gave the bar room.)
    //
    // WP29 P1 (IMGMGR-452, plan Decision 1): "?" left the REGULAR bar, so there the displaced-
    // control check reads the bar's LAST app item, More — the first to fall into the chevron.
    let lastOnSurface = rendersCompactShell(app) ? "gridShortcutHelpControl" : "gridMoreMenu"
    XCTAssertTrue(
      app.descendants(matching: .any)[lastOnSurface].firstMatch.isHittable,
      "'\(lastOnSurface)' is no longer hittable once the funnel joined its surface — on "
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

    let rating4 = row(app, "rating", "4")
    XCTAssertTrue(
      openPresentation(filter, revealing: rating4, timeout: 10),
      "The open popover has no '>= 4' rating row — decision 1's '>=stars' rows are missing.")
    // REGRESSION GUARD, from the gate run on 5e2e9d4: every DECLARED row must be an ADDRESSABLE
    // element, not one that would appear after a scroll. That run realised only the four rows
    // fitting the compact sheet — the popover used a `List`, which built nothing below the fold —
    // so `mark-none`, `mark-dislike`, `hasMaster-true` and both Type rows were absent from the
    // accessibility tree entirely, while the four it did build carried perfect identifiers.
    // Enumerated in ONE place, so the whole class fails here naming exactly which rows vanished
    // rather than one assertion at a time further down.
    //
    // Spelled out rather than derived from `FilterPopoverModel.sections`, and not for convenience:
    // XCUITest runs OUT OF PROCESS against an installed app, so this target links no app module —
    // every file in it imports only XCTest/Foundation/UIKit, and pulling an app target into a UI
    // test bundle to share a declaration is not a small change. The literals are the price of
    // that boundary; `FilterPopoverModelTests` holds the model's own copy, and the two meeting is
    // what this assertion checks. A cheaper future link would be a DEBUG probe element carrying
    // the declared row count, the idiom `debugProbe` already uses.
    let declared = [
      "filterPopoverRow-rating-3", "filterPopoverRow-rating-4", "filterPopoverRow-rating-5",
      "filterPopoverRow-mark-pick", "filterPopoverRow-mark-none", "filterPopoverRow-mark-dislike",
      "filterPopoverRow-hasMaster-true", "filterPopoverRow-ext-jpg", "filterPopoverRow-ext-arw",
      // WP21 P2: response-discovered like Type, from the DEBUG fixture's own `camera` facet —
      // the two bodies `fixtureGroupKey` already groups the twelve stub photographs by. The
      // identifier is `filterPopoverRow-<field>-<value>` verbatim (`FilterPopoverRow.id`), so
      // the server's own value, spaces and all, is what addresses the row.
      "filterPopoverRow-camera-SONY ILCE-7RM5", "filterPopoverRow-camera-FUJIFILM X-T2",
    ]
    let missing = declared.filter { !app.descendants(matching: .any)[$0].exists }
    XCTAssertTrue(
      missing.isEmpty,
      "Declared rows absent from the popover's accessibility tree: \(missing). A row that only "
        + "exists once scrolled into being is omitted as far as decision 1 is concerned — check "
        + "the popover is not rendering its rows lazily.")

    XCTAssertEqual(
      rating4.label, "≥ 4",
      "The rating row is not labelled with the '>=' it actually applies (`rating_min`).")
    let rating4Count = count(of: rating4)
    XCTAssertNotNil(
      rating4Count,
      "The '>= 4' row states no numeric count (value: \(String(describing: rating4.value))). "
        + "Decision 1 asks for the LIVE result count on each row before applying.")
    // Guards the expanded fixture going forward: a stub that stopped sending `rating` would make
    // this row read 0. NOT an isolated RED for the fixture (see this class's doc comment, B2) —
    // against `9a370a1` it fails on the missing element, not on the count.
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

    // WP21 P2 (IMGMGR-376 / -339), the shipped rule that replaces B7's default: the Camera
    // dimension IS offered now that img-manager v0.20.0 serves `ImageFacets.camera` and a
    // `camera` filter parameter, and its values come from the RESPONSE — never derived here.
    let camera = row(app, "camera", "SONY ILCE-7RM5")
    XCTAssertTrue(
      camera.waitForExistence(timeout: 5),
      "The popover has no Camera row for the fixture's own camera body — the one filter "
        + "dimension WP21 P2 adds is missing from the surface that offers it.")
    XCTAssertEqual(
      camera.label, "SONY ILCE-7RM5",
      "The Camera row does not carry the server's own value verbatim.")
    let cameraCount = count(of: camera)
    XCTAssertNotNil(camera.value as? String, "The Camera row states no count at all.")
    XCTAssertGreaterThan(
      cameraCount ?? 0, 0,
      "The Camera row states 0 against the DEBUG fixture, whose `camera` facet answers with two "
        + "real bodies — either the fixture lost its `camera:` values or the counts are not "
        + "being read off `ImageFacets.camera`.")
    XCTAssertTrue(
      camera.isEnabled, "A Camera row with results is not tappable.")

    // The SECOND body, so the section is response-discovered rather than one hard-coded row.
    let camera2 = row(app, "camera", "FUJIFILM X-T2")
    XCTAssertTrue(
      camera2.waitForExistence(timeout: 5),
      "The popover offers only one camera body — the section is not reading the response's own "
        + "value list.")

    // The stated cap's notice row (diff-gate B1). It is asserted here by ABSENCE and not added to
    // the `declared` addressability set above, which asserts presence: the DEBUG fixture answers
    // `camera` with two bodies — inside `FilterPopoverModel.cameraValueLimit` — so nothing was
    // truncated and a "+N more cameras" row would be stating something untrue. The PRESENCE case
    // has no honest UI leg without inventing a wire shape the server never sends for twelve
    // photographs (`DebugStubFacetsFixtureTests` pins camera to a partition of those twelve), so
    // it is proven in `FilterPopoverModelTests.theCameraSectionIsCappedAtItsStatedHead` against a
    // 20-body response instead. The two camera rows asserted above are this check's positive
    // control: the section IS on screen, so the zero hits below are the rule and not a blank.
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "filterPopoverRow-camera-more").count,
      0,
      "The popover shows a truncation notice against a two-body fixture — the cap announced an "
        + "overflow that did not happen.")

    // Unchanged from B7 and still the point: `camera_preview_only` answers a DIFFERENT question
    // ("is this image's best source the camera's own preview") and is not a stand-in for the
    // Camera dimension. It must still not be a popover row now that a real one exists.
    XCTAssertEqual(
      app.descendants(matching: .any).matching(
        identifier: "filterPopoverRow-cameraPreviewOnly-true"
      ).count, 0,
      "A `camera_preview_only` row is standing beside the real Camera row — the popover offers "
        + "the wrong dimension under the owner's word.")

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

    // The fixture answers `mark` with all three states and a ZERO among them (B9), so this row is
    // a real live zero rather than a contrived one.
    let dislike = row(app, "mark", "dislike")
    XCTAssertTrue(
      openPresentation(filter, revealing: dislike, timeout: 10),
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

    let rating4 = row(app, "rating", "4")
    XCTAssertTrue(
      openPresentation(filter, revealing: rating4, timeout: 10),
      "The popover has no '>= 4' row.")
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
    let rating4Again = row(app, "rating", "4")
    XCTAssertTrue(
      openPresentation(funnel(app), revealing: rating4Again, timeout: 10),
      "The popover did not reopen, so the second-tap-clears rule could not be exercised.")
    rating4Again.tap()

    let cleared = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Off"), object: funnel(app))
    XCTAssertEqual(
      XCTWaiter().wait(for: [cleared], timeout: 10), .completed,
      "Tapping the already-active '>= 4' row did not clear it — the funnel still reports an "
        + "active filter, so the popover and the filter it applies have drifted apart.")
  }

  // MARK: - WP21 P2: the scene card's pencil carries `edited_count` (IMGMGR-339)

  /// The badge half of WP21 P2, on the real surface and on BOTH destinations.
  ///
  /// **Read off the CARD's own spoken sentence, not off `sceneEdited` as an element**, and that is
  /// a deliberate correction of the phase's acceptance wording rather than a shortcut.
  /// `SceneCardView.cell` ends in `.accessibilityElement(children: .combine)` with its own
  /// `.accessibilityLabel`, so the badge cluster's identifiers are merged away and no descendant
  /// named `sceneEdited` is in the hierarchy to find — which is exactly why the shipped
  /// `SceneBandScreenshotUITests` asserts the pick count as `card.label.contains("2 picked")`
  /// rather than by identifier. The identifier stays on the pencil (it is what a future
  /// non-combined card would expose, and it is what `MarkPalette` colouring hangs beside), but an
  /// assertion on it would fail on a tree that never contained it.
  ///
  /// RED at `87497ce`: there the card announces "Scene of 5 photos, closed, 2 picked" and the
  /// pencil is a glyph with no number, so the `2 edited` clause is absent.
  func testTheSceneCardsPencilCarriesTheEditedCount() {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestEnterSceneMode"]
    app.launch()

    XCTAssertTrue(
      app.descendants(matching: .any)["gridDislikeButton"].waitForExistence(timeout: 30),
      "Action bar (gridDislikeButton) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid in Scene mode, got something else.")

    let card = app.descendants(matching: .any)["sceneCard"].firstMatch
    XCTAssertTrue(
      card.waitForExistence(timeout: 20),
      "No scene card is on screen — the fixture never entered Scene mode with data, so the "
        + "badge assertion below would be vacuous.")

    // The fixture scene holds five members, two of them edited (`fixtureStackRow`'s
    // `editedCount`), so a card that still draws a bare pencil — or draws the pick count where
    // the edit count belongs — fails here. `2 edited` cannot be satisfied by `2 picked`.
    XCTAssertTrue(
      card.label.contains("2 edited"),
      "The collapsed card does not carry `edited_count`. Label: '\(card.label)'")

    // POSITIVE CONTROL in the same reading: the clause the card ALREADY said is still there, so
    // the hit above is an added clause rather than a rewritten sentence.
    XCTAssertTrue(
      card.label.contains("2 picked"),
      "Positive control failed: the pick count left the card's sentence. Label: "
        + "'\(card.label)'")

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "P2-scene-edited-count"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTContext.runActivity(named: "card: '\(card.label)'") { _ in }
  }
}
