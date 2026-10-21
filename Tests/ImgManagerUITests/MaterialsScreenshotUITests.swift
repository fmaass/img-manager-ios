import UIKit
import XCTest

/// WP28 P4 (IMGMGR-451): the named materials screenshot matrix
/// (`MaterialsScreenshotManifest.txt`, 18 names per destination) under the REAL accessibility
/// settings.
///
/// The mode comes from the gate: the UI leg's own run is the DEFAULT mode; each extra mode is a
/// run of this suite alone with the setting applied to that leg's simulator and
/// `TEST_RUNNER_IMG_MATERIALS_MODE` set (xcodebuild hands it to this runner as
/// `IMG_MATERIALS_MODE`) — bin/gate-lib.sh `gate_materials_mode_run`.
///
/// Before EVERY capture the app's own reading (`materialsSettingsProbe`) must match the mode's
/// FULL expectation: all four keys present, both settings AND the two SwiftUI environment inputs
/// `MaterialPolicy` reads. The one tolerated mismatch is the plan's fallback rule: in Reduce
/// Transparency mode an app that reads exactly the default (the setting did not take) is
/// UNRESOLVED — the test records `materials-unresolved-<dest>-reduce-transparency` (an attachment
/// holding `dest=… mode=… run=<IMG_MATERIALS_RUN> surface=… reading=…`, plus the same
/// `MATERIALS-UNRESOLVED` line, the gate's pivot trigger) and SKIPS, capturing nothing. The run
/// token is the gate's (`gate_materials_mode_run`), so the gate can tell this run's marker from a
/// stale one. No marker without a token, and none after a capture in the same run (a mode is
/// wholly captured or wholly UNRESOLVED): both fail. Every other mismatch fails with
/// `MATERIALS-READBACK-MISMATCH`.
/// For a sheet the reading is taken just before the sheet opens — the one moment the probe under
/// the modal is certainly addressable.
///
/// In the default mode the matrix also runs the chrome touch-target census (ChromeCensus.swift)
/// in the states only it reaches: the inspector and summary sheets, the select bar and
/// Regular-2 (R3-18, IMGMGR-550, removed the search-active state). The loupe is in no matrix
/// state and is not censused.
///
/// Layout is read from the measured window (Compact below the tab shell's ceiling, Regular-3 at
/// or above the 1197 pt pin), never from a device idiom; a destination that cannot reach a matrix
/// skips it with the measured window.
/// Thrown after the `XCTFail` of a read-back mismatch, so the matrix stops there even when a
/// caller's `continueAfterFailure` would let it run on.
private struct MaterialsReadBackMismatch: Error {}

final class MaterialsScreenshotUITests: OrientationPinnedUITestCase {

  private enum Mode: String {
    case standard = "default"
    case reduceTransparency = "reduce-transparency"
    case increaseContrast = "increase-contrast"
  }

  /// Mirrors `LayoutResolver.regular3Threshold`, as `InspectorSummaryUITests` does.
  private static let regular3WidthThreshold: CGFloat = 1197

  /// No `setUp` override: the pinned base owns `setUp` (OrientationPinnedUITestCase).
  private var modeName: String {
    ProcessInfo.processInfo.environment["IMG_MATERIALS_MODE"] ?? Mode.standard.rawValue
  }

  private var mode: Mode? { Mode(rawValue: modeName) }

  /// The gate's token for this run (`TEST_RUNNER_IMG_MATERIALS_RUN`); empty outside the gate's
  /// extra-mode runs.
  private var runToken: String {
    ProcessInfo.processInfo.environment["IMG_MATERIALS_RUN"] ?? ""
  }

  /// Set by the first capture of this run: after it, an UNRESOLVED reading is a failure.
  private var capturedInThisRun = false

  /// Census failures, held until the matrix ends (`censusState`).
  private var censusFailures: [String] = []

  /// Every matrix starts here: a failed read-back or a missing surface ends the test, so nothing
  /// is captured after it, and an unknown mode is a failure rather than a default-mode run.
  private func beginMatrix() -> Bool {
    continueAfterFailure = false
    guard mode != nil else {
      XCTFail(
        "IMG_MATERIALS_MODE='\(modeName)' is not default, reduce-transparency or "
          + "increase-contrast.")
      return false
    }
    return true
  }

  // MARK: - iPhone (Compact)

  /// shoots-home, library, grid-pushed, inspector-sheet, summary-sheet.
  @MainActor
  func testCompactMaterialsMatrix() throws {
    guard beginMatrix() else { return }
    defer { assertCensusClean() }
    let roots = launch(extraArguments: ["-UITestStubSkipAutoSelect"], orientation: .portrait)
    guard rendersCompactShell(roots) else {
      throw XCTSkip(
        "IMGMGR-451 Compact matrix: window=\(roots.windows.firstMatch.frame.size) is not Compact.")
    }

    XCTAssertTrue(
      anyElement(roots, "untouchedRow-5").waitForExistence(timeout: 30),
      "The Shoots root never rendered.")
    try capture(roots, "iphone", "shoots-home")

    selectCompactTab(roots, title: "Library")
    XCTAssertTrue(
      anyElement(roots, "folderTreeViewMenu").waitForExistence(timeout: 15),
      "The Library root never rendered.")
    try capture(roots, "iphone", "library")

    let grid = launch(extraArguments: [], orientation: .portrait)
    XCTAssertTrue(
      grid.buttons["Dislike"].waitForExistence(timeout: 30), "The pushed grid never rendered.")
    try capture(grid, "iphone", "grid-pushed")

    try assertSettingReadsBack(grid, "iphone", before: "inspector-sheet")
    let stats = grid.buttons["Stats"]
    let info = gridInfoControl(grid)
    XCTAssertTrue(info.waitForExistence(timeout: 10), "No Info control on the grid's bar.")
    info.tap()
    XCTAssertTrue(stats.waitForExistence(timeout: 10), "Info did not present the inspector.")
    try capture(grid, "iphone", "inspector-sheet", readBack: false)
    censusState(
      grid, "iphone", "inspector-sheet", titleMenu: true, alsoMeasure: [("Stats", stats)])
    // The sheet's own dismissal, as InspectorSummaryUITests (c) does it.
    let start = stats.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .withOffset(CGVector(dx: 0, dy: -40))
    start.press(
      forDuration: 0.1,
      thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
    XCTAssertTrue(stats.waitForNonExistence(timeout: 10), "The inspector sheet did not dismiss.")

    try assertSettingReadsBack(grid, "iphone", before: "summary-sheet")
    let sheetBar = openSummary(grid)
    try capture(grid, "iphone", "summary-sheet", readBack: false)
    censusState(
      grid, "iphone", "summary-sheet", titleMenu: true, requiring: ["shootSummaryDone|Done"])
    closeSummary(sheetBar)

    // WP30 P1 (IMGMGR-456): the loupe — its system toolbar, bottom-bar mark group and content
    // filmstrip. Read back first: the probe sits under the Compact cover once it is up.
    try assertSettingReadsBack(grid, "iphone", before: "loupe")
    openLoupe(grid)
    try capture(grid, "iphone", "loupe", readBack: false)
  }

  // MARK: - iPad (Regular)

  /// regular3-collapsed, summary-sheet, regular3-inspector (one Regular-3 launch),
  /// select-bar (a Select-mode launch), regular2-grid (a portrait launch).
  @MainActor
  func testRegularMaterialsMatrix() throws {
    guard beginMatrix() else { return }
    defer { assertCensusClean() }
    let app = launch(extraArguments: [], orientation: .landscapeLeft)
    let window = app.windows.firstMatch.frame.size
    guard window.width >= Self.regular3WidthThreshold else {
      throw XCTSkip("IMGMGR-451 Regular matrix: window=\(window) does not resolve Regular-3.")
    }
    try capture(app, "ipad", "regular3-collapsed")

    try assertSettingReadsBack(app, "ipad", before: "summary-sheet")
    let sheetBar = openSummary(app)
    try capture(app, "ipad", "summary-sheet", readBack: false)
    censusState(
      app, "ipad", "summary-sheet", titleMenu: true, requiring: ["shootSummaryDone|Done"])
    closeSummary(sheetBar)

    let info = gridInfoControl(app)
    XCTAssertTrue(info.waitForExistence(timeout: 10), "No Info control on the grid's bar.")
    info.tap()
    XCTAssertTrue(
      app.buttons["Stats"].waitForExistence(timeout: 10), "Info did not show the inspector.")
    try capture(app, "ipad", "regular3-inspector")
    censusState(app, "ipad", "regular3-inspector", titleMenu: true, requiring: ["Info"])
    info.tap()
    XCTAssertTrue(
      app.buttons["Stats"].waitForNonExistence(timeout: 10), "Info did not hide the inspector.")

    let select = launch(extraArguments: ["-UITestEnterSelectMode"], orientation: .landscapeLeft)
    XCTAssertTrue(
      select.staticTexts["selectModeCaption"].waitForExistence(timeout: 30),
      "The Select-mode launch never showed the select bar.")
    try capture(select, "ipad", "select-bar")
    censusState(
      select, "ipad", "select-bar", titleMenu: true,
      alsoMeasure: [("selectModeDone", anyElement(select, "selectModeDone"))])

    let portrait = launch(extraArguments: [], orientation: .portrait)
    let portraitWindow = portrait.windows.firstMatch.frame.size
    let sidebar = anyElement(portrait, "folderTreeTier-Incoming")
    let narrow = portraitWindow.width < Self.regular3WidthThreshold
    let sidebarShown = sidebar.waitForExistence(timeout: 10) && sidebar.isHittable
    guard narrow && sidebarShown && portrait.buttons["Dislike"].isHittable else {
      throw XCTSkip(
        "IMGMGR-451 regular2-grid: window=\(portraitWindow) does not show the sidebar beside the "
          + "grid (Regular-2); the five captures above stand.")
    }
    try capture(portrait, "ipad", "regular2-grid")
    // The app's own bars by identifier — the Regular grid bar and action bar (WP29 P1).
    let appBars = (Self.regularGridBarIdentifiers + Self.regularActionBarIdentifiers).map {
      (key: $0, element: anyElement(portrait, $0))
    }
    censusState(
      portrait, "ipad", "regular2-grid", titleMenu: true, requiring: ["Info"],
      alsoMeasure: appBars)

    // WP30 P1 (IMGMGR-456): the docked Regular-2 loupe, same launch.
    try assertSettingReadsBack(portrait, "ipad", before: "regular2-loupe")
    openLoupe(portrait)
    try capture(portrait, "ipad", "regular2-loupe", readBack: false)

    // WP30 P3 (IMGMGR-458): Compare, swapped into the same docked container — its bars and the
    // content strip in each mode.
    try assertSettingReadsBack(portrait, "ipad", before: "regular2-compare")
    openCompare(portrait)
    try capture(portrait, "ipad", "regular2-compare", readBack: false)
  }

  // MARK: - Launch, read-back, capture

  /// WP30 P1: opens the loupe on the fixture's first tile — the first tap focuses, the second
  /// opens (`GridStore.tapTile`), so tap until Back is on screen.
  private func openLoupe(_ app: XCUIApplication) {
    let back = app.buttons["loupeBack"]
    for _ in 0..<3 where !back.exists {
      let tile = anyElement(app, "gridTile-1")
      guard tile.waitForExistence(timeout: 15) else { break }
      tile.tap()
      _ = back.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(back.exists, "The loupe never opened from a tile tap.")
  }

  /// WP30 P3: opens Compare from the open loupe's toolbar control.
  private func openCompare(_ app: XCUIApplication) {
    let compare = anyElement(app, "loupeCompareButton")
    XCTAssertTrue(compare.waitForExistence(timeout: 10), "The loupe has no Compare control.")
    compare.tap()
    XCTAssertTrue(
      app.buttons["compareBack"].waitForExistence(timeout: 10), "Compare never opened.")
  }

  private func launch(
    extraArguments: [String], orientation: UIDeviceOrientation
  ) -> XCUIApplication {
    XCUIDevice.shared.orientation = orientation
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestMaterialsProbe"] + extraArguments
    app.launch()
    XCUIDevice.shared.orientation = orientation
    // The rotation's layout pass, then the resolver's reaction to it (the P3 launch sequence).
    Thread.sleep(forTimeInterval: 2.0)
    return app
  }

  /// The app's own reading, `key=0|1` pairs (`MaterialsSettingsProbe.reading`).
  private func settingsReading(_ app: XCUIApplication) -> [String: String]? {
    let probe = anyElement(app, "materialsSettingsProbe")
    guard probe.waitForExistence(timeout: 15) else { return nil }
    var pairs: [String: String] = [:]
    for token in ((probe.value as? String) ?? "").split(separator: " ") {
      let parts = token.split(separator: "=", maxSplits: 1)
      if parts.count == 2 { pairs[String(parts[0])] = String(parts[1]) }
    }
    return pairs
  }

  /// What the app must read in each mode: every key, the settings and the environment inputs.
  private static func expectedReading(_ mode: Mode) -> [String: String] {
    let reduce = mode == .reduceTransparency ? "1" : "0"
    let darker = mode == .increaseContrast ? "1" : "0"
    return [
      "reduceTransparency": reduce,
      "envReduceTransparency": reduce,
      "darkerSystemColors": darker,
      "envIncreasedContrast": darker,
    ]
  }

  /// Returns only when the app reads this mode's full expectation. Reduce Transparency reading
  /// exactly the default is UNRESOLVED (marker, then `XCTSkip`); any other mismatch fails and
  /// throws, so nothing is captured after it either way.
  private func assertSettingReadsBack(
    _ app: XCUIApplication, _ dest: String, before surface: String
  ) throws {
    guard let mode = mode else {
      throw XCTSkip("No valid materials mode (beginMatrix recorded it).")
    }
    let reading = settingsReading(app)
    let readsBack = reading == Self.expectedReading(mode)
    let shown = reading.map { "\($0)" } ?? "<no materialsSettingsProbe>"
    print("MATERIALS-READBACK mode=\(mode.rawValue) surface=\(surface) ok=\(readsBack) \(shown)")
    if readsBack { return }
    // UNRESOLVED only for the exact default reading, so never when Reduce Transparency read "1".
    if mode == .reduceTransparency, reading == Self.expectedReading(.standard),
      reading?["reduceTransparency"] == "0"
    {
      let marker = "materials-unresolved-\(dest)-\(mode.rawValue)"
      guard !capturedInThisRun, !runToken.isEmpty else {
        XCTFail(
          "MATERIALS-READBACK-MISMATCH mode=\(mode.rawValue) surface=\(surface): the app reads "
            + "\(shown) after captured=\(capturedInThisRun) with run token '\(runToken)'; an "
            + "UNRESOLVED marker needs the gate's token and no capture before it.")
        throw MaterialsReadBackMismatch()
      }
      let identity = "dest=\(dest) mode=\(mode.rawValue) run=\(runToken)"
      let attachment = XCTAttachment(string: "\(identity) surface=\(surface) reading=\(shown)")
      attachment.name = marker
      attachment.lifetime = .keepAlways
      add(attachment)
      print("MATERIALS-UNRESOLVED \(identity) \(shown)")
      throw XCTSkip(
        "\(marker): the app reads \(shown) with the setting applied. UNRESOLVED — nothing is "
          + "captured in this mode (plan Phase 4 fallback rule).")
    }
    XCTFail(
      "MATERIALS-READBACK-MISMATCH mode=\(mode.rawValue) surface=\(surface): the app reads "
        + "\(shown), expected \(Self.expectedReading(mode)).")
    throw MaterialsReadBackMismatch()
  }

  /// Reads the setting back (unless the caller just did, before opening a sheet), lets the
  /// presentation settle, and attaches the screen as `<dest>-<surface>-<mode>` — the manifest
  /// name the gate resolves.
  private func capture(
    _ app: XCUIApplication, _ dest: String, _ surface: String, readBack: Bool = true
  ) throws {
    if readBack { try assertSettingReadsBack(app, dest, before: surface) }
    guard let mode = mode else { return }
    Thread.sleep(forTimeInterval: 1.0)
    capturedInThisRun = true
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "\(dest)-\(surface)-\(mode.rawValue)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  // MARK: - Touch-target census

  /// The census of one matrix state, in the default mode only (the extra modes' runs stay
  /// short). Every row prints at once; its failures are HELD until the matrix ends
  /// (`assertCensusClean`), so a census finding never stops the captures after it.
  @MainActor
  private func censusState(
    _ app: XCUIApplication, _ dest: String, _ state: String, titleMenu: Bool = false,
    requiring required: [String] = [],
    alsoMeasure extras: [(key: String, element: XCUIElement)] = []
  ) {
    guard mode == .standard else { return }
    let census = chromeCensus(
      app, state: state, titleMenu: titleMenu, requiring: required, alsoMeasure: extras)
    censusFailures += reportChromeTargets(
      census.rows, problems: census.problems, name: "\(dest)-matrix", failNow: false)
  }

  /// The held census failures, once, at the end of the matrix — also when it ends early (a
  /// skip or a thrown mismatch), since it runs from a `defer`.
  private func assertCensusClean() {
    guard !censusFailures.isEmpty else { return }
    continueAfterFailure = true
    XCTFail(censusFailures.joined(separator: "\n"))
  }

  // MARK: - Summary

  private func openSummary(_ app: XCUIApplication) -> XCUIElement {
    let title = gridTitleMenuTrigger(app, names: Self.materialsFolderOneNames)
    XCTAssertTrue(title.waitForExistence(timeout: 5), "The grid's title menu trigger is absent.")
    let row = shootSummaryMenuRow(app)
    XCTAssertTrue(
      openPresentation(title, revealing: row, timeout: 20),
      "The title menu did not offer \"Shoot Summary\".")
    row.tap()
    let sheetBar = app.navigationBars["Shoot Summary"]
    XCTAssertTrue(
      sheetBar.waitForExistence(timeout: 10), "\"Shoot Summary\" did not present the sheet.")
    return sheetBar
  }

  private func closeSummary(_ sheetBar: XCUIElement) {
    let done = sheetBar.buttons
      .matching(NSPredicate(format: "identifier == 'shootSummaryDone' OR label == 'Done'"))
      .firstMatch
    XCTAssertTrue(done.waitForExistence(timeout: 5), "The Summary sheet has no Done.")
    done.tap()
    XCTAssertTrue(sheetBar.waitForNonExistence(timeout: 10), "Done did not dismiss the Summary.")
  }
}
