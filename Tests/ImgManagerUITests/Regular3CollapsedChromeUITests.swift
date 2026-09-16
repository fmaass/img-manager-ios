import UIKit
import XCTest

/// IMGMGR-390 (owner decision on IMGMGR-338, comment 3731): **at Regular-3 the workspace opens
/// with the inspector COLLAPSED so the sidebar stays visible, and the six host chrome controls
/// are primary and directly hittable in that state.**
///
/// - COLLAPSED (the launch state) the grid IS the wide detail column: all six ride its bar as
///   primary items and the sidebar is the second rendered pane. That is the reach the decision
///   buys, and it is asserted in full, twice — at launch and after a round trip.
/// - EXPANDED the inspector is the `.prominentDetail` column and the grid's content column
///   measures ~209 pt, where the OS folds three of six primary items into the system overflow
///   chevron (recorded in `GridView.toolbarContent`, and the deviation IMGMGR-293 already
///   declares). The decision moved the six to the inspector's own bar for that state; two gate
///   runs then measured that NOTHING in that column takes a tap while it is expanded — as bar
///   items (`37ac723`) and as a rendered row (`b383b5a`) alike, every control read
///   `exists == true`, `isHittable == false`, and a tap computed hit point {-1, -1}, because
///   `.prominentDetail` with `columnVisibility == .all` renders the grid as a column OVERLAYING
///   a non-interactive detail pane. So the set stays on the grid's bar, and what this file pins
///   for the expanded state is the ESCAPE HATCH: the chrome control itself is never folded, so
///   the reader can always collapse back to the state where all six are reachable. The census
///   printed beside it records which of the other five the OS left out, as evidence rather than
///   as an assertion about an OS layout decision.
///
/// Every six-control assertion reads `isHittable`, never `exists`: an item folded into the
/// chevron is still in the hierarchy and would satisfy an existence check while being exactly the
/// failure the owner reported. `FilterPopoverUITests` established that reading for the funnel;
/// this file applies it to all six.
///
/// **Against `2dce96e` all three tests are RED**: the workspace launches with the inspector shown
/// (so every collapsed-state leg fails at its first reading), and collapsing it there renders the
/// grid ALONE — `.detailOnly` — so the sidebar legs fail too.
///
/// Makes no device-idiom decision: the Regular-3 layout is identified by the app's own measured
/// window width against the resolver's pin, exactly as `InspectorSlideOverUITests` does, and the
/// iPhone destination records that it has no Regular-3 to test rather than skipping silently.
final class Regular3CollapsedChromeUITests: OrientationPinnedUITestCase {

  /// LANDSCAPE: it is what puts the iPad destination at Regular-3, the only width this file is
  /// about; the iPhone destination is Compact in either orientation.
  override class var pinnedOrientation: UIDeviceOrientation { .landscapeLeft }

  /// Mirrors `LayoutResolver.regular3Threshold`. A UI-test bundle DRIVES an installed app rather
  /// than linking it, so the pin has to be duplicated as a literal;
  /// `LayoutPresentationTests.theRegular3WidthPinMatchesTheUITestLiteral` is the join that keeps
  /// the two honest.
  private static let regular3WidthThreshold: CGFloat = 1197

  /// The six items the owner called host chrome (IMGMGR-338): the five grid view-option controls
  /// plus the inspector's own persistent chrome control. Declared ONCE, so "every one of them" is
  /// one list rather than six copied assertions that can drift apart.
  private static let hostChromeIdentifiers = [
    "gridFilterControl",
    "gridSortControl",
    "gridGroupControl",
    "gridZoomControl",
    "gridShortcutHelpControl",
    "inspectorChromeButton",
  ]

  // MARK: - The launch state

  func testTheRegular3WorkspaceLaunchesCollapsedWithTheSidebarBesideTheGrid() {
    guard let app = launchedRegular3App() else { return }

    // The inspector is NOT on screen: `Stats` is the inspector's own segment, the reading every
    // sibling in this target uses for "something inspector-shaped is up".
    XCTAssertFalse(
      app.buttons["Stats"].exists,
      "Regular-3 launched with the inspector expanded. The owner's decision (IMGMGR-338 comment "
        + "3731) is that it starts COLLAPSED so the sidebar stays visible — see "
        + "`RootView.showRegular3Inspector`, which must default to false in DEBUG and RELEASE "
        + "alike.")
    // Positive control for that 0-hit reading: the app really is up and its hierarchy really is
    // being searched, so "no Stats" cannot pass vacuously on a blank screen.
    XCTAssertTrue(
      app.buttons["Dislike"].isHittable,
      "Positive control failed: the action bar is gone, so the absence check above is vacuous.")

    // ...and the pane the inspector is not taking belongs to the SIDEBAR plus the grid. This is
    // the half a default flip alone does not deliver: the collapsed workspace has to ask for
    // `.doubleColumn`, not the `.detailOnly` that shipped
    // (`InspectorPlacement.columnVisibility(for:regular3InspectorShown:)`).
    let sidebarRow = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(
      sidebarRow.waitForExistence(timeout: 10),
      "The sidebar is not on screen beside the collapsed grid. The collapsed Regular-3 workspace "
        + "must ask for `.doubleColumn` — `.detailOnly` renders the grid alone, which is the "
        + "shipped behaviour this story reverses.")
    XCTAssertTrue(
      sidebarRow.isHittable,
      "The sidebar's tier row is in the hierarchy but cannot be tapped — a queue the reader "
        + "cannot reach is not the visible sidebar the decision asked for.")

    assertEveryHostChromeControlIsHittable(
      in: app, state: "collapsed at launch",
      hint: "Collapsed, the grid is the wide detail column and carries all six.")
    attach(app: app, named: "IMGMGR-390-regular3-collapsed-at-launch")
  }

  // MARK: - The expanded state

  /// The fresh-launch EXPANDED workspace, through `-UITestInspectorShown` — the only route to
  /// that state now that collapsed is the default (`DebugStubLaunch.startsWithInspectorShown`).
  ///
  /// The expanded state's contract is the ESCAPE HATCH, not the full six: on this composition the
  /// ~209 pt content column folds three of them, and the inspector column — where the owner's
  /// decision put them — takes no taps at all (see the file's note). A state the reader could not
  /// leave would be the real defect, so that is what is asserted: the chrome control is reachable,
  /// and using it lands on the collapsed workspace where all six ARE reachable and the sidebar is
  /// back.
  func testTheChromeControlStaysReachableWhileTheInspectorIsExpanded() {
    guard let app = launchedRegular3App(extraArguments: ["-UITestInspectorShown"]) else { return }

    XCTAssertTrue(
      app.buttons["Stats"].waitForExistence(timeout: 10),
      "`-UITestInspectorShown` did not take effect — this leg needs the expanded three-column "
        + "workspace, and nothing inspector-shaped is on screen.")
    recordHostChromeCensus(in: app, state: "expanded at launch")

    let chrome = app.descendants(matching: .any)["inspectorChromeButton"].firstMatch
    XCTAssertTrue(
      chrome.waitForExistence(timeout: 10),
      "No `inspectorChromeButton` anywhere in the expanded workspace — the one control that "
        + "collapses the inspector has to be on screen in the state it collapses.")
    XCTAssertTrue(
      chrome.isHittable,
      "`inspectorChromeButton` exists but cannot be tapped while the inspector is expanded, so "
        + "the expansion cannot be undone. The OS folds a crowded bar from the trailing end and "
        + "this item leads the bar's enumeration (gate probe: navBarButtons=[\"Info\", "
        + "\"Filters\", ...]), so it is the one item the fold must never claim — check "
        + "`RootView.contentColumn` and `GridView.toolbarContent` for what joined it there.")
    attach(app: app, named: "IMGMGR-390-regular3-expanded-at-launch")

    chrome.tap()
    XCTAssertTrue(
      app.buttons["Stats"].waitForNonExistence(timeout: 10),
      "The inspector stayed on screen after the chrome control was tapped — an expansion that "
        + "cannot be undone is not a collapse.")
    assertEveryHostChromeControlIsHittable(
      in: app, state: "collapsed from the expanded launch",
      hint: "Collapsed, the grid is the wide detail column and carries all six as primary items.")
    let sidebarRow = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(
      sidebarRow.waitForExistence(timeout: 10) && sidebarRow.isHittable,
      "Collapsing from the expanded launch left the sidebar off screen — the collapsed workspace "
        + "must ask for `.doubleColumn` on the toggle path too, not the `.detailOnly` that "
        + "shipped (`RootView.inspectorVisibilityBinding`).")
    attach(app: app, named: "IMGMGR-390-regular3-collapsed-from-expanded")
  }

  // MARK: - The round trip

  /// A ROUND TRIP, never "a control exists": a toggle that expands but strands the controls fails
  /// the middle leg, and one that cannot collapse again fails the last.
  func testTheChromeControlExpandsAndCollapsesAndTheSixSurviveBothStates() {
    guard let app = launchedRegular3App() else { return }

    let stats = app.buttons["Stats"]
    let sidebarRow = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    let chrome = app.descendants(matching: .any)["inspectorChromeButton"].firstMatch
    XCTAssertTrue(
      chrome.waitForExistence(timeout: 10),
      "No `inspectorChromeButton` on the collapsed workspace's bar — there is nothing to expand "
        + "the inspector with.")

    chrome.tap()
    XCTAssertTrue(
      stats.waitForExistence(timeout: 10),
      "Tapping the chrome control did not expand the inspector — the control toggles a flag "
        + "nothing renders.")
    // Expanded, only the escape hatch is contractual — see the file's note: the ~209 pt content
    // column folds three of the six, and the inspector column cannot be given a tap at all. The
    // census records what the OS actually left reachable.
    recordHostChromeCensus(in: app, state: "expanded by the chrome control")
    XCTAssertTrue(
      chrome.isHittable,
      "`inspectorChromeButton` stopped taking taps once the inspector expanded, so the reader is "
        + "stranded in the narrow state. It leads the grid bar's enumeration and the OS folds "
        + "from the trailing end, so a fold that reaches this item means the bar gained "
        + "something ahead of it.")
    attach(app: app, named: "IMGMGR-390-regular3-expanded-by-control")

    // ...and back. The sidebar returning is what says the collapse restored the two-column shape
    // rather than leaving a reserved blank pane behind.
    chrome.tap()
    XCTAssertTrue(
      stats.waitForNonExistence(timeout: 10),
      "A second tap left the inspector on screen — an expansion that cannot be undone is not a "
        + "collapse.")
    XCTAssertTrue(
      sidebarRow.isHittable,
      "The sidebar did not come back with the collapse — the collapsed workspace must ask for "
        + "`.doubleColumn` in BOTH the launch path and the toggle path "
        + "(`RootView.inspectorVisibilityBinding`).")
    assertEveryHostChromeControlIsHittable(
      in: app, state: "collapsed by the chrome control",
      hint: "Collapsed again, the six are back on the grid's bar.")
  }

  // MARK: - Helpers

  /// Evidence, never a verdict: which of the six the OS left directly reachable in a state whose
  /// bar it is entitled to fold. Printed (not only an activity) because the gate copies back the
  /// xcodebuild log, which is where the ticket reads it afterwards.
  private func recordHostChromeCensus(in app: XCUIApplication, state: String) {
    let census = Self.hostChromeIdentifiers.map { identifier -> String in
      let control = app.descendants(matching: .any)[identifier].firstMatch
      let reading = control.exists ? (control.isHittable ? "hittable" : "folded") : "absent"
      return "\(identifier)=\(reading)"
    }
    print(
      "IMGMGR-390-CENSUS \(state): window=\(app.frame.size) " + census.joined(separator: " "))
  }

  /// The whole list, every time, with the state named in the failure: a run that reports only the
  /// first missing control hides how much of the bar folded.
  private func assertEveryHostChromeControlIsHittable(
    in app: XCUIApplication, state: String, hint: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    for identifier in Self.hostChromeIdentifiers {
      let control = app.descendants(matching: .any)[identifier].firstMatch
      XCTAssertTrue(
        control.waitForExistence(timeout: 10),
        "`\(identifier)` is nowhere in the hierarchy while \(state). \(hint)",
        file: file, line: line)
      XCTAssertTrue(
        control.isHittable,
        "`\(identifier)` exists but cannot be tapped while \(state) — a control folded into the "
          + "system overflow chevron reads exactly like this, and a folded item is not a primary, "
          + "directly hittable control. \(hint)",
        file: file, line: line)
    }
  }

  /// The fixture launch plus the Regular-3 gate. Returns nil — with the reading recorded, never
  /// silently — on a destination whose window is below the resolver's pin, because a Regular-3
  /// assertion made there would be asserting a layout the device cannot resolve.
  private func launchedRegular3App(extraArguments: [String] = []) -> XCUIApplication? {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"] + extraArguments
    app.launch()

    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else (sign-in, blank, or a failed stub).")
    // The rotation's own layout pass, then the resolver's `.onGeometryChange` reaction to it —
    // the same settle this target's siblings wait out before reading geometry-dependent state.
    Thread.sleep(forTimeInterval: 2.0)

    guard app.frame.size.width >= Self.regular3WidthThreshold else {
      print(
        "IMGMGR-390 \(app.frame.size): below the Regular-3 pin "
          + "(\(Self.regular3WidthThreshold)) — this destination has no third column to collapse")
      return nil
    }
    return app
  }

  private func attach(app: XCUIApplication, named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
