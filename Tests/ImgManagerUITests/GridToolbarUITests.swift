import UIKit
import XCTest

/// WP29 P1 (IMGMGR-452): the Regular grid bar reads
/// [sidebar toggle] · breadcrumb · [Info · Search · Select · Filter · Arrange · More].
///
/// Ticket acceptance probe: "toolbar groups render in the spec order, ≤ 3 groups, breadcrumb
/// centred". Until P2 builds Arrange, Sort · Group · Zoom hold its slot (plan Phase 1).
///
/// - (a) the bar's items in minX order; while the Regular-3 inspector is EXPANDED only Info must be
///   hittable (IMGMGR-390), and every folded item must be reachable through the system overflow.
/// - (b) at most three clusters, from frames (a gap over 16 pt starts one). DIAGNOSTIC as much as
///   verdict: the independent verifier counts the glass clusters in `ipad-bar-p1-<r3|r3x|r2>`.
/// - (c) the title's midX within ±24 pt of its bar's midX, collapsed and at Regular-2.
/// - (d) the Filter control states the active count ("Filters, 1 filter active"), plus a badge
///   screenshot.
/// - (e) Select enters Select mode; More opens with Clear mark and without Select.
/// - (f) with the inspector expanded, Clear and every at-rest action-bar control stay hittable:
///   removing the Regular Clear fold lost nothing.
///
/// (a)–(c) and (f) are Regular's only; the iPhone destination records that it has no Regular
/// layout and skips them — the same three bar tests `RegularSidebarShellUITests` carried before
/// this phase moved them here, so the destination's skip count is unchanged. (d) and (e) hold at
/// every width and run on both destinations.
final class GridToolbarUITests: OrientationPinnedUITestCase {

  override class var pinnedOrientation: UIDeviceOrientation { .landscapeLeft }

  /// Mirrors `LayoutResolver.regular3Threshold` (`LayoutPresentationTests` is the join).
  private static let regular3WidthThreshold: CGFloat = 1197

  /// The app-declared items after the system search, in spec order. Sort holds the Arrange slot
  /// (Group and Zoom sit beside it until P2 replaces the three).
  private static let declaredAfterSearch = [
    "gridSelectCommand", "gridFilterControl", "gridSortControl", "gridGroupControl",
    "gridZoomControl", "gridMoreMenu",
  ]

  /// The at-rest action bar at Regular: More moved to the toolbar, Clear never folds there.
  private static let regularActionBar = [
    "gridPickButton", "gridDislikeButton", "gridClearButton", "gridUndoButton", "gridTagButton",
  ]

  /// Folder 1's tree name, which the Regular sidebar has loaded, and its server count.
  private static let folderOneName = "2026-08-27 — Stub Shoot"
  private static let folderOneCount = "12 photos"

  private static let clusterGap: CGFloat = 16
  private static let titleTolerance: CGFloat = 24

  // MARK: - Regular-3 collapsed

  func testRegular3CollapsedBarOrderClustersAndCentredTitle() throws {
    let app = try launched(.regular3)
    XCTAssertFalse(app.buttons["Stats"].exists, "Regular-3 did not launch collapsed.")

    assertEveryDeclaredItemIsHittable(in: app, state: "Regular-3 collapsed")
    assertSpecOrder(in: app, state: "Regular-3 collapsed")
    assertAtMostThreeClusters(in: app, state: "r3")
    assertTitleCentred(in: app, state: "Regular-3 collapsed")
    capture(app, name: "ipad-bar-p1-r3")
    // Moved here from `RegularSidebarShellUITests` (WP28 P2 evidence, unchanged names).
    capture(app, name: "ipad-bar-regular3-collapsed-search-min")
    activateSearchAndCapture(app, name: "ipad-bar-regular3-collapsed-search-active")
  }

  // MARK: - Regular-3 expanded

  func testRegular3ExpandedKeepsInfoHittableAndEveryItemReachable() throws {
    let app = try launched(.regular3)
    let labels = declaredLabels(in: app, state: "Regular-3 collapsed")

    let info = gridInfoControl(app)
    XCTAssertTrue(info.waitForExistence(timeout: 10), "No Info control on the grid's bar.")
    info.tap()
    XCTAssertTrue(
      app.buttons["Stats"].waitForExistence(timeout: 10), "Info did not expand the inspector.")
    Thread.sleep(forTimeInterval: 1.0)

    // (a) expanded: Info is the escape hatch and must stay directly hittable.
    XCTAssertTrue(
      gridInfoControl(app).isHittable,
      "Info is not hittable while the Regular-3 inspector is expanded — the fold reached the one "
        + "control that collapses it (IMGMGR-390).")
    logBarFrames(app, state: "r3x")
    assertAtMostThreeClusters(in: app, state: "r3x")
    capture(app, name: "ipad-bar-p1-r3x")

    // (f) the at-rest action bar, Clear included, in the expanded column.
    for identifier in Self.regularActionBar {
      let control = app.descendants(matching: .any)[identifier].firstMatch
      XCTAssertTrue(
        control.waitForExistence(timeout: 10),
        "`\(identifier)` is not on the action bar with the inspector expanded.")
      XCTAssertTrue(
        control.isHittable,
        "`\(identifier)` is not hittable with the inspector expanded — the Regular bar no longer "
          + "folds Clear into More, so every at-rest control must fit the expanded column.")
    }

    // (a) expanded: each folded item is one tap into the system overflow away.
    var reach: [String] = []
    for identifier in Self.declaredAfterSearch {
      let control = app.descendants(matching: .any)[identifier].firstMatch
      if control.exists && control.isHittable {
        reach.append("\(identifier)=direct")
        continue
      }
      let label = labels[identifier] ?? identifier
      let viaOverflow = reachableThroughOverflow(in: app, identifier: identifier, label: label)
      reach.append("\(identifier)=\(viaOverflow ? "overflow" : "UNREACHABLE")")
      XCTAssertTrue(
        viaOverflow,
        "`\(identifier)` (\"\(label)\") is neither hittable on the bar nor reachable through the "
          + "system overflow with the inspector expanded — a control lost its home.")
    }
    print("WP29-P1-REACH r3x: " + reach.joined(separator: " "))

    // Moved here from `RegularSidebarShellUITests` (WP28 P2 evidence, unchanged names).
    capture(app, name: "ipad-bar-regular3-expanded-search-min")
    activateSearchAndCapture(app, name: "ipad-bar-regular3-expanded-search-active")
  }

  // MARK: - Regular-2

  func testRegular2BarOrderClustersAndCentredTitle() throws {
    let app = try launched(.regular2)
    assertEveryDeclaredItemIsHittable(in: app, state: "Regular-2")
    assertSpecOrder(in: app, state: "Regular-2")
    assertAtMostThreeClusters(in: app, state: "r2")
    assertTitleCentred(in: app, state: "Regular-2")
    capture(app, name: "ipad-bar-p1-r2")
    // Moved here from `RegularSidebarShellUITests` (WP28 P2 evidence, unchanged names).
    capture(app, name: "ipad-bar-regular2-search-min")
    activateSearchAndCapture(app, name: "ipad-bar-regular2-search-active")
  }

  // MARK: - (d) the Filter count, every width

  func testTheFilterControlStatesTheActiveFilterCount() throws {
    let app = launchedAnyWidth()
    let filter = app.descendants(matching: .any)["gridFilterControl"].firstMatch
    XCTAssertTrue(filter.waitForExistence(timeout: 15), "No 'gridFilterControl' on screen.")
    XCTAssertEqual(filter.label, "Filters", "The Filter control claims a filter at launch.")

    // Applied through the shipped popover row — the same lane `FilterPopoverUITests` drives.
    let rating4 = app.descendants(matching: .any)["filterPopoverRow-rating-4"]
    XCTAssertTrue(
      openPresentation(filter, revealing: rating4, timeout: 15),
      "The Filter popover has no '>= 4' row.")
    rating4.tap()

    let active = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Active"),
      object: app.descendants(matching: .any)["gridFilterControl"].firstMatch)
    XCTAssertEqual(
      XCTWaiter().wait(for: [active], timeout: 15), .completed,
      "Applying '>= 4' did not put the Filter control into its active state.")
    let applied = app.descendants(matching: .any)["gridFilterControl"].firstMatch
    XCTAssertEqual(
      applied.label, "Filters, 1 filter active",
      "The Filter control does not state the active count.")
    capture(app, name: "grid-filter-badge-\(layoutName(app))")
  }

  // MARK: - (e) Select and More, every width

  func testSelectEntersSelectModeAndMoreCarriesClearMarkWithoutSelect() throws {
    let app = launchedAnyWidth()
    let select = app.descendants(matching: .any)["gridSelectCommand"].firstMatch
    XCTAssertTrue(select.waitForExistence(timeout: 15), "No 'gridSelectCommand' on the bar.")
    XCTAssertTrue(
      app.navigationBars.descendants(matching: .any)["gridSelectCommand"].firstMatch.exists,
      "Select is not a navigation-bar item (\(layoutName(app))).")
    let caption = app.staticTexts["selectModeCaption"]
    XCTAssertFalse(caption.exists, "The grid launched in Select mode.")
    XCTAssertTrue(
      openPresentation(select, revealing: caption, timeout: 15),
      "The bar's Select did not enter Select mode (no 'selectModeCaption').")
    capture(app, name: "grid-select-from-bar-\(layoutName(app))")

    // Leave Select through the same control, then open More at rest.
    let exit = app.descendants(matching: .any)["gridSelectCommand"].firstMatch
    XCTAssertTrue(exit.isHittable, "The bar's Select is not hittable while Select is on.")
    exit.tap()
    XCTAssertTrue(caption.waitForNonExistence(timeout: 10), "Select did not exit Select mode.")

    let clearMark = app.descendants(matching: .any)["gridMoreMenu.more.clearMark"]
    XCTAssertTrue(
      openMoreMenu(in: app, revealing: clearMark, timeout: 15),
      "More did not open with its Clear mark row.")
    let selects = app.descendants(matching: .any).matching(identifier: "gridSelectCommand")
    XCTAssertEqual(
      selects.count, 1,
      "More still carries a Select row: 'gridSelectCommand' must exist exactly once, on the bar.")
    capture(app, name: "grid-more-open-\(layoutName(app))")
  }

  // MARK: - Assertions

  private func assertEveryDeclaredItemIsHittable(in app: XCUIApplication, state: String) {
    XCTAssertTrue(gridInfoControl(app).isHittable, "Info is not hittable at \(state).")
    XCTAssertTrue(
      regularToolbarSearchButton(app).isHittable, "The toolbar search is not hittable at \(state).")
    for identifier in Self.declaredAfterSearch {
      let control = app.descendants(matching: .any)[identifier].firstMatch
      XCTAssertTrue(
        control.waitForExistence(timeout: 10), "`\(identifier)` is not on the bar at \(state).")
      XCTAssertTrue(
        control.isHittable,
        "`\(identifier)` exists but is folded or covered at \(state), where the bar has room.")
    }
  }

  /// (a): the app-declared items in spec order, then the system search between Info and Select.
  /// Two assertions, so a red run says whether the SYSTEM placed search elsewhere (the plan's
  /// pivot trigger) or the app's own order broke.
  private func assertSpecOrder(in app: XCUIApplication, state: String) {
    let info = gridInfoControl(app)
    let declared = Self.declaredAfterSearch.map {
      app.descendants(matching: .any)[$0].firstMatch
    }
    let infoX = info.frame.minX
    let xs = declared.map(\.frame.minX)
    let reading = zip(Self.declaredAfterSearch, xs).map { "\($0)=\($1)" }.joined(separator: " ")
    let searchX = regularToolbarSearchButton(app).frame.minX
    print("WP29-P1-ORDER \(state): info=\(infoX) search=\(searchX) \(reading)")

    let appOrder = [infoX] + xs
    XCTAssertEqual(
      appOrder, appOrder.sorted(),
      "\(state): the app-declared items are not in spec order Info · Select · Filter · Arrange "
        + "(Sort · Group · Zoom) · More — \(reading), info=\(infoX).")

    let selectX = xs[0]
    XCTAssertTrue(
      infoX < searchX && searchX < selectX,
      "SEARCH-POSITION \(state): the system search (minX \(searchX)) is not between Info "
        + "(\(infoX)) and Select (\(selectX)).")
  }

  /// (b): hittable bar elements grouped by horizontal gaps; one bar, the grid's.
  private func assertAtMostThreeClusters(in app: XCUIApplication, state: String) {
    let clusters = barClusters(in: app)
    let description = clusters.map { cluster in
      "[" + cluster.names.joined(separator: ",") + " \(Int(cluster.minX))-\(Int(cluster.maxX))]"
    }
    let joined = description.joined(separator: " ")
    print("WP29-P1-CLUSTERS \(state): count=\(clusters.count) \(joined)")
    XCTAssertLessThanOrEqual(
      clusters.count, 3,
      "\(state): the grid's bar renders \(clusters.count) clusters (gap > \(Self.clusterGap) pt): "
        + joined)
  }

  /// (c): the breadcrumb (title) is centred on its bar.
  private func assertTitleCentred(in app: XCUIApplication, state: String) {
    let title = gridTitleMenuTrigger(app, names: [Self.folderOneName])
    XCTAssertTrue(title.waitForExistence(timeout: 10), "\(state): no grid title on the bar.")
    guard let bar = gridBar(in: app) else {
      XCTFail("\(state): no navigation bar carries the grid's Info control.")
      return
    }
    let offset = title.frame.midX - bar.frame.midX
    print(
      "WP29-P1-TITLE \(state): label=\"\(title.label)\" title=\(title.frame) bar=\(bar.frame) "
        + "offset=\(offset)")
    XCTAssertLessThanOrEqual(
      abs(offset), Self.titleTolerance,
      "\(state): the title's midX is \(offset) pt off its bar's midX (title \(title.frame), bar "
        + "\(bar.frame)) — the breadcrumb is not centred.")
    let subtitle = app.navigationBars.staticTexts[Self.folderOneCount]
    print(
      "WP29-P1-SUBTITLE \(state): exists=\(subtitle.exists) "
        + "frame=\(subtitle.exists ? String(describing: subtitle.frame) : "-")")
  }

  // MARK: - Bar geometry

  private struct Cluster {
    var minX: CGFloat
    var maxX: CGFloat
    var names: [String]
  }

  /// The navigation bar that carries the grid's Info control.
  private func gridBar(in app: XCUIApplication) -> XCUIElement? {
    let info = gridInfoControl(app)
    guard info.exists else { return nil }
    let center = CGPoint(x: info.frame.midX, y: info.frame.midY)
    return app.navigationBars.allElementsBoundByIndex.first { $0.frame.contains(center) }
  }

  private func barClusters(in app: XCUIApplication) -> [Cluster] {
    guard let bar = gridBar(in: app) else { return [] }
    let elements = bar.descendants(matching: .any).allElementsBoundByIndex.filter { element in
      guard element.elementType != .other, element.isHittable else { return false }
      let frame = element.frame
      return !frame.isEmpty && frame.width < bar.frame.width * 0.8
    }
    let sorted = elements.map { element -> (CGRect, String) in
      let name = element.identifier.isEmpty ? element.label : element.identifier
      return (element.frame, name)
    }.sorted { $0.0.minX < $1.0.minX }
    var clusters: [Cluster] = []
    for (frame, name) in sorted {
      if var last = clusters.last, frame.minX - last.maxX <= Self.clusterGap {
        last.maxX = max(last.maxX, frame.maxX)
        last.names.append(name)
        clusters[clusters.count - 1] = last
      } else {
        clusters.append(Cluster(minX: frame.minX, maxX: frame.maxX, names: [name]))
      }
    }
    return clusters
  }

  private func logBarFrames(_ app: XCUIApplication, state: String) {
    let elements = app.navigationBars.descendants(matching: .any).allElementsBoundByIndex
    let lines = elements.compactMap { element -> String? in
      guard element.elementType != .other, element.isHittable else { return nil }
      return "id=\(element.identifier) label=\(element.label) frame=\(element.frame)"
    }
    print("WP29-P1-BAR \(state): window=\(app.frame.size) " + lines.joined(separator: " | "))
  }

  // MARK: - Overflow

  /// The system overflow on the navigation bars — never the grid's own More (`gridMoreMenu`).
  private func overflowButton(_ app: XCUIApplication) -> XCUIElement {
    app.navigationBars.buttons
      .matching(NSPredicate(format: "label ==[c] 'More' AND identifier != 'gridMoreMenu'"))
      .firstMatch
  }

  /// Opens the overflow and looks for a hittable element carrying the item's identifier or label
  /// that was not there before the tap (the folded bar item itself may linger in the hierarchy).
  private func reachableThroughOverflow(
    in app: XCUIApplication, identifier: String, label: String
  ) -> Bool {
    let overflow = overflowButton(app)
    guard overflow.waitForExistence(timeout: 5) else { return false }
    let matches = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, label))
    let before = matches.count
    let opened = openPresentation(
      overflow, revealing: matches.element(boundBy: before), timeout: 15)
    guard opened else { return false }
    capture(app, name: "ipad-bar-p1-r3x-overflow-\(identifier)")
    let revealed = matches.element(boundBy: before)
    let reachable = revealed.exists && revealed.isHittable
    // Close the menu with a tap on the status-bar strip, which carries no control.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).tap()
    _ = revealed.waitForNonExistence(timeout: 5)
    return reachable
  }

  private func declaredLabels(in app: XCUIApplication, state: String) -> [String: String] {
    var labels: [String: String] = [:]
    for identifier in Self.declaredAfterSearch {
      let control = app.descendants(matching: .any)[identifier].firstMatch
      XCTAssertTrue(
        control.waitForExistence(timeout: 10), "`\(identifier)` is not on the bar at \(state).")
      labels[identifier] = control.label
    }
    return labels
  }

  // MARK: - Launch

  private enum Layout {
    case regular2
    case regular3
  }

  /// The fixture launch plus the layout gate: throws `XCTSkip`, with the measured window, when
  /// the window does not resolve to `layout` here (the iPhone is Compact in both orientations).
  private func launched(_ layout: Layout) throws -> XCUIApplication {
    let orientation: UIDeviceOrientation = layout == .regular2 ? .portrait : .landscapeLeft
    XCUIDevice.shared.orientation = orientation
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    XCUIDevice.shared.orientation = orientation
    _ = app.windows.firstMatch.waitForExistence(timeout: 30)
    Thread.sleep(forTimeInterval: 2.0)
    let width = app.frame.size.width
    let resolves: Bool
    switch layout {
    case .regular3:
      resolves = width >= Self.regular3WidthThreshold
    case .regular2:
      resolves = width < Self.regular3WidthThreshold && width >= Self.compactShellWidthCeiling
    }
    guard resolves else {
      throw XCTSkip("IMGMGR-452 window=\(app.frame.size) does not resolve to \(layout) here.")
    }
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "The DEBUG fixture composition never rendered (sign-in, blank, or a failed stub).")
    // The bar settles after the content that fills the pane under it, and the title's count
    // after the sidebar's tree load.
    Thread.sleep(forTimeInterval: 1.5)
    return app
  }

  /// The fixture launch at whatever width this destination resolves in the pinned orientation.
  private func launchedAnyWidth() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()
    XCUIDevice.shared.orientation = Self.pinnedOrientation
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "The DEBUG fixture composition never rendered (sign-in, blank, or a failed stub).")
    Thread.sleep(forTimeInterval: 1.0)
    return app
  }

  private func layoutName(_ app: XCUIApplication) -> String {
    let width = app.frame.size.width
    if width < Self.compactShellWidthCeiling { return "compact" }
    return width >= Self.regular3WidthThreshold ? "regular3" : "regular2"
  }

  // MARK: - Evidence

  private func activateSearchAndCapture(
    _ app: XCUIApplication, name: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard expandRegularToolbarSearch(app, context: name) != nil else {
      capture(app, name: "\(name)-NOT-EXPANDED")
      XCTFail(
        "\(name): the toolbar search did not activate (no hittable field taking typed text).",
        file: file, line: line)
      return
    }
    Thread.sleep(forTimeInterval: 1.0)
    capture(app, name: name)
  }

  private func capture(_ app: XCUIApplication, name: String) {
    logBarFrames(app, state: name)
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
