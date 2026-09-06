import XCTest

/// P7 (IMGMGR-217) acceptance, driven through the PRODUCTION composition rather than an extracted
/// helper — the same discipline P6's browse test was rebuilt around (its diff-gate round 1,
/// blocker 2). `FolderTreeModelTests` pins the pure decisions; only this one mounts the sidebar,
/// opens a CONTAINER that is not itself a shoot, reaches a shoot two levels down, filters the
/// tree from the search field and taps through to the grid.
///
/// Nothing here can pass against the pre-P7 flat list: that list rendered shoot leaves only, so
/// no container row, no nested row and no expand control existed to find, and there was no search
/// field at all.
///
/// Runs on BOTH gate destinations and asserts nothing idiom-shaped — the iPad run is the
/// Regular-3 evidence, the iPhone run the Compact evidence, and the retained attachments are the
/// phase's screenshots.
///
/// Launch fixture: `-UITestStubGrid` (DEBUG-only `DebugStubTransport`, never in a Release
/// archive) plus `-UITestStubSkipAutoSelect`, so the app stops at the home. That fixture's
/// incoming tier is `2026-08-27 — Stub Shoot` (id 1, a root-level shoot) beside `2026` (id 2, a
/// container) over `2026-09-14 — Wandern` (id 3) over `template` (id 4).
///
/// IMGMGR-350 changed two things about the walk and nothing about the property: the tree is the
/// HOME (no "Folders" disclosure above it, and the tier is Incoming), and the year's dated
/// children now sit under a presentation-only MONTH FOLD, so reaching the nested shoot opens one
/// more row. The fold carries no folder id and is not selectable — which is why the walk still
/// ends on `folderRow-3`.
final class FolderTreeHierarchyUITests: OrientationPinnedUITestCase {

  func testTheTreeNestsTwoLevelsAndTheSearchFieldFiltersIt() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"]
    app.launch()

    let localTier = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(reveal(localTier, in: app), "The Incoming tier branch never appeared.")
    localTier.tap()

    // Level one: a folder that is NOT a shoot, which is exactly what the pre-P7 list dropped —
    // and its expand control, which is a separate button from the row's own tap target.
    let expander = app.descendants(matching: .any)["folderDisclose-2"].firstMatch
    XCTAssertTrue(
      reveal(expander, in: app),
      "The container's expand control never appeared — the sidebar is still rendering a flat "
        + "list of shoot leaves rather than the server's folder hierarchy (IMGMGR-217).")
    expander.tap()

    // Level two: the month fold the year's dated children now sit under (IMGMGR-350 P1).
    let month = app.descendants(matching: .any)["folderTreeMonth-2-2026-09"].firstMatch
    XCTAssertTrue(
      reveal(month, in: app),
      "The year container revealed no month fold — its dated children are grouped under one "
        + "(lib/folderTree.ts:222), and the shoot below is reached through it.")
    app.descendants(matching: .any)["folderDisclose-2-2026-09"].firstMatch.tap()

    // Level three: the shoot underneath it.
    let nested = app.descendants(matching: .any)["folderRow-3"].firstMatch
    XCTAssertTrue(
      reveal(nested, in: app),
      "Expanding the container revealed no nested shoot — the tree is not two levels deep.")
    attach(named: "P7-tree-two-levels")

    let field = app.textFields["folderTreeSearchField"].firstMatch
    XCTAssertTrue(reveal(field, in: app), "The folder search field never appeared.")

    // A term nothing matches produces the empty state. This runs FIRST as the positive control
    // (LSN-0033) for the absence asserted next: "the row was gone" cannot then be the list
    // merely never having built it.
    field.tap()
    field.typeText("zzzz-no-such-folder\n")
    XCTAssertTrue(
      app.descendants(matching: .any)["folderTreeNoMatches"].firstMatch.waitForExistence(
        timeout: 10),
      "A search matching nothing produced no empty state — the filter is not running at all.")
    attach(named: "P7-tree-search-no-matches")

    app.descendants(matching: .any)["folderTreeSearchClear"].firstMatch.tap()
    XCTAssertTrue(reveal(field, in: app), "The search field vanished after being cleared.")
    field.tap()
    field.typeText("wandern\n")

    // The filter really ran: the non-matching shoot is gone, the match survives, and the match's
    // ancestor is still there to show where it lives.
    XCTAssertTrue(
      app.descendants(matching: .any)["folderRow-1"].firstMatch.waitForNonExistence(timeout: 10),
      "A shoot whose name does not contain the search term stayed in the tree.")
    XCTAssertTrue(
      app.descendants(matching: .any)["folderRow-3"].firstMatch.waitForExistence(timeout: 10),
      "The matching shoot disappeared with everything else — the filter dropped its own hit.")
    XCTAssertTrue(
      app.descendants(matching: .any)["folderContainer-2"].firstMatch.exists,
      "The match's ancestor was pruned away, so the hit is shown with no context.")
    attach(named: "P7-tree-search-applied")

    // Selection still lands in the SAME grid contract, from a row two levels down.
    let target = app.descendants(matching: .any)["folderRow-3"].firstMatch
    XCTAssertTrue(reveal(target, in: app), "The nested shoot was not reachable to tap.")
    target.tap()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Tapping a nested folder-tree row never reached the grid — every row must enter the SAME "
        + "grid through GridStore.selectShoot(folderID:sourceTier:).")
    attach(named: "P7-grid-reached-from-a-nested-shoot")
  }

  /// IMGMGR-400 (owner device pass, TestFlight 0.12.0 (15)): "the folders only open when tapping
  /// on the chevron to expand the tree". A container row's NAME has to toggle it exactly as its
  /// chevron does — the web has always done this (`FolderTreeBranch.vue:95,:103` toggle a month
  /// on its label), and the shipped tree offered the toggle on the chevron Button ALONE, so a
  /// reader tapping the row name got nothing at all.
  ///
  /// Driven on the MONTH FOLD, which is the only row whose name toggles rather than navigates: a
  /// fold is no folder (`FolderTreeItemID`), so there is nothing to open a grid with. The year
  /// container above it is a real folder and its name now enters the grid, which is why the walk
  /// still reaches the fold through `folderDisclose-2`.
  func testTappingAMonthFoldsNameTogglesItExactlyAsItsChevronDoes() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"]
    app.launch()

    let localTier = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(reveal(localTier, in: app), "The Incoming tier branch never appeared.")
    localTier.tap()

    app.descendants(matching: .any)["folderDisclose-2"].firstMatch.tap()
    let month = app.descendants(matching: .any)["folderTreeMonth-2-2026-09"].firstMatch
    XCTAssertTrue(reveal(month, in: app), "The year container revealed no month fold to tap.")

    // The absence below is read against a surface that WAS found (LSN-0033): the fold is on
    // screen and closed, so "the shoot is not there" is the fold's state and not a tree that
    // never rendered.
    XCTAssertFalse(
      app.descendants(matching: .any)["folderRow-3"].firstMatch.exists,
      "The month fold started open — this leg cannot tell an opening tap from a no-op.")

    month.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["folderRow-3"].firstMatch.waitForExistence(timeout: 10),
      "Tapping the month fold's NAME did not open it (IMGMGR-400): the row toggles only from its "
        + "chevron Button, so a tap anywhere else on the row does nothing.")
    attach(named: "IMGMGR-400-month-name-tap-opens")

    month.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["folderRow-3"].firstMatch.waitForNonExistence(timeout: 10),
      "Tapping the open month fold's NAME did not close it — the name must drive the SAME toggle "
        + "the chevron drives, in both directions.")
    attach(named: "IMGMGR-400-month-name-tap-closes")
  }

  /// IMGMGR-405 (owner device pass, TestFlight 0.12.1 (16)): "click on the whole row to expand".
  /// A month row expanded ONLY from its chevron on the device — while the simulator's own tap on
  /// its label passed, because a tap sent to the label's centre is not the tap a thumb makes.
  ///
  /// So this drives the row's TRAILING edge, which no label covers: it is the part of the row
  /// that only rule 1 ("the whole row is one target") can answer. A build whose fold is tappable
  /// on its text alone fails here and nowhere else.
  ///
  /// Both directions, because a toggle that only opens is not a toggle; and the closed state is
  /// asserted first as the positive control (LSN-0033), so "the shoot is not there" is the fold's
  /// state rather than a tree that never rendered.
  func testAMonthFoldTogglesFromItsTrailingEdgeAndNotOnlyFromItsLabel() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"]
    app.launch()

    let localTier = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(reveal(localTier, in: app), "The Incoming tier branch never appeared.")
    localTier.tap()

    app.descendants(matching: .any)["folderDisclose-2"].firstMatch.tap()
    let month = app.descendants(matching: .any)["folderTreeMonth-2-2026-09"].firstMatch
    XCTAssertTrue(reveal(month, in: app), "The year container revealed no month fold to tap.")
    XCTAssertFalse(
      app.descendants(matching: .any)["folderRow-3"].firstMatch.exists,
      "The month fold started open — this leg cannot tell an opening tap from a no-op.")

    // The coordinate is derived from the row's own LIST CELL and not from the element that
    // carries the month identifier (round-2 finding 4): that element is a label on the shipped
    // build, so an offset inside it lands on the label and says nothing about how wide the target
    // is. The cell's frame is the row.
    let cell = rowCell(containing: "folderTreeMonth-2-2026-09", in: app)
    XCTAssertTrue(
      cell.waitForExistence(timeout: 10),
      "The month row's own list cell was never found, so the tap below could not be aimed at the "
        + "row — this leg cannot run without it.")

    trailingEdge(of: cell).tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["folderRow-3"].firstMatch.waitForExistence(timeout: 10),
      "A tap on the month row's TRAILING edge did not open it (IMGMGR-405): the row is not one "
        + "full-width target, so a thumb landing anywhere but the label does nothing.")
    attach(named: "IMGMGR-405-month-trailing-tap-opens")

    trailingEdge(of: cell).tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["folderRow-3"].firstMatch.waitForNonExistence(timeout: 10),
      "A second tap on the month row's trailing edge did not close it — the whole row drives the "
        + "SAME toggle the chevron drives, in both directions.")
    attach(named: "IMGMGR-405-month-trailing-tap-closes")
  }

  /// IMGMGR-405 rules 2 and 3 on a FOLDER row that has children: one tap opens its grid AND
  /// expands it, and the next tap on that same row — the one the reader is standing in, which the
  /// enclosing `List` still holds as its selection — collapses it without navigating anywhere.
  ///
  /// Driven on the year container (id 2), which is both a real folder and a parent; the fixture's
  /// month fold under it is the evidence that the first tap expanded. Nothing here is
  /// idiom-shaped: both branches of the second tap are chosen from an OBSERVED screen fact (did
  /// the tree stay beside the grid), never from the device — and the second branch is a real
  /// assertion of its own, not a skip. Rule 3's collapse is structurally unreachable where the
  /// split view collapses into a stack: coming back out of a folder's grid clears the selection,
  /// so the row is no longer the one the reader is standing in and the tap re-enters it. That is
  /// the round-2 finding-1 trade written down: the row's action and the List's own recognizer
  /// must produce ONE outcome on a tap, never a collapse and a push together.
  func testAYearRowOpensAndExpandsOnOneTapThenCollapsesWhereTheListHoldsIt() throws {
    let app = XCUIApplication()
    // `-UITestPerFolderGrid` (IMGMGR-405) makes the fixture's image ids carry the folder they
    // were loaded for, so `gridTile-2001…` IS the year folder's grid. Without it every folder
    // answers the same twelve tiles and "the grid did not change" is unreadable — the round-3
    // finding-2 correction. Opt-in: no other suite passes it, so nothing else moves.
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect", "-UITestPerFolderGrid"]
    app.launch()

    let localTier = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(reveal(localTier, in: app), "The Incoming tier branch never appeared.")
    localTier.tap()

    let container = app.descendants(matching: .any)["folderContainer-2"].firstMatch
    XCTAssertTrue(reveal(container, in: app), "The year container never appeared under Incoming.")
    let month = app.descendants(matching: .any)["folderTreeMonth-2-2026-09"].firstMatch
    XCTAssertFalse(
      month.exists,
      "The year container started open — this leg cannot tell an expanding tap from a no-op.")

    container.tap()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Tapping a folder row with children never reached the grid — rule 2 is that one tap both "
        + "enters the folder and opens it, never one or the other.")
    XCTAssertTrue(
      app.descendants(matching: .any)["gridTile-2001"].firstMatch.waitForExistence(timeout: 30),
      "The grid that opened is not the YEAR folder's (id 2): under -UITestPerFolderGrid its "
        + "tiles are gridTile-2001…2012, so this names the scope the tap actually entered.")
    // Did the tree stay BESIDE the grid? That is the enclosing `List` still holding its selection,
    // and it is the only state in which rule 3's collapse is reachable at all: a collapsed split
    // view is a stack, and coming back out of the grid clears the selection with it. Read off the
    // screen, never off the device idiom — the same question `returnToTheTree` asks.
    let treeStayedBesideTheGrid = container.exists && container.isHittable
    returnToTheTree(app, row: container)
    XCTAssertTrue(
      reveal(month, in: app),
      "The tap that opened the year's grid did not also expand it (IMGMGR-405 rule 2): the row "
        + "still expands only from its chevron.")
    attach(named: "IMGMGR-405-year-row-opens-and-expands")

    // The GRID's own identity, read as the set of tile identifiers on screen: under
    // `-UITestPerFolderGrid` every id names the folder it was loaded for, so this says WHICH
    // folder's grid is showing and not merely that one is (round-3 finding 2).
    let gridBefore = gridTileIdentifiers(in: app)

    container.tap()
    if treeStayedBesideTheGrid {
      XCTAssertTrue(
        month.waitForNonExistence(timeout: 10),
        "A second tap on the folder the reader is already standing in did not collapse it "
          + "(IMGMGR-405 rule 3).")
      XCTAssertTrue(
        app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch.exists,
        "The collapsing tap navigated instead — rule 3 leaves whatever is on the other side of "
          + "the split view exactly as it was.")
      XCTAssertFalse(
        gridBefore.isEmpty,
        "No grid tiles were on screen beside the tree, so the comparison below would hold "
          + "vacuously — this leg needs the year's grid to have been there.")
      XCTAssertTrue(
        gridBefore.allSatisfy { $0.hasPrefix("gridTile-2") },
        "The grid beside the tree was not the year folder's: \(gridBefore.sorted()).")
      XCTAssertEqual(
        gridTileIdentifiers(in: app), gridBefore,
        "The collapsing tap changed the grid — a different folder's tiles, or none: rule 3 "
          + "closes the branch and touches nothing else.")
    } else {
      // The documented consequence of deciding the tap against the LIST's selection rather than
      // against the highlight (round-2 finding 1): where the pop-back cleared the selection, the
      // row is painted but not selected, so the tap re-enters the folder — which is what the List
      // underneath is going to do on that same tap whatever this view decides — and leaves the
      // branch it opened open.
      XCTAssertTrue(
        app.descendants(matching: .any)["gridTile-2001"].firstMatch.waitForExistence(timeout: 30),
        "A tap on a painted-but-unselected folder did not re-enter ITS OWN grid — the row's own "
          + "action and the List's selection recognizer must agree on one outcome, never fire "
          + "two, and the scope they agree on is this folder's.")
      XCTAssertTrue(
        gridTileIdentifiers(in: app).allSatisfy { $0.hasPrefix("gridTile-2") },
        "Re-entering the folder loaded some other folder's photographs.")
      // Read after coming back, because the push takes the tree's rows off the hierarchy with it.
      returnToTheTree(app, row: container)
      XCTAssertTrue(
        reveal(month, in: app),
        "Re-entering the folder collapsed its branch as a side effect — only a tap the List "
          + "cannot act on (a same-value re-tap) may close a row.")
    }
    attach(named: "IMGMGR-405-year-row-second-tap")
  }

  /// IMGMGR-405 rule 5: the tree says which folder is open, and says it about exactly one row.
  /// The owner's report is that nothing does ("visualize which folder is selected"), and the
  /// enclosing `List`'s own selection rendering is what they are not seeing — so the trait is the
  /// tree's own, on the element that already carries the row's handle.
  func testTheOpenedFolderIsTheOnlyRowMarkedSelected() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestStubSkipAutoSelect"]
    app.launch()

    let localTier = app.descendants(matching: .any)["folderTreeTier-Incoming"].firstMatch
    XCTAssertTrue(reveal(localTier, in: app), "The Incoming tier branch never appeared.")
    localTier.tap()

    let shoot = app.descendants(matching: .any)["folderRow-1"].firstMatch
    XCTAssertTrue(reveal(shoot, in: app), "The fixture's root shoot row never appeared.")
    XCTAssertFalse(
      shoot.isSelected,
      "A row was already marked selected before anything was opened — the assertion below could "
        + "then pass without a tap.")

    shoot.tap()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30), "The shoot row never reached the grid.")
    returnToTheTree(app, row: shoot)

    XCTAssertTrue(
      reveal(shoot, in: app), "The tree did not come back after the shoot's grid was opened.")
    XCTAssertTrue(
      shoot.isSelected,
      "The opened folder's row carries no selected trait (IMGMGR-405 rule 5) — on the phone the "
        + "List's own selection is cleared by coming back out of the grid, which is why the tree "
        + "has to say this itself.")
    XCTAssertFalse(
      app.descendants(matching: .any)["folderContainer-2"].firstMatch.isSelected,
      "A second row is marked selected — the highlight must be exactly one row at a time.")
    attach(named: "IMGMGR-405-selected-row")
  }

  /// The trailing end of a row, in the ROW's own coordinates: `dx` 0.9 is past every label in this
  /// tree and still inside the row. A coordinate rather than another identifier on purpose — what
  /// is being asserted is that the ROW is the target, and an identifier on some inner text would
  /// prove only that the text is.
  private func trailingEdge(of element: XCUIElement) -> XCUICoordinate {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
  }

  /// Every grid tile identifier currently in the hierarchy. Under `-UITestPerFolderGrid` each one
  /// carries the folder its grid was loaded for (`gridTile-<folderID*1000 + n>`), so a SET of them
  /// is the grid's identity — which folder, and which photographs of it — rather than the bare
  /// "a grid is showing" a single element answers.
  private func gridTileIdentifiers(in app: XCUIApplication) -> Set<String> {
    let tiles = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "gridTile-"))
    // An explicit closure, never `map(\.identifier)`: under Swift 6 `XCUIElement.identifier` is
    // main-actor-isolated and a key-path literal into it does not compile
    // (`InspectorSlideOverUITests.swift:444` records the same for `label`).
    return Set(tiles.allElementsBoundByIndex.map { $0.identifier })
  }

  /// The list cell a row is drawn in — the element whose frame IS the row, whatever the row's
  /// content happens to be. `List` renders its rows as collection-view cells (the same collection
  /// view `reveal` scrolls), so this is where a "the whole row is the target" assertion has to
  /// aim.
  private func rowCell(containing identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.cells.containing(.any, identifier: identifier).firstMatch
  }

  /// Come back to the tree if opening a grid took it away. A COLLAPSED `NavigationSplitView` is a
  /// stack, so on Compact a folder's grid is pushed over the home while on Regular the sidebar
  /// stays put — this asks the screen which happened rather than asking the app what device it is
  /// on, and does nothing when the row is still there.
  private func returnToTheTree(_ app: XCUIApplication, row: XCUIElement) {
    if row.exists && row.isHittable { return }
    let back = app.navigationBars.buttons.firstMatch
    if back.exists && back.isHittable { back.tap() }
  }

  /// Scrolls the home list until `element` is on screen, in BOTH directions: the search field
  /// sits above the rows, so an up-only scan walks past what it is looking for and never comes
  /// back (observed in gate run 1cfa3f4).
  private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 8) -> Bool {
    if element.waitForExistence(timeout: 15), element.isHittable { return true }
    // SwiftUI's `List` is a collection view; the queue is the first one on both idioms. Falling
    // back to the app itself keeps the helper working if that ever stops being true.
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

  /// Screenshots are retained as XCTAttachments, which land in the run's `.xcresult` bundle under
  /// the gate's own DerivedData — the size suffix distinguishes the iPhone destination's capture
  /// from the iPad's without asking the app anything idiom-shaped.
  private func attach(named name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let size = screenshot.image.size
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(name)-\(Int(size.width))x\(Int(size.height))"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
