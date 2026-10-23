import XCTest

/// IMGMGR-473 (owner report, iPad): "I group by scene and open a group; when I tap a picture to
/// mark it, the pane scrolls and the screen jumps."
///
/// Read back on the real surface: the on-screen frame of the marked photograph (and of a second
/// member beside it) before and after one mark, taken with the grid scrolled INTO the open band so
/// the top row is cut mid-height — the position a reader culling a long scene is actually in. A
/// mark that moved the content offset moves both frames.
///
/// The mark goes through the action bar's Pick button on the focused member, which reaches the
/// same `performMark` the latched tap does: the optimistic apply (state + the scene's ✓N count)
/// before the network await, then `refreshScenesFor`'s merge of the re-read row after it. The
/// member is a plain tail member (601…), so the pick crosses the pick boundary and BOTH halves
/// run. The Undo button turning enabled is the evidence the write committed, so a mark that never
/// happened cannot pass as "nothing moved".
///
/// Round 2 (gate on ea18cf7): RED at 402x874 (+43.33 pt, exactly the cut-off part of the top
/// row: the bound `.scrollPosition(id:)` re-snapped that row's top to the viewport), green at
/// 1032x1376 only because that drag happened to end row-aligned, where a top-snap moves nothing.
/// So the top row being CUT is now a stated precondition, nudged into place when a drag ends
/// aligned, and the viewport's own frame is printed before and after, so chrome that grows above
/// the grid is told apart from the content offset moving inside it.
final class SceneMarkScrollPositionUITests: OrientationPinnedUITestCase {

  @MainActor
  func testMarkingAMemberOfAnOpenSceneLeavesTheGridWhereItWas() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestEnterSceneMode"]
    app.launch()

    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else.")

    pushScene(app, 5000, timeout: 20)
    let lead = app.descendants(matching: .any)["gridTile-3"].firstMatch
    XCTAssertTrue(
      lead.waitForExistence(timeout: 15), "Opening the scene did not put its members on screen.")

    let grid = app.scrollViews.containing(.any, identifier: "gridTile-3").firstMatch
    XCTAssertTrue(grid.waitForExistence(timeout: 10), "No scrollable grid holds the open band.")

    // Into the band by a PARTIAL drag (no fling), so the offset is not row-aligned.
    let leadYBeforeDrag = lead.frame.minY
    let from = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
    let to = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
    from.press(forDuration: 0.1, thenDragTo: to)
    Thread.sleep(forTimeInterval: 1.5)
    XCTAssertLessThan(
      lead.frame.minY, leadYBeforeDrag - 20,
      "The grid did not scroll, so an unmoved frame below would prove nothing.")

    // A top-snap is only visible when the top edge cuts a row: nudge until it does.
    var cut = tileCutByTopEdge(of: grid.frame, in: grid)
    var nudges = 0
    while cut == nil, nudges < 3 {
      nudges += 1
      let nudgeFrom = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
      let nudgeTo = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
      nudgeFrom.press(forDuration: 0.1, thenDragTo: nudgeTo)
      Thread.sleep(forTimeInterval: 1.0)
      cut = tileCutByTopEdge(of: grid.frame, in: grid)
    }
    guard cut != nil else {
      attach(named: "IMGMGR-473-no-cut-row")
      XCTFail("After \(nudges) nudges no tile is cut by the grid's top edge (\(grid.frame)).")
      return
    }

    let gridFrame = grid.frame
    guard let found = firstMemberFullyInside(gridFrame, app: app) else {
      attach(named: "IMGMGR-473-no-target")
      XCTFail("No plain band member lies fully inside the grid viewport after the drag.")
      return
    }
    let (targetID, target) = found
    let neighbour = app.descendants(matching: .any)["gridTile-\(targetID + 1)"].firstMatch

    // Browse mode: the first tap FOCUSES (no write). Settle, then read the "before" frames, so
    // anything the focus change itself does is not charged to the mark.
    target.tap()
    Thread.sleep(forTimeInterval: 1.0)
    let undo = app.buttons["gridUndoButton"]
    XCTAssertTrue(undo.exists, "No Undo control — the commit evidence below would be missing.")
    XCTAssertFalse(undo.isEnabled, "Undo is already enabled before the mark — no clean baseline.")
    let targetBefore = target.frame.minY
    let neighbourBefore = neighbour.exists ? neighbour.frame.minY : nil
    let viewportBefore = grid.frame
    let cutBefore = tileCutByTopEdge(of: viewportBefore, in: grid)
    attach(named: "IMGMGR-473-before-mark")
    XCTAssertNotNil(
      cutBefore,
      "Focusing the target left no row cut by the top edge — a top-snap would be invisible.")

    app.buttons["gridPickButton"].tap()
    let committed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: undo)
    XCTAssertEqual(
      XCTWaiter().wait(for: [committed], timeout: 10), .completed,
      "Undo never became available — the mark did not commit, so no frame reading below means "
        + "anything.")
    // `refreshScenesFor` re-reads the scene row AFTER the commit that enabled Undo.
    Thread.sleep(forTimeInterval: 2.0)
    attach(named: "IMGMGR-473-after-mark")

    let targetAfter = target.frame.minY
    let viewportAfter = grid.frame
    print(
      "IMGMGR473-SCROLL window=\(app.frame.size) target=\(targetID) "
        + "before=\(targetBefore) after=\(targetAfter) "
        + "neighbourBefore=\(String(describing: neighbourBefore)) "
        + "neighbourAfter=\(neighbour.exists ? neighbour.frame.minY : -1) "
        + "nudges=\(nudges) cutBefore=\(String(describing: cutBefore)) "
        + "cutAfter=\(String(describing: tileCutByTopEdge(of: viewportAfter, in: grid))) "
        + "viewportBefore=\(viewportBefore) viewportAfter=\(viewportAfter) "
        + "navBar=\(app.navigationBars.firstMatch.frame)")
    XCTAssertEqual(
      targetAfter, targetBefore, accuracy: 1.0,
      "Marking a member of an open scene moved the grid: the marked photograph's frame went from "
        + "y=\(targetBefore) to y=\(targetAfter).")
    if let neighbourBefore, neighbour.exists {
      XCTAssertEqual(
        neighbour.frame.minY, neighbourBefore, accuracy: 1.0,
        "Marking a member of an open scene moved its neighbour's frame.")
    }
  }

  /// The first plain tail member (601…635, no verdict, no handle overlay) whose whole frame lies
  /// inside the grid viewport with a margin, so the tap cannot land on chrome and a jump in
  /// either direction stays measurable.
  private func firstMemberFullyInside(_ viewport: CGRect, app: XCUIApplication)
    -> (Int, XCUIElement)?
  {
    for id in 601...635 {
      let tile = app.descendants(matching: .any)["gridTile-\(id)"].firstMatch
      guard tile.exists else { continue }
      let frame = tile.frame
      if frame.minY > viewport.minY + 40, frame.maxY < viewport.maxY - 40, tile.isHittable {
        return (id, tile)
      }
    }
    return nil
  }

  /// The tile the grid's top edge cuts through, and how many points of it lie above that edge —
  /// nil when the top row sits flush. One snapshot of the grid, walked by hand (no key paths to
  /// an element's properties: Swift 6 strict concurrency).
  @MainActor
  private func tileCutByTopEdge(of viewport: CGRect, in grid: XCUIElement) -> (String, CGFloat)? {
    let root: any XCUIElementSnapshot
    do {
      root = try grid.snapshot()
    } catch {
      XCTFail("Could not snapshot the grid to find the cut row: \(error)")
      return nil
    }
    var pending: [any XCUIElementSnapshot] = [root]
    while let node = pending.popLast() {
      let frame = node.frame
      if node.identifier.hasPrefix("gridTile-"), frame.minY < viewport.minY - 2,
        frame.maxY > viewport.minY + 2
      {
        return (node.identifier, viewport.minY - frame.minY)
      }
      pending.append(contentsOf: node.children)
    }
    return nil
  }

  private func attach(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
