import XCTest

/// IMGMGR-389 acceptance: ONE pinned "Needs review" section above the folder tree, listing the
/// shoots whose served readiness is `ready_to_review` or `review_in_progress` — and absent
/// entirely when no shoot is in that state.
///
/// The membership rule is the premise gate's adjudication of 2026-09-16 (IMGMGR-389 comment
/// 6913): a presentation filter over the SHIPPED six-value readiness vocabulary, never a
/// client-side re-derivation and never the unshipped server-side review-done predicate
/// (IMGMGR-391). `needs_previews` (not reviewable yet), `historical_unreviewed` (the pre-app
/// history would flood the section), `sync_problem` (a problem, not an unresolved review) and
/// `ready_for_editing` (done) are excluded on purpose.
///
/// Driven through the production composition, like every folder-tree suite in this target, and
/// asserting nothing idiom-shaped: the home is one component on both destinations (WP16 P5), so
/// both legs of the gate walk the same rows.
///
/// Launch fixture: `-UITestStubGrid` plus `-UITestStubSkipAutoSelect`, so the app stops at the
/// home. Of the fixture's six summaries exactly TWO are members — folder 1
/// (`review_in_progress`, Incoming's root shoot) and folder 21 (`ready_to_review`, the archive
/// shoot) — and the other four are one each of the excluded values: 3 `sync_problem`,
/// 5 `historical_unreviewed`, 11 `ready_for_editing`, 22 `needs_previews`
/// (`DebugStubTransport.fixtureSummaries()`).
final class NeedsReviewSectionUITests: OrientationPinnedUITestCase {

  /// The section is on the home at launch, states how many shoots are in it, lists exactly the
  /// members in the order the server sent them, and each row enters that shoot's grid.
  func testThePinnedSectionListsTheShootsAwaitingReviewAndOpensOne() throws {
    let app = launch(extraArguments: [])

    let section = app.descendants(matching: .any)["needsReviewSection"].firstMatch
    XCTAssertTrue(
      section.waitForExistence(timeout: 30),
      "The home carries no pinned \"Needs review\" section. IMGMGR-389 pins ONE above the tree, "
        + "on every size class where the tree home renders.")

    // WP28 P2 (IMGMGR-449): at Regular the section sits under the sidebar's "Shoots" header.
    if !rendersCompactShell(app) {
      let shoots = app.descendants(matching: .any)["sidebarSectionShoots"].firstMatch
      XCTAssertTrue(
        shoots.waitForExistence(timeout: 15),
        "At Regular the pinned section has no \"Shoots\" header above it.")
      XCTAssertLessThan(
        shoots.frame.minY, section.frame.minY,
        "\"Shoots\" does not sit above the \"Needs review\" header.")
    }

    let count = app.descendants(matching: .any)["needsReviewCount"].firstMatch
    XCTAssertTrue(count.waitForExistence(timeout: 15), "The section header states no count.")
    XCTAssertEqual(
      count.label, "2",
      "The count must be the number of MEMBER shoots — the fixture serves six summaries, of "
        + "which folder 1 (review_in_progress) and folder 21 (ready_to_review) are the two in "
        + "the set; a count of 6 would mean the section lists every shoot.")

    // The members, in the order `/api/folder-summaries` sent them (folder 1 before folder 21):
    // the tree relies on the server's order and this section takes the same posture.
    for folderID in [1, 21] {
      XCTAssertTrue(
        app.descendants(matching: .any)["needsReviewRow-\(folderID)"].firstMatch.waitForExistence(
          timeout: 15),
        "Folder \(folderID) is a member of the set and carries no row in the pinned section.")
    }

    // The non-members are the control, asserted only after the section itself was found, so an
    // absence here is a row that is not there rather than a section that never rendered.
    for folderID in [3, 5, 11, 22] {
      XCTAssertFalse(
        app.descendants(matching: .any)["needsReviewRow-\(folderID)"].firstMatch.exists,
        "Folder \(folderID)'s readiness is outside the membership set, and it is listed anyway — "
          + "the section is a filter over readiness, not the shoot list.")
    }
    attach(named: "IMGMGR-389-needs-review-section")

    app.descendants(matching: .any)["needsReviewRow-1"].firstMatch.tap()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Tapping a pinned row never reached the grid. A pinned row opens the shoot through the "
        + "SAME selection and GridStore.selectShoot(folderID:sourceTier:) path a tree folder row "
        + "takes — there is no second navigation path.")
    attach(named: "IMGMGR-389-needs-review-row-grid")
  }

  /// Nothing awaiting review renders NOTHING: no header, no count, no placeholder.
  ///
  /// `-UITestSummariesReviewed` serves the same six fixture summaries with every readiness
  /// rewritten to `ready_for_editing`, which is the only way to drive this through the real UI —
  /// the shipped fixture always has members. The flag's effect is asserted FIRST, on a shoot row's
  /// own readiness badge, so the absence below cannot be an ignored launch argument, and the tree
  /// is walked before it, so the absence cannot be a home that never loaded.
  func testTheSectionIsAbsentWhenNoShootAwaitsReview() throws {
    let app = launch(extraArguments: ["-UITestSummariesReviewed"])
    // WP28 P1 (IMGMGR-448): at Compact the tree is the Library tab's, and the pinned section's one
    // home is the Shoots tab — so the walk happens in Library and the absence is read on Shoots.
    let compact = rendersCompactShell(app)
    showLibraryIfCompact(app)

    let incoming = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(reveal(incoming, in: app), "The Incoming tier row never appeared.")
    incoming.tap()

    let shootRow = app.descendants(matching: .any)["folderRow-1"].firstMatch
    XCTAssertTrue(reveal(shootRow, in: app), "The fixture's root shoot row never appeared.")

    let badge = app.descendants(matching: .any)["folderReadiness-1"].firstMatch
    XCTAssertTrue(badge.waitForExistence(timeout: 15), "The shoot row carried no readiness badge.")
    XCTAssertEqual(
      badge.label, "Ready for editing",
      "-UITestSummariesReviewed did not reach the summaries: folder 1 still states its shipped "
        + "fixture readiness. Without this, the absence asserted below would prove nothing.")
    attach(named: "IMGMGR-389-every-shoot-reviewed")

    if compact {
      selectCompactTab(app, title: "Shoots")
      XCTAssertTrue(
        app.descendants(matching: .any)["recentRow-1"].firstMatch.waitForExistence(timeout: 15),
        "The Shoots tab never listed the reviewed shoot under Recent, so the absence below "
          + "could be a Shoots tab that never loaded.")
    }
    XCTAssertFalse(
      app.descendants(matching: .any)["needsReviewSection"].firstMatch.exists,
      "The pinned section is still on screen with no shoot awaiting review. Empty means the "
        + "section does not render at all — no header and no placeholder.")
    XCTAssertFalse(
      app.descendants(matching: .any)["needsReviewCount"].firstMatch.exists,
      "The section's count survived an empty membership — an empty section renders nothing, "
        + "including its header.")
    if !compact {
      // WP28 P2 (IMGMGR-449): "Shoots" goes with the section it names; the tree keeps its
      // "Library" header, which is the positive control that sidebar headers render at all.
      XCTAssertTrue(
        app.descendants(matching: .any)["sidebarSectionLibrary"].firstMatch.exists,
        "The sidebar's \"Library\" header is missing, so the absence below proves nothing.")
      XCTAssertFalse(
        app.descendants(matching: .any)["sidebarSectionShoots"].firstMatch.exists,
        "\"Shoots\" renders with no Needs-review rows under it; an empty section renders nothing.")
    }
  }

  private func launch(extraArguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"] + extraArguments
    app.launch()
    return app
  }

  /// Scrolls the home until `element` is on screen, in BOTH directions — the same helper the
  /// sibling folder-tree suites carry, copied rather than extracted for the reason they give
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

  private func attach(named name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let size = screenshot.image.size
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(name)-\(Int(size.width))x\(Int(size.height))"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
