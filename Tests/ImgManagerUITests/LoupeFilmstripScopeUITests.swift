import XCTest

/// IMGMGR-406 (owner decision 2026-09-05, option (a), iPad and iPhone alike): in Scene mode the
/// loupe's filmstrip shows the OPEN SCENE's members and nothing else, and on a loose photograph
/// there is no strip at all.
///
/// The unit suite drives `LoupeView.body` through a SUBSTITUTED filmstrip surface, so it stays
/// green even if the shipped strip renders something else entirely. This class reads the running
/// app's own accessibility tree in the Scene-mode fixture, which is the only place the two halves
/// of the decision — "no strip" and "these five thumbnails" — are observable on the real thing.
///
/// Runs on both gate destinations deliberately: the decision is explicitly the same on iPhone and
/// iPad, so a layout that grew a strip of its own has to come through here.
final class LoupeFilmstripScopeUITests: OrientationPinnedUITestCase {

  /// The `-UITestEnterSceneMode` fixture (`DebugStubTransport`): loose photographs 1, 2, 8 and 9
  /// either side of scene 5000, whose band is the five named members 3…7 followed by the plain
  /// tail 601…635, with member 700 held back on a SECOND membership page.
  private let firstMemberID = 3
  private let bandTailMemberID = 635
  private let secondPageMemberID = 700

  func testTheStripIsTheOpenSceneAndIsAbsentOnALoosePhotograph() throws {
    let app = launchSceneFixture()
    expandTheFixtureScene(app)

    // Half 1 — a LOOSE photograph, with the scene already open behind it. The loupe opens on it
    // (a loose tile is the ONE tile a test may tap — see `openLoupe`) and carries no strip.
    openLoupe(app, onTile: "gridTile-1")
    let looseImage = element(app, "loupeImage")
    XCTAssertTrue(
      looseImage.waitForExistence(timeout: 10),
      "The loupe did not open on the loose photograph — the absence below would be vacuous.")
    attach(name: "scene-loupe-loose-no-strip")
    XCTAssertFalse(
      element(app, "loupeFilmstrip").exists,
      "A loose photograph in Scene mode still has a filmstrip — option (a) gives its height back "
        + "to the image.")
    XCTAssertEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'filmstripThumbnail-'"))
        .count, 0,
      "The strip is gone but its thumbnails are still in the tree.")

    // Half 2 — a MEMBER, reached by ADVANCING rather than by tapping a member's tile. Same app,
    // same launch, and the strip has to appear with the focus change (AC 5).
    let strip = advanceIntoTheBand(app)
    attach(name: "scene-loupe-member-band-only")

    let thumbnails = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'filmstripThumbnail-'"))
    if thumbnails.count < 2 {
      XCTContext.runActivity(named: "element tree with no filmstrip band") { activity in
        activity.add(XCTAttachment(string: app.debugDescription))
      }
    }
    // A COUNT is deliberately not the claim: the strip is a `LazyHStack`, so only the thumbnails
    // currently on screen are in the tree at all. WHICH photographs it draws is the claim, and
    // the fixture makes it discriminating — the loose photographs either side of the band are in
    // the grid behind this loupe, and none of them is in the strip.
    XCTAssertGreaterThanOrEqual(thumbnails.count, 2, "The strip drew no band at all.")
    XCTAssertTrue(strip.exists)
    for loose in [1, 2, 8, 9] {
      XCTAssertFalse(
        app.buttons["filmstripThumbnail-\(loose)"].exists,
        "Loose photograph \(loose) is in the strip — the scene's band is not what is shown.")
    }
    // Positive control for those absences: members of this scene ARE there under the same
    // identifier convention, so the assertions above are about which frames, not about a naming
    // scheme that changed underneath them.
    XCTAssertTrue(app.buttons["filmstripThumbnail-\(firstMemberID)"].exists)
    XCTAssertTrue(app.buttons["filmstripThumbnail-4"].exists)
  }

  /// IMGMGR-406 round 2: the paging trigger is the LOUPE's, on the focused photograph — the same
  /// code path whether or not a strip is drawn, which is why proving it here also covers the
  /// loose-photograph case where there is no strip to hang a trigger on.
  ///
  /// Why the band and not a loose tail: the grid pages from every cell it RENDERS
  /// (`GridView.page(from:)` on each cell's `.task`), so on any window whose tail is on screen the
  /// grid has already paged and a loupe probe would be vacuous. The fixture's band is longer than
  /// either destination's viewport, so the grid never renders — and never pages from — its last
  /// member, while the strip can be scrolled to that member inside the loupe. Deleting
  /// `LoupeView`'s `onChange` trigger makes this test fail: nothing else asks.
  ///
  /// What the negative half witnesses, precisely: no page-two THUMBNAIL IS MOUNTED — not "no
  /// request was made". A UI test cannot read a request count here: `DebugStubTransport` is an
  /// `actor` in the app process, and the one published counter surface (`DebugProbe`, drawn as
  /// `debugProbe`/`debugProbe.absorb` accessibility values in `GridView`) counts facets and
  /// absorb writes only. Mounting is nevertheless a faithful witness of the ASK, because member
  /// 700 exists nowhere but the second membership page: no other fixture row carries that id, so
  /// its thumbnail cannot appear unless that page was fetched.
  func testFocusingTheBandTailAsksForTheNextMembershipPage() throws {
    let app = launchSceneFixture()
    expandTheFixtureScene(app)
    // Reached the same way as the scope test: open on a LOOSE tile and advance into the band. A
    // member's own tile is not a tap target for a test — see `openLoupe`.
    openLoupe(app, onTile: "gridTile-1")
    let strip = advanceIntoTheBand(app)

    // The negative half, and the reason this test can fail: the second membership page has not
    // been asked for by anything yet — not by the grid (the band's tail is below the fold) and not
    // by opening the loupe (member 3 is not the band's last).
    let paged = app.buttons["filmstripThumbnail-\(secondPageMemberID)"]
    XCTAssertFalse(
      paged.exists,
      "Member \(secondPageMemberID) is on screen before anything asked for page two — the "
        + "fixture's second membership page is not being held back, so the assertion below "
        + "would prove nothing.")

    // Scroll the strip to the loaded tail and FOCUS it. That focus change is the trigger.
    let tail = app.buttons["filmstripThumbnail-\(bandTailMemberID)"]
    var swipes = 0
    while !(tail.exists && tail.isHittable), swipes < 30 {
      strip.swipeLeft()
      swipes += 1
    }
    if !(tail.exists && tail.isHittable) {
      XCTContext.runActivity(named: "element tree with the band tail unreachable") { activity in
        activity.add(XCTAttachment(string: app.debugDescription))
      }
    }
    XCTAssertTrue(
      tail.exists && tail.isHittable,
      "The strip never reached member \(bandTailMemberID) in \(swipes) swipes.")
    tail.tap()
    attach(name: "scene-loupe-band-tail-focused")

    XCTAssertTrue(
      paged.waitForExistence(timeout: 20),
      "Focusing the band's last loaded member did not bring the next membership page in — the "
        + "loupe's paging trigger is not wired (nothing else asks: the strip has no pager and the "
        + "grid never rendered this member).")
    attach(name: "scene-loupe-band-tail-paged")
  }

  // MARK: - Shared

  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func launchSceneFixture() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestEnterSceneMode"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared — expected the DEBUG fixture composition's "
        + "populated Scene-mode grid, got something else.")
    return app
  }

  /// Opens the fixture's scene, and waits for its band to be on screen.
  private func expandTheFixtureScene(_ app: XCUIApplication) {
    let handle = element(app, "sceneHandle-5000")
    XCTAssertTrue(handle.waitForExistence(timeout: 15), "The fixture scene's handle is missing.")
    handle.tap()
    XCTAssertTrue(
      element(app, "gridTile-\(firstMemberID)").waitForExistence(timeout: 20),
      "Opening the scene did not put its members on screen.")
  }

  /// Opens the loupe on a named tile, re-resolving the element for EVERY tap: one tile surfaces
  /// as several accessibility elements (`TileView`'s own note), and focusing it re-composes them,
  /// so an element bound before the first tap can be gone by the second.
  ///
  /// Only ever pointed at a LOOSE tile. The band's leading member carries the scene's close
  /// handle as an overlay (`GridView.bandHandle`), and the 2026-09-05 gate run failed exactly
  /// there: the first tap on `gridTile-3` left neither a loupe nor a `gridTile-3` in the tree.
  /// Members are reached by advancing instead — `advanceIntoTheBand`.
  private func openLoupe(_ app: XCUIApplication, onTile identifier: String) {
    XCTAssertTrue(
      element(app, identifier).waitForExistence(timeout: 20), "\(identifier) is not on screen.")
    let close = app.buttons["loupeClose"]
    // `GridStore.tapTile`: the SECOND tap on the focused tile opens; a first tap on an unfocused
    // tile only moves focus. Which of the two a tile needs depends on where focus already is.
    for _ in 0..<3 where !close.exists {
      let tile = element(app, identifier)
      guard tile.exists else { break }
      tile.tap()
      _ = close.waitForExistence(timeout: 3)
    }
    if !close.exists {
      XCTContext.runActivity(named: "element tree when \(identifier) never opened the loupe") {
        activity in
        activity.add(XCTAttachment(string: app.debugDescription))
      }
    }
    XCTAssertTrue(close.exists, "Tapping \(identifier) never opened the loupe.")
  }

  /// Walks the open loupe forward until the focused photograph is a member of the open scene, and
  /// returns the strip that appearing proves it. `loupeNext` is a named, stable control on the
  /// image, so this reaches a member without touching a tile at all — and the strip appearing on
  /// the way is itself IMGMGR-406's AC 5 (the scope follows the focus).
  private func advanceIntoTheBand(_ app: XCUIApplication) -> XCUIElement {
    let strip = element(app, "loupeFilmstrip")
    let next = app.buttons["loupeNext"]
    XCTAssertTrue(
      next.waitForExistence(timeout: 10),
      "The loupe has no forward control — a member cannot be reached without tapping a tile.")
    var advances = 0
    while !strip.exists, advances < 5 {
      XCTAssertTrue(
        next.isEnabled,
        "The loupe cannot advance any further and no band was reached (\(advances) advances).")
      next.tap()
      advances += 1
      _ = strip.waitForExistence(timeout: 4)
    }
    if !strip.exists {
      XCTContext.runActivity(named: "element tree with no strip after \(advances) advances") {
        activity in
        activity.add(XCTAttachment(string: app.debugDescription))
      }
    }
    XCTAssertTrue(
      strip.exists,
      "Advancing \(advances) frames from the loose photograph never reached the scene's band — "
        + "the fixture order is loose 1, loose 2, then the members of scene 5000.")
    return strip
  }

  private func attach(name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTContext.runActivity(named: "\(name) size \(screenshot.image.size)") { _ in }
  }
}
