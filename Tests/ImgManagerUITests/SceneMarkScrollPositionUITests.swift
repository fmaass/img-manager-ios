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
final class SceneMarkScrollPositionUITests: OrientationPinnedUITestCase {

  func testMarkingAMemberOfAnOpenSceneLeavesTheGridWhereItWas() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestEnterSceneMode"]
    app.launch()

    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else.")

    let handle = app.descendants(matching: .any)["sceneHandle-5000"].firstMatch
    XCTAssertTrue(
      handle.waitForExistence(timeout: 20),
      "No handle for the fixture scene — the fixture never entered Scene mode with data.")
    handle.tap()
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
    attach(named: "IMGMGR-473-before-mark")

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
    print(
      "IMGMGR473-SCROLL window=\(app.frame.size) target=\(targetID) "
        + "before=\(targetBefore) after=\(targetAfter) "
        + "neighbourBefore=\(String(describing: neighbourBefore)) "
        + "neighbourAfter=\(neighbour.exists ? neighbour.frame.minY : -1)")
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

  private func attach(named name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
