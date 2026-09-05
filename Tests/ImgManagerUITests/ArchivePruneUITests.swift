import XCTest

/// IMGMGR-362 (WP21 P3) acceptance, on the real thing: the reader flips ONE switch and the fully
/// mirrored archive folder leaves the tree — and flipping it back brings the folder home.
///
/// The unit suite proves the transform and its composition (`FolderTreePruneMirroredTests`); this
/// proves the shipped wiring, which is the half that a correct transform nobody threaded would
/// leave inert: the preference is owned by `GridStore`, the tree is a different view in a
/// different column, and "the tree re-renders when the flag flips" is a fact about SwiftUI
/// observation that only a running app can answer.
///
/// Reachability (the plan's Compact check): the More menu lives on the GRID's action bar
/// (`GridView`), which the tree home does not show, so the SAME entry is rendered in the tree
/// home's own View menu — one preference key, two entry points, never a second mechanism. This
/// test drives the home's entry point, by the entry's own identifier, on both destinations.
///
/// Launch fixture: `-UITestStubGrid` + `-UITestStubSkipAutoSelect`, so the app stops at the tree
/// home. Its archive answer is the year container 20 over the real shoot 21 and the zero-count
/// mirrored folder 22 (`DebugStubTransport`, read-only here).
final class ArchivePruneUITests: OrientationPinnedUITestCase {

  private let mirroredRow = "folderRow-22"
  private let monthOfTheMirroredRow = "folderTreeMonth-20-2025-11"
  private let toggle = "gridMoreMenu.more.pruneMirroredArchive"

  func testHidingMirroredArchiveFoldersRemovesTheRowAndPuttingItBackRestoresIt() throws {
    let app = launch()

    // The mirrored folder is on screen BEFORE anything is flipped, which is what makes the
    // disappearance below readable against a surface that was found (LSN-0033). `launch()` pins
    // the preference OFF for this process, so this is a statement about the tree and not about
    // whatever the simulator happened to have on disk.
    if !revealMirroredRow(in: app) {
      // The one state this test cannot start from is "already pruned". Rather than fail — which
      // is what an interrupted earlier run would otherwise cause on the NEXT run — recover, and
      // SAY SO in the run log. Nothing is masked: the two legs below still have to pass, and the
      // shipped default is owned by `GridPreferencesTests.theArchivePruneIsOffByDefaultAndPersists`
      // rather than by this walk.
      XCTContext.runActivity(named: "recovered a leftover ON preference before the first leg") {
        _ in
      }
      flipTheToggle(in: app)
      XCTAssertTrue(
        revealMirroredRow(in: app),
        "The mirrored archive folder (\(mirroredRow)) is in the tree in NEITHER state — with the "
          + "prune off it must be there, so this is not a leftover preference.")
    }
    attach(named: "P3-archive-prune-off")

    flipTheToggle(in: app)

    XCTAssertTrue(
      app.descendants(matching: .any)[mirroredRow].firstMatch.waitForNonExistence(timeout: 15),
      "Hiding mirrored archive folders left \(mirroredRow) in the tree — either the transform "
        + "never ran or the preference never reached FolderTreeSection.")
    // The month row that folded ONLY the mirrored folder goes with it: the prune runs before the
    // fold, so no synthetic row is left standing over nothing.
    XCTAssertFalse(
      app.descendants(matching: .any)[monthOfTheMirroredRow].firstMatch.exists,
      "The mirrored folder's month row \(monthOfTheMirroredRow) is still on screen with nothing "
        + "under it — the prune must run BEFORE the month fold.")
    // Positive control for the two absences above: the archive branch is still open and still
    // rendering, so this is about the pruned rows and not about a collapsed or empty tree.
    XCTAssertTrue(
      app.descendants(matching: .any)["folderContainer-20"].firstMatch.exists,
      "Positive control failed: the archive year container disappeared too, so the assertions "
        + "above are about an empty tree rather than about the prune.")
    XCTAssertTrue(
      app.descendants(matching: .any)["folderTreeMonth-20-2025-12"].firstMatch.exists,
      "Positive control failed: the surviving shoot's month row is gone as well — the prune took "
        + "more than the mirrored folder.")
    attach(named: "P3-archive-prune-on")

    flipTheToggle(in: app)

    XCTAssertTrue(
      revealMirroredRow(in: app),
      "Turning the prune back OFF did not bring \(mirroredRow) back. The flag hides folders; it "
        + "must never be able to lose one.")
    attach(named: "P3-archive-prune-off-again")
  }

  // MARK: - The walk

  /// Opens the Archive tier, its year container and the mirrored folder's month fold, and answers
  /// whether the mirrored row is on screen. Idempotent: every step is skipped when its target is
  /// already open, so the same helper serves the first leg and the reappearance leg.
  private func revealMirroredRow(in app: XCUIApplication) -> Bool {
    let row = app.descendants(matching: .any)[mirroredRow].firstMatch
    if row.waitForExistence(timeout: 5) { return true }

    let archive = app.descendants(matching: .any)["folderTreeTier-Archive"].firstMatch
    XCTAssertTrue(reveal(archive, in: app), "The Archive tier row never appeared on the home.")
    if !app.descendants(matching: .any)["folderContainer-20"].firstMatch.exists {
      archive.tap()
    }

    let container = app.descendants(matching: .any)["folderContainer-20"].firstMatch
    XCTAssertTrue(reveal(container, in: app), "The archive year container never appeared.")
    if !app.descendants(matching: .any)[monthOfTheMirroredRow].firstMatch.exists {
      app.descendants(matching: .any)["folderDisclose-20"].firstMatch.tap()
    }

    let month = app.descendants(matching: .any)[monthOfTheMirroredRow].firstMatch
    guard reveal(month, in: app) else { return false }
    if !row.exists {
      app.descendants(matching: .any)["folderDisclose-20-2025-11"].firstMatch.tap()
    }
    return reveal(app.descendants(matching: .any)[mirroredRow].firstMatch, in: app)
  }

  /// Opens the tree home's View menu and taps the prune row BY THE ENTRY'S OWN IDENTIFIER — the
  /// same `GridMoreMenuEntry` the grid's More menu renders, so this drives the shipped entry
  /// rather than a control written for the test.
  private func flipTheToggle(in app: XCUIApplication) {
    let menu = app.descendants(matching: .any)["folderTreeViewMenu"].firstMatch
    XCTAssertTrue(
      menu.waitForExistence(timeout: 10),
      "The tree home exposes no View menu, so the prune has no entry point on the surface that "
        + "renders the tree (the plan's Compact reachability check).")
    menu.tap()

    let entry = app.descendants(matching: .any)[toggle].firstMatch
    XCTAssertTrue(
      entry.waitForExistence(timeout: 10),
      "The tree home's View menu does not render '\(toggle)'.")
    // EXACTLY one, counted rather than `firstMatch`-ed: the entry is declared once and rendered
    // in two places (this menu and the grid's More menu), so "two rows answering to one
    // identifier are on screen together" is the failure this assertion exists to catch — on the
    // iPad above all, where the sidebar and the grid are both mounted.
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: toggle).count, 1,
      "More than one element answers to '\(toggle)' while the tree home's View menu is open — "
        + "the grid's More row and this one must never be presented at the same time.")
    entry.tap()
  }

  /// The preference this test drives is PERSISTED (`grid.pruneMirroredArchive`), and the
  /// simulator keeps it across runs — so an interrupted earlier run could otherwise decide what
  /// the next one sees. The pair below pins it OFF for this launch through `UserDefaults`'
  /// own `NSArgumentDomain`, which outranks the app's stored value on every read: no app change,
  /// no test-only code path in the shipped target, and `DebugStubTransport`'s launch-flag
  /// vocabulary (which this phase must not edit) is left alone.
  ///
  /// It is FIRST in the list on purpose: the argument domain reads `-key value` pairs in order,
  /// so the key must not be sitting where another flag's value is expected.
  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-grid.pruneMirroredArchive", "<false/>",
      "-UITestStubGrid", "-UITestStubSkipAutoSelect",
    ]
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
