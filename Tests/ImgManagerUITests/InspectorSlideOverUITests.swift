import UIKit
import XCTest

/// WP13 P10 (IMGMGR-219), on the real simulator surface. Two jobs, one code path:
///
/// 1. **The phase's live probe** — which real configurations resolve to which layout mode. The
///    classification uses only facts INDEPENDENT of the inspector, in this order: the measured
///    window width against the resolver's own Regular-3 pin identifies Regular-3, and below that
///    pin the queue's presence beside the grid separates Regular-2 from Compact. The order
///    matters — at Regular-3 the queue is legitimately off screen (see the note at the
///    classification itself), so a sidebar-first split would call a 1376 pt iPad "Compact".
///    It deliberately does NOT read the "Folders" disclosure — P6
///    (IMGMGR-216) gives Compact that same section, so its presence stops meaning "Regular".
///    Width alone cannot make the Compact/Regular split either: the measured anchors are 874 pt
///    Compact (iPhone landscape) and 1032 pt Regular-2 (iPad portrait), while a genuine iPad
///    half-window is Regular from ~667 pt up — no width floor separates those. Production makes
///    the same call for the same reason: `horizontalSizeClass` gates B2 and `LayoutMode.swift`'s
///    B2 section records why reimplementing it as a width would be a guess. The queue beside the
///    grid is that trait's visible consequence in the sub-pin range, which is why it is the input
///    there and only there. The inspector's presence is never an input — it is what these
///    tests are here to judge, so using it would let a wrong presentation relabel the layout and
///    pass (diff-gate round 1, blocking finding 1). Never a device idiom — this target is inside
///    the gate's device-idiom absence grep like every other source directory.
///
/// 2. **The acceptance assertion** — at Regular-2 the inspector is a NON-MODAL panel: the grid's
///    own controls stay hittable beside it. Under the pre-P10 modal sheet that assertion fails,
///    which is exactly the RED this phase had to observe before flipping the placement.
///
/// Both `bin/mac-gate.sh` destinations run this file, and each asserts the contract of the mode
/// it actually resolved — so the iPhone leg pins "Compact still presents the sheet" through the
/// same code that pins the slide-over on the iPad leg.
final class InspectorSlideOverUITests: OrientationPinnedUITestCase {

  private enum ResolvedLayout: String {
    case compact
    case regular2
    case regular3
  }

  /// Mirrors `LayoutResolver.regular3Threshold`. A UI-test bundle DRIVES an installed app rather
  /// than linking it, so the app module cannot be imported here and the pin has to be duplicated
  /// as a literal. `LayoutPresentationTests.theRegular3WidthPinMatchesTheUITestLiteral` is the
  /// join that keeps the two honest: move the production pin and that test fails, naming this
  /// literal as the thing that must move with it.
  private static let regular3WidthThreshold: CGFloat = 1197

  func testInspectorPresentationInPortrait() {
    assertInspectorContract(orientation: .portrait, orientationName: "portrait")
  }

  func testInspectorPresentationInLandscape() {
    assertInspectorContract(orientation: .landscapeLeft, orientationName: "landscape")
  }

  private func assertInspectorContract(
    orientation: UIDeviceOrientation, orientationName: String
  ) {
    XCUIDevice.shared.orientation = orientation

    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    let dislike = app.buttons["Dislike"]
    XCTAssertTrue(
      dislike.waitForExistence(timeout: 30),
      "Action bar (Dislike) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else (sign-in, blank, or a failed stub).")

    // The rotation's own layout pass, then the resolver's `.onGeometryChange` reaction to it.
    Thread.sleep(forTimeInterval: 2.0)

    // The sidebar column's own first row. It used to be a queue card from the stub's fixture
    // ("40 photos · 10 picked"); IMGMGR-350 made the home the tier tree, so no card is rendered
    // on any width and that predicate now matches nothing anywhere — which would classify every
    // width below the Regular-3 pin as Compact. The tier row asks the same question of the same
    // column: is the sidebar on screen beside the grid?
    let sidebarRow = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    let statsSegment = app.buttons["Stats"]
    let chromeInfo = app.navigationBars.buttons
      .matching(NSPredicate(format: "label BEGINSWITH 'Info'")).firstMatch

    let width = app.frame.size.width

    // The grid is on screen in EVERY layout, so it is the one input whose absence would make the
    // sidebar reading below meaningless rather than informative. Asserted first, so that
    // `sidebarIsBesideTheGrid` is unambiguously a statement about the SIDEBAR.
    XCTAssertTrue(
      dislike.isHittable,
      "The grid must be reachable in every layout — a pane reading taken while the grid itself "
        + "is missing classifies nothing.")

    // Is the SIDEBAR on screen beside the grid? True only at Regular-2.
    let sidebarIsBesideTheGrid = sidebarRow.isHittable && dislike.isHittable
    // Read, but NEVER used to classify — asserted per branch below instead.
    let inspectorAlreadyOnScreen = statsSegment.exists
    let hasChromeInfo = chromeInfo.exists

    // Width FIRST, sidebar second — and only below the pin. Integration finding on merged main
    // 428694d: at Regular-3 the queue is legitimately NOT on screen. The app asks for
    // `columnVisibility == .all`, but under `.prominentDetail` the OS still renders only
    // content + detail at these widths — exactly what `LayoutMode.swift`'s Pass 3 recorded (43
    // samples, 672–1376 pt, rendered pane count constant at 2, "sidebar never shown"). The
    // landscape probe proves it directly: 1376 pt with the permanent inspector up
    // (inspectorAtLaunch=true, chromeInfo=false) and no queue card in the hierarchy. So a
    // sidebar-first split mis-reads Regular-3 as Compact; the sidebar only ever separates
    // Compact from Regular-2, which is the one range where the width pin cannot.
    let resolved: ResolvedLayout =
      width >= Self.regular3WidthThreshold
      ? .regular3
      : (sidebarIsBesideTheGrid ? .regular2 : .compact)

    // The probe's record. `print` (not only an activity) because the gate copies back the
    // xcodebuild log, which is where this has to be readable afterwards.
    print(
      "P10-PROBE \(orientationName): window=\(app.frame.size) "
        + "sidebarBesideGrid=\(sidebarIsBesideTheGrid) "
        + "inspectorAtLaunch=\(inspectorAlreadyOnScreen) chromeInfo=\(hasChromeInfo) "
        + "resolvedLayout=\(resolved.rawValue)")
    attach(app: app, named: "P10-\(orientationName)-\(resolved.rawValue)-atLaunch")

    switch resolved {
    case .compact:
      XCTAssertTrue(
        hasChromeInfo, "Compact must reach the inspector from the persistent chrome control.")
      XCTAssertFalse(
        inspectorAlreadyOnScreen,
        "Compact's inspector is a sheet reached from chrome — it must not already be on screen.")
      chromeInfo.tap()
      XCTAssertTrue(
        statsSegment.waitForExistence(timeout: 10), "The inspector never appeared after Info.")
      // Fold item 7's ONE Info/Stats sheet is modal by design and STAYS modal at Compact — the
      // grid behind it is covered, so its controls are not hittable. This is the pin that keeps
      // P10's reversal scoped to the one width it is meant for.
      XCTAssertFalse(
        dislike.isHittable,
        "Compact must still present the modal sheet — the grid is not reachable behind it.")

    case .regular2:
      XCTAssertTrue(
        hasChromeInfo, "Regular-2 must reach the inspector from the persistent chrome control.")
      // The other half of blocking finding 1: at this width a PERMANENT inspector is wrong. The
      // slide-over is opened from chrome, so nothing inspector-shaped may be on screen yet.
      XCTAssertFalse(
        inspectorAlreadyOnScreen,
        "Regular-2's inspector must be opened from chrome, never permanently on screen.")
      chromeInfo.tap()
      XCTAssertTrue(
        statsSegment.waitForExistence(timeout: 10), "The inspector never appeared after Info.")
      // THE phase assertion ([/link/3220] §2.2, IMGMGR-219): a slide-over, not a modal. The grid
      // is still on screen AND still takes taps beside the panel. RED under the shipped sheet.
      XCTAssertTrue(
        dislike.isHittable,
        "Regular-2's inspector must not block the grid — a panel that stops the grid taking "
          + "taps is the modal sheet with a different animation.")
      assertTheChromeControlReportsTheActiveFilterCount(app: app, chromeInfo: chromeInfo)

    case .regular3:
      assertTheRegular3InspectorCollapsesAndRestores(
        app: app, chromeInfo: chromeInfo, statsSegment: statsSegment, dislike: dislike,
        hasChromeInfo: hasChromeInfo, inspectorAlreadyOnScreen: inspectorAlreadyOnScreen,
        orientationName: orientationName)
    }

    attach(app: app, named: "P10-\(orientationName)-\(resolved.rawValue)-inspectorShown")
  }

  /// WP16 P2 (IMGMGR-298), the Codex delta blocker: the collapse that reclaims the inspector's
  /// width does it by swapping the workspace between the three-column and two-column
  /// `NavigationSplitView` shapes, which moves `GridView` to a different slot — a new structural
  /// identity, so SwiftUI builds a fresh `ScrollView` at offset zero. `GridStore` keeps the page,
  /// the selection and the focus; the scroll offset had no preservation path at all, so a reader
  /// deep inside a shoot who hid the inspector landed back at the top.
  ///
  /// **The EXPAND leg is the falsifier, and this says so rather than letting three legs look
  /// equally load-bearing.** Collapsed, the grid is the whole 1376 pt window and the fixture's
  /// twelve tiles may well all fit, so "tile 12 is still on screen" can pass there for the wrong
  /// reason. Re-expanded, the grid is the ~209 pt column again — where tile 12 shows ONLY if the
  /// offset was restored, and where a lost offset puts tile 1 back on screen. Those two
  /// readings are asserted as a pair, so neither a blank screen nor an all-tiles-visible layout
  /// can satisfy them together.
  ///
  /// Against `0b04220` both expand-leg assertions fail: nothing carried the offset across the
  /// rebuild, so the re-expanded grid is at the top with tile 1 showing and tile 12 far below.
  func testRegular3CollapsePreservesTheGridScrollPosition() {
    XCUIDevice.shared.orientation = .landscapeLeft

    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    let dislike = app.buttons["Dislike"]
    XCTAssertTrue(
      dislike.waitForExistence(timeout: 30),
      "Action bar (Dislike) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else.")
    Thread.sleep(forTimeInterval: 2.0)

    // Width, never an idiom: the iPhone destination has no Regular-3 to collapse, and a test that
    // asserted one there would be asserting a layout the device cannot resolve. Recorded, not
    // silently skipped.
    guard app.frame.size.width >= Self.regular3WidthThreshold else {
      print(
        "WP16P2-SCROLL \(app.frame.size): below the Regular-3 pin "
          + "(\(Self.regular3WidthThreshold)) — no third column here to collapse")
      return
    }

    let chromeInfo = app.navigationBars.buttons
      .matching(NSPredicate(format: "label BEGINSWITH 'Info'")).firstMatch
    let firstTile = app.descendants(matching: .any)["gridTile-1"]
    let lastTile = app.descendants(matching: .any)["gridTile-12"]
    let gridScroll = app.scrollViews.containing(.any, identifier: "gridTile-1").firstMatch
    XCTAssertTrue(
      gridScroll.waitForExistence(timeout: 10),
      "No scrollable grid containing the fixture's tiles — the twelve `gridTile-<id>` elements "
        + "are what this test scrolls through.")

    var swipes = 0
    while !lastTile.isHittable && swipes < 12 {
      gridScroll.swipeUp()
      swipes += 1
    }
    XCTAssertTrue(
      lastTile.isHittable,
      "Could not scroll the last fixture tile into view after \(swipes) swipes — the rest of "
        + "this test has no deep position to preserve.")
    // Positive control for the whole test: we really did travel. If the grid never scrolled, tile
    // 1 would still be on screen and every "position preserved" reading below would be vacuous.
    XCTAssertFalse(
      firstTile.isHittable,
      "The grid did not actually scroll — tile 1 is still on screen beside tile 12, so nothing "
        + "below distinguishes a preserved position from an unmoved one.")
    print("WP16P2-SCROLL scrolled: window=\(app.frame.size) swipes=\(swipes)")
    attach(app: app, named: "P2-scroll-deep-before-collapse")

    // Collapse. Weak on its own (see the note above) — asserted anyway, because a crash or a
    // blanked grid here should fail as itself rather than as the expand leg.
    chromeInfo.tap()
    XCTAssertTrue(
      waitForNonExistence(of: app.buttons["Stats"], timeout: 10),
      "The inspector did not collapse, so this test never reached the rebuild it is about.")
    XCTAssertTrue(
      lastTile.isHittable,
      "The collapsed grid lost the photograph the reader was looking at.")
    attach(app: app, named: "P2-scroll-deep-collapsed")

    // Expand — THE falsifier.
    chromeInfo.tap()
    XCTAssertTrue(
      app.buttons["Stats"].waitForExistence(timeout: 10),
      "The inspector did not come back, so the expand leg never ran.")
    attach(app: app, named: "P2-scroll-deep-after-expand")
    XCTAssertTrue(
      lastTile.isHittable,
      "Collapsing and re-expanding the inspector threw the reader back to the top of the shoot. "
        + "The grid is rebuilt in a different split-view slot, so its ScrollView starts at zero "
        + "unless the position is carried in store-owned state — see "
        + "`GridStore.gridScrollAnchor` and `GridScrollAnchor`, which also explains why the "
        + "anchor cannot be a row id.")
    XCTAssertFalse(
      firstTile.isHittable,
      "Tile 1 is back on screen after the round trip — the restored position is the top of the "
        + "grid, not the place the reader was.")
  }

  /// WP16 P2 (IMGMGR-298), design record [/link/3332] decision 4: **both panels collapsible.**
  ///
  /// This branch REVERSES a pinned, tested contract. At `4753450` it read
  /// `XCTAssertFalse(hasChromeInfo, "Regular-3's inspector is a permanent column — there is
  /// nothing for a chrome control to open.")`, so leg (i) below is RED against the shipped app
  /// for exactly the reason the phase exists.
  ///
  /// A ROUND TRIP, never "a control exists" (gate round 1, B5): a control that toggles a flag
  /// nothing renders fails leg (ii); a hide that never restores fails leg (iii).
  ///
  /// Leg (ii) also measures that the grid ACTUALLY TOOK THE PANE. `statsSegment.exists == false`
  /// alone cannot distinguish a real collapse from the plan's own "Known unknown" — a
  /// `NavigationSplitView` that keeps reserving a third column for an `EmptyView`, which is the
  /// failure `RootView.swift`'s own 2-column comment records for the Regular-2 case with
  /// retained screenshot evidence. `ActionBarView` centres its chosen tier inside
  /// `.frame(maxWidth: .infinity)`, so the action bar's mid-x IS the grid pane's centre: when
  /// the pane grows the bar moves right, and when a blank pane is reserved it does not move at
  /// all. Strictly-greater needs no predicted pixel value.
  private func assertTheRegular3InspectorCollapsesAndRestores(
    app: XCUIApplication, chromeInfo: XCUIElement, statsSegment: XCUIElement,
    dislike: XCUIElement, hasChromeInfo: Bool, inspectorAlreadyOnScreen: Bool,
    orientationName: String
  ) {
    // Leg (i). RED at 4753450: `usesChromeControl` was false for `.permanentColumn`, so no Info
    // item was declared on the content column's bar at all (`RootView.swift:422`).
    XCTAssertTrue(
      hasChromeInfo,
      "Regular-3 must reach the inspector from the SAME persistent chrome control the other two "
        + "widths use (decision 4). If this fails while the inspector is visibly on screen, "
        + "check for an `OverflowBarButtonItem` — the Info item is the fifth `.primaryAction` "
        + "on a content column the gate measured at ~209 pt, and a folded item is not a "
        + "reachable control.")
    XCTAssertTrue(
      inspectorAlreadyOnScreen,
      "Regular-3 must still LAUNCH with the inspector shown — a launch that hides it is a "
        + "capability loss, not a collapse.")
    XCTAssertTrue(dislike.isHittable, "The grid stays interactive beside the column.")

    recordTheRegular3SidebarProbe(app: app, orientationName: orientationName, state: "shown")

    let barBeforeCollapse = dislike.frame.midX
    chromeInfo.tap()

    // Leg (ii): it actually hides, and the grid actually gains the space.
    XCTAssertTrue(
      waitForNonExistence(of: statsSegment, timeout: 10),
      "Tapping the chrome control at Regular-3 left the inspector on screen — the control "
        + "toggles a flag nothing renders.")
    XCTAssertTrue(
      dislike.isHittable, "The grid must still be reachable once the inspector is collapsed.")
    let barAfterCollapse = dislike.frame.midX
    print(
      "WP16P2-COLLAPSE \(orientationName): window=\(app.frame.size) "
        + "actionBarMidX before=\(barBeforeCollapse) after=\(barAfterCollapse)")
    attach(app: app, named: "P2-regular3-inspector-collapsed")
    XCTAssertGreaterThan(
      barAfterCollapse, barBeforeCollapse,
      "The inspector left the screen but the grid pane did not grow (action bar mid-x unmoved at "
        + "\(barAfterCollapse)) — the reader traded the inspector for a blank pane, which is "
        + "not what decision 4 asked for. This is the measured failure of the first attempt "
        + "(before=104.5 after=104.5 at a 1376 pt window), where the collapsed state still "
        + "rendered a three-column `NavigationSplitView` with an `EmptyView` third column: the "
        + "column is reserved by the initializer's arity, not by its content. The collapsed "
        + "workspace must render the two-column shape and ask for `.detailOnly` — see "
        + "`InspectorPlacement.columnVisibility(for:regular3InspectorShown:)`.")

    // ...and the width it reclaimed went to the GRID, not to the sidebar. Decision 4 asked for a
    // collapsible inspector; it did not ask for the sidebar, which [/link/3220] keeps off at
    // this width. `dislike.isHittable` just above is this 0-hit reading's positive control.
    // Read as the sidebar's own tier row since IMGMGR-350: the queue card this looked for is not
    // rendered on any width any more, so the reading would have been vacuously true.
    let sidebarRow = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertFalse(
      sidebarRow.exists,
      "Collapsing the inspector revealed the sidebar. The freed pane must go to the grid "
        + "— check the visibility the collapsed shape asks for "
        + "(`InspectorPlacement.columnVisibility(for:regular3InspectorShown:)`).")
    recordTheRegular3SidebarProbe(app: app, orientationName: orientationName, state: "collapsed")

    // Leg (iii): and it comes back.
    chromeInfo.tap()
    XCTAssertTrue(
      statsSegment.waitForExistence(timeout: 10),
      "The inspector never came back after a second tap — a hide that cannot be undone is not a "
        + "collapse.")
  }

  /// The plan's mandatory FIRST-ACTION probe, carried here because the lane that wrote this
  /// runs on Linux and has no simulator: the gate itself is the only surface that can answer it.
  ///
  /// Deliberately ASSERTS NOTHING. Its three readings are (a) whether the sidebar column is on
  /// screen at Regular-3, (b) whether a system `NavigationSplitView` sidebar toggle is in the
  /// hierarchy at all, and (c) whether it is hittable. (a) is already recorded as false by this
  /// file's own classification note; (b)/(c) had no recorded answer, and decision 4's sidebar
  /// half turns on them: if the sidebar cannot be revealed at Regular-3 under
  /// `.prominentDetail`, NO control ships and the half is a declared deviation. A probe that
  /// asserted an answer would be pinning whichever behaviour the OS happened to have.
  ///
  /// Taken in BOTH states, because they are different compositions and the first gate run showed
  /// they answer differently. `state: "shown"` is the three-column workspace, whose reading at
  /// 1376 pt was `sidebarToggleExists=true sidebarToggleHittable=false` with the toggle listed
  /// TWICE (one leading control per rendered column — the same composition that ships at
  /// 4753450, since nothing in this phase adds a toolbar item to the inspector's own bar).
  /// `state: "collapsed"` is the two-column shape the fix round introduced, which renders one
  /// pane and should therefore offer exactly one toggle.
  ///
  /// The full `navBarButtons` list is printed rather than summarised because it is also the only
  /// reading of what the content column's bar can hold: at 1376 pt that column measures ~209 pt,
  /// and the first run showed Zoom and Shortcut-help already folded behind `More`. Comparing the
  /// two states says whether that is the bar being too narrow (the collapsed list, at the full
  /// window width, carries all of them) rather than anything this phase decided.
  private func recordTheRegular3SidebarProbe(
    app: XCUIApplication, orientationName: String, state: String
  ) {
    let sidebarRow = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    let sidebarToggle = app.buttons
      .matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch
    let navBarButtonLabels = app.navigationBars.buttons.allElementsBoundByIndex.map { $0.label }
    print(
      "WP16P2-SIDEBAR-PROBE \(orientationName) \(state): window=\(app.frame.size) "
        + "sidebarRowOnScreen=\(sidebarRow.exists) "
        + "sidebarToggleExists=\(sidebarToggle.exists) "
        + "sidebarToggleHittable=\(sidebarToggle.exists && sidebarToggle.isHittable) "
        + "navBarButtons=\(navBarButtonLabels)")
    attach(app: app, named: "P2-regular3-sidebar-probe-\(state)")
  }

  /// `XCTNSPredicateExpectation` rather than a poll: the collapse is animated
  /// (`withAnimation(.snappy(duration: 0.25))`), so a single immediate `.exists` read after the
  /// tap would race the animation rather than observe the outcome.
  private func waitForNonExistence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: element)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }

  /// Diff-gate round 1, blocking finding 2: the filter-count indicator must be proven ON THE
  /// PRODUCTION CONTROL, not on the helper functions that feed it. Nothing below touches
  /// `InspectorFacetFilters` — it drives the shipped chain end to end (tap a facet row → the
  /// store's query changes → `RootView`'s Info control re-renders) and then reads the control's
  /// own accessibility label. Drop `.accessibilityLabel(...)` from that button and the label
  /// falls back to the visual title, which fails here (IMGMGR-224).
  ///
  /// Run at Regular-2 specifically because the slide-over leaves the navigation bar uncovered, so
  /// the control stays readable while the panel is open — under Compact's modal sheet it is not.
  private func assertTheChromeControlReportsTheActiveFilterCount(
    app: XCUIApplication, chromeInfo: XCUIElement
  ) {
    XCTAssertEqual(
      chromeInfo.label, "Info",
      "With no facet filter applied the control must read plainly — otherwise the assertion "
        + "below could not tell a real count from a leftover.")

    app.buttons["Stats"].tap()

    let clearFilters = app.buttons["inspectorClearFilters"]
    XCTAssertFalse(clearFilters.exists, "No facet filter should be active at launch.")

    // The stub serves exactly one mark facet — value "pick", count 3 (`DebugStubTransport`), and
    // `InspectorFacetField.displayValue` passes a mark value through verbatim, so the row's label
    // starts with a LOWERCASE "pick".
    //
    // Case-sensitive on purpose. The previous `BEGINSWITH[c]` was case-INSENSITIVE and therefore
    // also matched the grid action bar's "Pick" button, which `.firstMatch` reached first: the
    // gate log for 9e162d6 shows the tap landing on the `hand.thumbsup` Button, so the test
    // applied a mark instead of a filter and nothing was ever filtered. The action bar is "Pick",
    // the facet row is "pick"; case alone separates them, and the exclusions below make the
    // separation explicit rather than incidental.
    let markRow = app.buttons
      .matching(
        NSPredicate(
          format:
            "label BEGINSWITH 'pick' AND label != 'Pick'"
            + " AND NOT (label CONTAINS 'photos')")
      )
      .firstMatch
    guard markRow.waitForExistence(timeout: 10) else {
      // An explicit closure, never `map(\.label)`: under Swift 6 `XCUIElement.label` is
      // main-actor-isolated, and a key-path literal into it does not compile.
      let labels = app.buttons.allElementsBoundByIndex.map { $0.label }
      XCTFail(
        "The Stats section never offered the stub's 'pick' mark facet row. Buttons seen: \(labels)")
      return
    }
    // Name what is about to be tapped, so a future mismatch is legible in the log rather than
    // silently marking a photograph again.
    let markRowLabel = markRow.label
    XCTAssertTrue(
      markRowLabel.hasPrefix("pick"),
      "Resolved the wrong element as the mark facet row: \(markRowLabel).")
    markRow.tap()

    // The store actually applied it: the Clear row only renders while activeCount > 0.
    if !clearFilters.waitForExistence(timeout: 10) {
      let labels = app.buttons.allElementsBoundByIndex.map { $0.label }
      XCTFail(
        "Tapping the facet row did not put the production query into a filtered state. Tapped "
          + "\(markRowLabel); buttons now: \(labels)")
    }

    // ...and THAT is what the production control must now be reporting — in the phrasing written
    // for a screen reader, not the terse visual one.
    //
    // IMGMGR-224: what XCUITest reads back here IS the accessibility label. Until this ticket the
    // toolbar item dropped `.accessibilityLabel(infoButtonAccessibilityLabel(...))` and the
    // element fell back to the visual title ("Info · 1", `InspectorFacetFilters.infoButtonTitle`),
    // so the sentence written for VoiceOver ("Info, 1 filter active",
    // `InspectorModel.swift:330`) was dead code. The expected string below is that function's
    // output verbatim — the test pins production, not the other way round — and the screenshot
    // attached beside it is the evidence that the VISUAL title is still the middle-dot form.
    XCTAssertTrue(
      chromeInfo.waitForExistence(timeout: 5), "The chrome control vanished while filtering.")
    attach(app: app, named: "P10-info-control-filtered")
    XCTAssertEqual(
      chromeInfo.label, "Info, 1 filter active",
      "The Info control must announce the active-filter count in the accessible phrasing — it is "
        + "the only place a filtered grid announces itself, and a screen reader that hears the "
        + "terse visual title instead is the IMGMGR-224 regression this test exists to catch.")
  }

  private func attach(app: XCUIApplication, named name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTContext.runActivity(named: "\(name) — captured size \(screenshot.image.size)") { _ in }
  }
}
