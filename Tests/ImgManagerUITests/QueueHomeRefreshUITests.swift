import XCTest

/// IMGMGR-499: the Library home's pull-to-refresh has a visible twin — the "Refresh" row of the
/// tree's View menu (`folderTreeViewMenu`: the Compact Library tab, the Regular sidebar) — and it
/// runs the same `QueueHomeRefresh.run(summaries:tree:)` the gesture does.
///
/// Reviews r1/r2: the decisive reading is PER TRIGGER, on `debugProbe.homeRefresh`.
/// `RootView.refreshQueueHome()` — the gesture's and the row's one path — counts its summaries
/// half once it has run (`homeRefreshSummaries`) and records the tree reload token it ISSUED
/// (`homeRefreshTreeToken`); the tree's own load path records the highest token a load has
/// COMPLETED for (`treeLoadCompletedToken`). The launch load and the foreground resume never
/// issue through that path, so before the tap the path must read 0 / no token (observed, or the
/// test fails), and after it the summaries half must read 1 and a tree load must complete for
/// the issued token, which is strictly greater than every token completed before the tap. The
/// served-request counts must also grow — supporting evidence, not the attribution.
final class QueueHomeRefreshUITests: OrientationPinnedUITestCase {

  func testTheTreeViewMenuRefreshRowRerunsBothHalvesOfTheHomeRefresh() throws {
    let app = XCUIApplication()
    // Stopped at the tree home, as `TreeViewMenuPruneUITests` launches for the same menu.
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"]
    app.launch()
    showLibraryIfCompact(app)

    let probe = app.descendants(matching: .any)["debugProbe.homeRefresh"].firstMatch
    XCTAssertTrue(
      probe.waitForExistence(timeout: 30), "The tree home carries no home-refresh probe.")
    // Explicit, not assumed: nothing has run the refresh path yet, and the home has loaded.
    XCTAssertTrue(
      waitFor("value CONTAINS 'homeRefreshSummaries=0 homeRefreshTreeToken=0 '", probe, timeout: 5),
      "The home refresh path ran before Refresh was tapped: \(String(describing: probe.value)).")
    XCTAssertTrue(
      waitFor(
        "value MATCHES 'summariesRequests=[1-9][0-9]* folderTreeRequests=[1-9][0-9]* .*'",
        probe, timeout: 30),
      "The tree home never loaded its summaries and tree: \(String(describing: probe.value)).")
    // And a tree load has COMPLETED (the probe reads -1 until one has), so the baseline below is
    // a finished tree, never a load still in flight.
    XCTAssertTrue(
      waitFor("NOT (value CONTAINS 'treeLoadCompletedToken=-1')", probe, timeout: 30),
      "No tree load completed at launch: \(String(describing: probe.value)).")

    let viewMenu = app.descendants(matching: .any)["folderTreeViewMenu"].firstMatch
    XCTAssertTrue(
      viewMenu.waitForExistence(timeout: 15), "The tree home exposes no View menu at this width.")
    // Identifier OR label, as the Shoots title menu's Refresh row is found
    // (`CompactTabShellUITests`): a menu row's identifier is not guaranteed to reach XCUITest.
    let row = app.buttons
      .matching(
        NSPredicate(format: "identifier == 'queueHomeRefreshMenuRow' OR label == 'Refresh'")
      )
      .firstMatch
    XCTAssertTrue(
      openPresentation(viewMenu, revealing: row, timeout: 20),
      "The tree's View menu did not offer \"Refresh\".")
    XCTAssertTrue(row.isHittable, "The tree View menu's Refresh row cannot be tapped.")
    let before = read(probe)
    XCTAssertEqual(before.homeSummaries, 0, "The refresh path ran while the menu was opening.")
    XCTAssertEqual(before.issuedToken, 0, "The refresh path ran while the menu was opening.")
    XCTAssertGreaterThanOrEqual(
      before.completedToken, 0, "No tree load had completed before the tap.")
    row.tap()

    // The summaries half of THIS path, exactly once.
    XCTAssertTrue(
      waitFor("value CONTAINS 'homeRefreshSummaries=1 '", probe, timeout: 15),
      "Refresh did not run the summaries half once: \(String(describing: probe.value)).")
    // The tree half: a token issued by THIS tap, newer than any load completed before it, and a
    // tree load that completed for it. Without the token bump no load ever runs for it.
    let issued = try XCTUnwrap(
      waitForIssuedTokenCompletion(probe, timeout: 15),
      "Refresh issued no tree reload token, or no tree load completed for it: "
        + "\(String(describing: probe.value)).")
    XCTAssertGreaterThan(
      issued, before.completedToken,
      "The token Refresh issued (\(issued)) is not newer than the tree's before the tap.")
    // And they reached the wire: a summaries request and folder-tree requests beyond the
    // reading taken just before the tap.
    let after = counts(probe, exceeding: before, timeout: 15)
    XCTAssertGreaterThan(
      after.summaries, before.summaries,
      "Refresh did not re-fetch the summaries (\(before.summaries) before, "
        + "\(after.summaries) after).")
    XCTAssertGreaterThan(
      after.tree, before.tree,
      "Refresh did not reload the folder tree (\(before.tree) before, \(after.tree) after).")
  }

  // MARK: - Probe

  private struct Counts {
    var summaries: Int
    var tree: Int
    var homeSummaries: Int
    var issuedToken: Int
    var completedToken: Int
  }

  private func read(_ probe: XCUIElement) -> Counts {
    let raw = (probe.value as? String) ?? ""
    return Counts(
      summaries: number(after: "summariesRequests=", in: raw),
      tree: number(after: "folderTreeRequests=", in: raw),
      homeSummaries: number(after: "homeRefreshSummaries=", in: raw),
      issuedToken: number(after: "homeRefreshTreeToken=", in: raw),
      completedToken: number(after: "treeLoadCompletedToken=", in: raw))
  }

  /// The integer after `key`, sign included; -1 when absent (the probe's "none yet").
  private func number(after key: String, in text: String) -> Int {
    guard let range = text.range(of: key) else { return -1 }
    let digits = text[range.upperBound...].prefix(while: { $0.isNumber || $0 == "-" })
    return Int(digits) ?? -1
  }

  /// The token Refresh issued, once a tree load has completed for it; nil if either is missing
  /// when `timeout` runs out. Waits on the probe's value changing, never a blind sleep.
  private func waitForIssuedTokenCompletion(_ probe: XCUIElement, timeout: TimeInterval) -> Int? {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while true {
      let raw = (probe.value as? String) ?? ""
      let current = read(probe)
      if current.issuedToken > 0, current.completedToken >= current.issuedToken {
        return current.issuedToken
      }
      guard Date() < deadline else { return nil }
      let moved = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value != %@", raw), object: probe)
      _ = XCTWaiter().wait(for: [moved], timeout: max(0.1, deadline.timeIntervalSinceNow))
    }
  }

  private func waitFor(_ format: String, _ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
    return XCTWaiter.wait(for: [done], timeout: timeout) == .completed
  }

  /// The counts once BOTH request counts exceed `before`, or whatever they read when `timeout`
  /// runs out — waiting on the probe's value changing, never a blind sleep.
  private func counts(_ probe: XCUIElement, exceeding before: Counts, timeout: TimeInterval)
    -> Counts
  {
    let deadline = Date(timeIntervalSinceNow: timeout)
    var raw = (probe.value as? String) ?? ""
    var current = read(probe)
    while !(current.summaries > before.summaries && current.tree > before.tree),
      Date() < deadline
    {
      let moved = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value != %@", raw), object: probe)
      _ = XCTWaiter().wait(for: [moved], timeout: max(0.1, deadline.timeIntervalSinceNow))
      raw = (probe.value as? String) ?? ""
      current = read(probe)
    }
    return current
  }
}
