import XCTest

/// IMGMGR-350 checkpoint-2, findings B1 and B3: what the tree home does when something it does
/// NOT depend on fails, and when one of the three things it does depend on fails.
///
/// Both are driven through the production composition against the DEBUG fixture, with one
/// launch argument each turning a single endpoint into a 500 — the states no shipped entry point
/// can produce, because the fixture otherwise answers everything.
///
/// Runs on BOTH gate destinations and asserts nothing idiom-shaped: the tree is one component on
/// both idioms, and neither of these states is a layout question.
final class TreeHomeDegradedUITests: OrientationPinnedUITestCase {

  /// B1: `/api/folder-summaries` down, `/api/folders` healthy. The home used to become "Not
  /// connected" with nothing under it; the tree it never needed the summaries for must render.
  func testASummariesOutageStillRendersTheWholeTree() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-UITestStubGrid", "-UITestStubSkipAutoSelect", "-UITestFailSummaries",
    ]
    app.launch()
    // WP28 P1 (IMGMGR-448): at Compact the tree is the Library tab's; Shoots is the launch tab.
    showLibraryIfCompact(app)

    for tier in ["Incoming", "Edits", "Archive"] {
      let branch = app.descendants(matching: .any)["folderTreeTier-\(tier)"].firstMatch
      XCTAssertTrue(
        reveal(branch, in: app),
        "A /api/folder-summaries outage blanked the \(tier) tier. The summaries feed the row "
          + "badge and the widget, never the tree itself — the folder load answered.")
    }
    attach(named: "B1-summaries-outage-tree-renders")

    // And the reader is told, rather than left to wonder why a badge is missing later.
    // `DegradedStateCopy.notConnected`, verbatim (ConnectivityState.swift:11).
    XCTAssertTrue(
      app.staticTexts["Not connected to the home network"].firstMatch.waitForExistence(
        timeout: 10),
      "The degraded notice never appeared — a summaries outage must still be stated.")
  }

  /// Checkpoint-3 finding F1: the summaries' own loading states must never hide a tree that is
  /// already on screen. `QueueStore` sits in its first-load phase for as long as
  /// `/api/folder-summaries` takes — and a "Try Again" tap after a summaries outage puts it back
  /// there — so a phase-gated home replaced a loaded tree with a centered spinner.
  ///
  /// Driven with a summaries endpoint that NEVER answers, so the state is held rather than
  /// flashed: the tree must be on screen, and the summaries' copy must not.
  func testASummariesLoadThatNeverFinishesNeverHidesTheTree() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-UITestStubGrid", "-UITestStubSkipAutoSelect", "-UITestHangSummaries",
    ]
    app.launch()
    // WP28 P1 (IMGMGR-448): at Compact the tree is the Library tab's; Shoots is the launch tab.
    showLibraryIfCompact(app)

    let incoming = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(
      reveal(incoming, in: app),
      "A summaries load that has not finished hid the whole home. The tree has its own load and "
        + "its own placeholder; the summaries decide neither.")
    for tier in ["Edits", "Archive"] {
      XCTAssertTrue(
        app.descendants(matching: .any)["folderTreeTier-\(tier)"].firstMatch.exists,
        "The \(tier) tier is missing while the summaries are still loading.")
    }
    XCTAssertFalse(
      app.staticTexts["Loading shoots…"].firstMatch.exists,
      "The summaries' centered first-load copy is on screen over the tree.")
    attach(named: "F1-summaries-still-loading-tree-renders")
  }

  /// B3: one tier of `/api/folders` down. That tier says so where its branch would be, the other
  /// two render, and the empty-library copy — which means "this library has nothing in it" — is
  /// nowhere on screen.
  func testAFailedTierSaysSoAndTheOthersStillRender() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-UITestStubGrid", "-UITestStubSkipAutoSelect", "-UITestFailArchiveFolders",
    ]
    app.launch()
    // WP28 P1 (IMGMGR-448): at Compact the tree is the Library tab's; Shoots is the launch tab.
    showLibraryIfCompact(app)

    // The two healthy tiers first: they are this test's positive control, so the archive row's
    // own state below is read against a tree that was actually drawn (LSN-0033).
    for tier in ["Incoming", "Edits"] {
      let branch = app.descendants(matching: .any)["folderTreeTier-\(tier)"].firstMatch
      XCTAssertTrue(
        reveal(branch, in: app),
        "One unreachable tier took the \(tier) tier with it — a partial failure renders the rows "
          + "that did arrive.")
    }

    let failed = app.descendants(matching: .any)["folderTreeTierFailed-Archive"].firstMatch
    XCTAssertTrue(
      reveal(failed, in: app),
      "The unreachable Archive tier rendered nothing of its own. An unknown tier is not an empty "
        + "tier: it has to say it could not be loaded, where its branch would have been.")
    attach(named: "B3-failed-tier-says-so")

    XCTAssertFalse(
      app.descendants(matching: .any)["folderTreeEmpty"].firstMatch.exists,
      "\"No shoots\" is on screen while a tier is unreachable — that copy means the library is "
        + "empty, which is precisely what a failed load cannot know.")
  }

  /// Scrolls the home list until `element` is on screen, in BOTH directions — the same helper the
  /// sibling folder-tree suites carry, copied rather than extracted for the reason they give.
  private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 8) -> Bool {
    if element.waitForExistence(timeout: 15), element.isHittable { return true }
    let firstList = app.collectionViews.firstMatch
    let scroller: XCUIElement = firstList.exists ? firstList : app
    for _ in 0..<swipes {
      scroller.swipeUp()
      if element.exists, element.isHittable { return true }
    }
    for _ in 0..<(swipes * 2) {
      scroller.swipeDown()
      if element.exists, element.isHittable { return true }
    }
    return element.exists && element.isHittable
  }

  private func attach(named name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let size = screenshot.image.size
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(name)-\(Int(size.width))x\(Int(size.height))"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
