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
final class InspectorSlideOverUITests: XCTestCase {

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

    // A queue card from the stub's own fixture ("40 photos · 10 picked"). P6 does not touch
    // queue cards, so this survives the wave that retires the Folders-based split.
    let queueCard = app.staticTexts
      .matching(NSPredicate(format: "label CONTAINS ' photos · '")).firstMatch
    let statsSegment = app.buttons["Stats"]
    let chromeInfo = app.navigationBars.buttons
      .matching(NSPredicate(format: "label BEGINSWITH 'Info'")).firstMatch

    let width = app.frame.size.width

    // The grid is on screen in EVERY layout, so it is the one input whose absence would make the
    // sidebar reading below meaningless rather than informative. Asserted first, so that
    // `queueIsBesideTheGrid` is unambiguously a statement about the QUEUE.
    XCTAssertTrue(
      dislike.isHittable,
      "The grid must be reachable in every layout — a pane reading taken while the grid itself "
        + "is missing classifies nothing.")

    // Is the QUEUE on screen beside the grid? True only at Regular-2.
    let queueIsBesideTheGrid = queueCard.isHittable && dislike.isHittable
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
      : (queueIsBesideTheGrid ? .regular2 : .compact)

    // The probe's record. `print` (not only an activity) because the gate copies back the
    // xcodebuild log, which is where this has to be readable afterwards.
    print(
      "P10-PROBE \(orientationName): window=\(app.frame.size) "
        + "queueBesideGrid=\(queueIsBesideTheGrid) "
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
      XCTAssertFalse(
        hasChromeInfo,
        "Regular-3's inspector is a permanent column — there is nothing for a chrome control to "
          + "open.")
      XCTAssertTrue(
        inspectorAlreadyOnScreen, "Regular-3's inspector column must be on screen with no tap.")
      XCTAssertTrue(dislike.isHittable, "The grid stays interactive beside the permanent column.")
    }

    attach(app: app, named: "P10-\(orientationName)-\(resolved.rawValue)-inspectorShown")
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
