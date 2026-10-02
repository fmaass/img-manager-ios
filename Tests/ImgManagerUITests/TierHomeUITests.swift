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
/// The widths are covered by the two destinations plus one launch argument, never by asking the
/// app what device it is on: the iPhone leg is Compact for every method here, and the iPad leg is
/// this class's pinned portrait, where the tree is beside the grid. Since IMGMGR-390 the
/// inspector starts COLLAPSED wherever the width has one, so a plain launch is the collapsed
/// state and `-UITestInspectorShown` is what asks for the expanded one
/// (`RootView.showInspector`, expanded by that flag on the first resolve to Regular-3 only).
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

  /// The same walk with the inspector column EXPANDED — the state that is no longer the default
  /// (IMGMGR-390), so it is the one a launch argument now has to ask for. The flag only governs
  /// Regular-3's third column, so Compact and Regular-2 walk exactly as above.
  func testTheHomeIsTheTierTreeWithTheInspectorExpanded() throws {
    let app = launch(extraArguments: ["-UITestInspectorShown"])
    walkIncomingToTheShootAndIntoTheGrid(app, label: "P2-tier-home-inspector-expanded")
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
    // WP28 P2 (IMGMGR-449): at Regular the three tiers are the sidebar's "Library" section.
    if !rendersCompactShell(app) {
      let library = app.descendants(matching: .any)["sidebarSectionLibrary"].firstMatch
      let incoming = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
      XCTAssertTrue(
        library.exists, "At Regular the tier rows have no \"Library\" header above them.")
      XCTAssertLessThan(
        library.frame.minY, incoming.frame.minY, "\"Library\" does not sit above the tiers.")
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

  /// IMGMGR-400 (owner device pass, TestFlight 0.12.0 (15)): "the actual image folders dont open
  /// at all to show pictures". A folder row of ANY kind must enter the grid on a tap, exactly as
  /// the web does (`FolderTreeBranch.vue:63` selects any folder on its name). The shipped tree
  /// wired the tap ONLY where `FolderTreeNode.isSelectableShoot` was true — `ShootListFilter
  /// .shootKinds` = {dated, dated_split} — so every import/project/template/other folder holding
  /// images was inert on the device (156 such leaves in production).
  ///
  /// The fixture's `template` leaf (id 4, kind `template`, 3 images, under the shoot id 3) is
  /// that case in the LIVE vocabulary (IMGMGR-173). Its handle is `folderContainer-4` and not
  /// `folderRow-4`: `FolderTreeRowPresentation.rowIdentifier` still splits the two prefixes by
  /// `isSelectableShoot`, which this fix deliberately leaves alone — the shoot-list semantics
  /// (cover thumbnail, subline, readiness badge, `ShootListFilter`) are unchanged and only the
  /// TAP was widened.
  ///
  /// The walk also pins the other half of the web's behaviour on a folder that has children: the
  /// shoot id 3 is opened by its CHEVRON, which reveals the template row rather than navigating.
  func testAFolderOfAnyKindEntersTheGridNotOnlyADatedShoot() throws {
    let app = launch(extraArguments: [])

    let incoming = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(reveal(incoming, in: app), "The Incoming tier row never appeared.")
    // IMGMGR-462: Compact launches with Incoming open; a bare tap would close it.
    openTreeTier(incoming, showing: app.descendants(matching: .any)["folderRow-1"].firstMatch)

    app.descendants(matching: .any)["folderDisclose-2"].firstMatch.tap()
    let month = app.descendants(matching: .any)["folderTreeMonth-2-2026-09"].firstMatch
    XCTAssertTrue(reveal(month, in: app), "The year container revealed no month fold.")
    app.descendants(matching: .any)["folderDisclose-2-2026-09"].firstMatch.tap()

    let shoot = app.descendants(matching: .any)["folderRow-3"].firstMatch
    XCTAssertTrue(reveal(shoot, in: app), "The month fold revealed none of the shoots it folds.")

    // The chevron on a row that BOTH navigates and expands still only expands.
    app.descendants(matching: .any)["folderDisclose-3"].firstMatch.tap()
    let template = app.descendants(matching: .any)["folderContainer-4"].firstMatch
    XCTAssertTrue(
      reveal(template, in: app),
      "The shoot's own chevron revealed no `template` subfolder — the fixture nests one (id 4) "
        + "and the chevron must still open it.")
    attach(named: "IMGMGR-400-non-dated-folder-reachable")

    template.tap()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Tapping a folder whose kind is not a dated shoot never reached the grid (IMGMGR-400): a "
        + "template/import/project/other folder holding images must enter the SAME grid through "
        + "GridStore.selectShoot(folderID:sourceTier:).")
    attach(named: "IMGMGR-400-non-dated-folder-grid")
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

    // IMGMGR-462: Compact launches with Incoming open; a bare tap would close it.
    openTreeTier(incoming, showing: app.descendants(matching: .any)["folderRow-1"].firstMatch)
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
    // WP28 P1 (IMGMGR-448): at Compact the tree is the Library tab's; Shoots is the launch tab.
    showLibraryIfCompact(app)
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
