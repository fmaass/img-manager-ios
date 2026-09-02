import XCTest

/// IMGMGR-350 acceptance: the HOME is the tier-grouped folder tree — Incoming / Edits / Archive
/// at the top level, each folding into the server's own taxonomy — and the readiness-sectioned
/// queue is no longer the home.
///
/// Driven through the production composition, like every folder-tree test in this target: it
/// mounts the real sidebar, opens a tier, opens a year container, opens the MONTH FOLD inside it
/// (`folderTreeMonth-<parentId>-<yyyy>-<mm>`, the presentation-only row P1 ported from the web)
/// and taps the shoot underneath through to the grid.
///
/// The three widths the story names are covered by the two destinations plus one launch
/// argument, never by asking the app what device it is on: the iPhone leg is Compact for every
/// method here; the iPad leg is the DEFAULT Regular-3 (inspector shown, sidebar present) for the
/// methods that pass no argument, and Regular-2 for `-UITestInspectorHidden`, which collapses the
/// inspector column exactly as the shipped control does (`RootView.showRegular3Inspector`).
///
/// Launch fixture: `-UITestStubGrid` (DEBUG-only `DebugStubTransport`, never in a Release
/// archive) plus `-UITestStubSkipAutoSelect`, so the app stops at the home. That fixture answers
/// per `(source_tier, tree)` since IMGMGR-350 P2: Incoming is `2026-08-27 — Stub Shoot` (id 1)
/// beside the `2026` container (id 2) holding two September shoots (ids 3 and 5); Edits is its
/// own shoot (id 11); Archive is a real shoot (id 21) beside a zero-count mirrored folder (22).
final class TierHomeUITests: OrientationPinnedUITestCase {

  func testTheHomeIsTheTierTreeAndAMonthFoldReachesAShoot() throws {
    let app = launch(extraArguments: [])
    walkIncomingToTheShootAndIntoTheGrid(app, label: "P2-tier-home-default")
  }

  /// The same walk with the inspector column collapsed — Regular-2 on the iPad destination, and
  /// unchanged Compact on the phone (the flag only governs Regular-3's third column).
  func testTheHomeIsTheTierTreeWithTheInspectorCollapsed() throws {
    let app = launch(extraArguments: ["-UITestInspectorHidden"])
    walkIncomingToTheShootAndIntoTheGrid(app, label: "P2-tier-home-inspector-collapsed")
  }

  /// All three tiers are top-level places, and Edits is one of them: the owner kept it as a
  /// direct way in ("we can leave as is, its nice to access the edits directly"). Its shoot
  /// exists in no other tier, which is what proves the three branches are three taxonomies
  /// rather than one repeated.
  func testEveryTierIsATopLevelPlaceAndEditsReachesItsOwnShoot() throws {
    let app = launch(extraArguments: [])

    for tier in ["Incoming", "Edits", "Archive"] {
      let branch = app.descendants(matching: .any)["folderTreeTier-\(tier)"].firstMatch
      XCTAssertTrue(
        reveal(branch, in: app),
        "The \(tier) tier is not a top-level row of the home — IMGMGR-350 stacks all three.")
    }

    let edits = app.descendants(matching: .any)["folderTreeTier-Edits"].firstMatch
    edits.tap()
    let editsShoot = app.descendants(matching: .any)["folderRow-11"].firstMatch
    XCTAssertTrue(
      reveal(editsShoot, in: app),
      "The Edits tier reached no shoot of its own. `edits` is the same source_tier as incoming "
        + "and differs only by its tree prefix, so a tree that renders the incoming taxonomy "
        + "under this label would pass everything except this.")
    attach(named: "P2-tier-home-edits")

    editsShoot.tap()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Tapping the Edits shoot never reached the grid — every tree row enters the SAME grid "
        + "through GridStore.selectShoot(folderID:sourceTier:).")
  }

  // MARK: - The walk

  private func walkIncomingToTheShootAndIntoTheGrid(_ app: XCUIApplication, label: String) {
    // The home IS the tree: the tier row is here without opening anything, and the wrapper the
    // tree used to live under is gone. Asserted in that order, so the absence below is read
    // against a surface that was found (LSN-0033).
    let incoming = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(
      reveal(incoming, in: app),
      "The Incoming tier row never appeared. Since IMGMGR-350 the tier tree IS the home, not a "
        + "disclosure below the readiness sections.")
    XCTAssertFalse(
      app.descendants(matching: .any)["foldersDisclosure"].firstMatch.exists,
      "The old \"Folders\" disclosure is still on screen — the tree was supposed to be promoted "
        + "to the home, not nested under its own wrapper.")
    attach(named: "\(label)-home")

    incoming.tap()
    let container = app.descendants(matching: .any)["folderContainer-2"].firstMatch
    XCTAssertTrue(reveal(container, in: app), "The year container never appeared under Incoming.")

    // The year's dated children are folded into a month row: no folder id, not selectable, and
    // the only way down to the shoots it holds.
    app.descendants(matching: .any)["folderDisclose-2"].firstMatch.tap()
    let month = app.descendants(matching: .any)["folderTreeMonth-2-2026-09"].firstMatch
    XCTAssertTrue(
      reveal(month, in: app),
      "The year's dated shoots did not fold into a month row — `folderTreeMonth-2-2026-09` is "
        + "the fold P1 ported from the web (lib/folderTree.ts:222).")
    attach(named: "\(label)-month-fold")

    app.descendants(matching: .any)["folderDisclose-2-2026-09"].firstMatch.tap()
    let shoot = app.descendants(matching: .any)["folderRow-3"].firstMatch
    XCTAssertTrue(
      reveal(shoot, in: app), "Opening the month fold revealed none of the shoots it folds.")

    shoot.tap()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Tapping a shoot under a month fold never reached the grid — a fold is presentation only "
        + "and must not change what a row underneath it does.")
    attach(named: "\(label)-grid")
  }

  private func launch(extraArguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"] + extraArguments
    app.launch()
    return app
  }

  /// Scrolls the home until `element` is on screen, in BOTH directions — the same helper the
  /// sibling folder-tree suites carry, copied rather than extracted for the same reason they give
  /// (extracting it would edit shipped test files this suite is not otherwise touching).
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

  /// Screenshots are retained as XCTAttachments in the run's `.xcresult` under the gate's own
  /// DerivedData — the size suffix distinguishes the iPhone destination's capture from the iPad's
  /// without asking the app anything idiom-shaped.
  private func attach(named name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let size = screenshot.image.size
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(name)-\(Int(size.width))x\(Int(size.height))"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
