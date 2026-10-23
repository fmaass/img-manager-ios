import Foundation
import UIKit
import XCTest

/// IMGMGR-542 (R3-22), the plan's measurement step: long frames (over 25 ms, at least one missed
/// 60 Hz frame) while the grid scrolls with 0, 1 and 3 peek bands open, all in one launch. The
/// formula (the 3-band count at most the 0-band count plus three times the 1-band delta, clamped
/// at 0) is computed and printed as `pass=`, but only recorded (`verdict=record-only`).
///
/// Fixture (`-UITestPeekBandsMeasure`, `DebugPeekBandsFixture`): a STAND-IN, not the real
/// largest folder — 240 scenes 80001…80240 between 240 loose photographs, three browse pages of
/// 160 rows; scenes 80001…80003 hold 60 members each, every other scene 8. The real folder's
/// stack count is not known to this lane and is not claimed. `-UITestFrameMonitor` counts long
/// frames only inside a scroll window (`GridFrameMonitor`), published as `debugProbe.frames`
/// (`longFrames=<n>;windows=<n>;loading=idle|busy;bands=<ids>`).
///
/// Simulator frames are rendered by the Mac's GPU under gate load: the result is a same-run
/// RELATIVE check, not a device frame-time claim. This test never skips.
///
/// Record-only: under full-gate load the spread between repetitions (68…111 long frames in one
/// iPad run) exceeds the band effect, so the simulator cannot decide the formula. The
/// decisive run is the owner's device run on the real folder (IMGMGR-638); this test records the
/// stand-in numbers. It still fails when a swipe does not move or opens no measured window, when
/// a phase measures no window, or when the line and its attachment are not produced.
final class PeekBandScrollMetricsUITests: OrientationPinnedUITestCase {

  private static let fixture = "fixture=stand-in stacks=240 opened=60,60,60"
  private static let swipesPerRepetition = 8
  private static let repetitions = 1
  private static let firstScenes = [80001, 80002, 80003]

  private struct Frames {
    let longFrames: Int
    let windows: Int
    let idle: Bool
  }

  func testLongFramesWithZeroOneAndThreeBands() throws {
    let app = launched()
    let grid = try XCTUnwrap(gridFrame(app), "No scroll view holds the first scene's chevron.")
    let top = streamAnchor(app)
    XCTAssertNotEqual(top, "none", "The stream recorded no top row at launch.")

    let zero = measurePhase(app, grid: grid, top: top, phase: "zero")

    open(app, Self.firstScenes[0], grid: grid, top: top)
    waitForBands(app, "80001")
    let one = measurePhase(app, grid: grid, top: top, phase: "one")

    open(app, Self.firstScenes[1], grid: grid, top: top)
    open(app, Self.firstScenes[2], grid: grid, top: top)
    waitForBands(app, "80001,80002,80003")
    let three = measurePhase(app, grid: grid, top: top, phase: "three")

    // One repetition per phase: the median of one value is that value; the reps fields stay so
    // the line format is stable.
    let a = median(zero)
    let b = median(one)
    let c = median(three)
    // Clamped at zero: a negative 1-band delta is noise and must not make the limit tighter
    // than the 0-band count.
    let limit = a + 3 * max(0, b - a)
    let line =
      "PEEKBAND-MEASURE \(Self.fixture) budgetMs=25 dest=\(destination(app)) zero=\(a) one=\(b) "
      + "three=\(c) "
      + "reps0=\(list(zero)) reps1=\(list(one)) reps3=\(list(three)) limit=\(limit) "
      + "pass=\(c <= limit) verdict=record-only"
    print(line)
    let attachment = XCTAttachment(string: line)
    attachment.name = "peekband-measure.txt"
    attachment.lifetime = .keepAlways
    add(attachment)
    // Not asserted: the simulator noise floor under gate load exceeds the band effect, so the
    // decisive run is the owner's device run on the real folder (IMGMGR-638).
  }

  // MARK: - One phase

  /// Warm-up (one untimed pass to the measured depth and back), then `repetitions` runs of
  /// `swipesPerRepetition` fixed swipes from the top. Each swipe must move the stream anchor and
  /// open at least one measured window; a swipe that does neither fails the test rather than
  /// counting as a low number. The phase as a whole must have measured at least one window.
  private func measurePhase(
    _ app: XCUIApplication, grid: CGRect, top: String, phase: String
  ) -> [Int] {
    waitIdle(app, phase)
    for _ in 0..<Self.swipesPerRepetition { swipe(app, grid: grid) }
    returnToTop(app, top: top)
    waitIdle(app, phase)

    var counts: [Int] = []
    for repetition in 0..<Self.repetitions {
      returnToTop(app, top: top)
      waitIdle(app, phase)
      let start = frames(app)
      var anchor = streamAnchor(app)
      for index in 0..<Self.swipesPerRepetition {
        let before = frames(app)
        swipe(app, grid: grid)
        let after = frames(app)
        let moved = streamAnchor(app)
        let label = "\(phase) rep \(repetition) swipe \(index)"
        XCTAssertNotEqual(moved, anchor, "\(label): the anchor did not advance (end reached?).")
        XCTAssertGreaterThanOrEqual(
          after.windows, before.windows + 1, "\(label): the swipe opened no measured window.")
        anchor = moved
      }
      let end = frames(app)
      XCTAssertGreaterThanOrEqual(
        end.windows, start.windows + 1, "\(phase) rep \(repetition): no measured window.")
      counts.append(end.longFrames - start.longFrames)
    }
    XCTAssertFalse(counts.isEmpty, "\(phase): the phase measured nothing.")
    return counts
  }

  // MARK: - Gestures

  /// One fixed-distance, fixed-velocity drag up the middle of the grid, then the settle time a
  /// fling needs to come to rest (the measured window closes on idle).
  private func swipe(_ app: XCUIApplication, grid: CGRect) {
    let origin = app.coordinate(withNormalizedOffset: .zero)
    let from = origin.withOffset(CGVector(dx: grid.midX, dy: grid.minY + grid.height * 0.75))
    let to = origin.withOffset(CGVector(dx: grid.midX, dy: grid.minY + grid.height * 0.35))
    from.press(
      forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(1200),
      thenHoldForDuration: 0)
    Thread.sleep(forTimeInterval: 1.5)
  }

  private func returnToTop(_ app: XCUIApplication, top: String) {
    for _ in 0..<40 where streamAnchor(app) != top {
      app.swipeDown(velocity: .fast)
      Thread.sleep(forTimeInterval: 0.8)
    }
    XCTAssertEqual(streamAnchor(app), top, "Could not scroll back to the top of the stream.")
    // The anchor names the top row while it is still partly under the bar: one more fling
    // settles the content at its very top (a fling at the top only bounces).
    app.swipeDown(velocity: .fast)
    Thread.sleep(forTimeInterval: 0.8)
  }

  /// Opens a band at its chevron (from the top, scrolling down to it if needed), then goes back
  /// to the top.
  private func open(_ app: XCUIApplication, _ stackID: Int, grid: CGRect, top: String) {
    let chevron = app.descendants(matching: .any)["sceneHandle-\(stackID)"].firstMatch
    // A measured phase ends where its last swipe left the stream, deep below the first scenes:
    // the search starts from the top, where 80001 is drawn and 80002/80003 lie below.
    returnToTop(app, top: top)
    // A lazy grid realises the rows of a viewport it has just come back to on its own schedule:
    // give the top a moment, and settle it once more, before searching by swiping.
    if !chevron.waitForExistence(timeout: 5) {
      dumpTree(app, "open \(stackID): absent at the top")
      app.swipeDown(velocity: .slow)
      _ = chevron.waitForExistence(timeout: 5)
    }
    for _ in 0..<30 where !(chevron.exists && chevron.isHittable) {
      // Toward the chevron: down when it is drawn above the middle (under the bar), else up.
      if chevron.exists && chevron.frame.midY < grid.midY {
        app.swipeDown(velocity: .slow)
      } else {
        app.swipeUp(velocity: .slow)
      }
      Thread.sleep(forTimeInterval: 0.6)
    }
    if !chevron.isHittable { dumpTree(app, "open \(stackID): not reachable") }
    XCTAssertTrue(chevron.isHittable, "Chevron \(stackID) is not reachable.")
    chevron.tap()
    let open = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "open"), object: chevron)
    XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 15), .completed, "\(stackID) not open.")
    returnToTop(app, top: top)
  }

  /// Failure evidence for the log, read by grep: the probes, then every identified element of
  /// the snapshot whose identifier names a scene, a tile or a scroll view, one line each.
  private func dumpTree(_ app: XCUIApplication, _ reason: String) {
    print(
      "PEEKBAND-DIAG \(reason) scroll='\(probe(app, "debugProbe.scroll"))' "
        + "frames='\(probe(app, "debugProbe.frames"))' scrollViews=\(app.scrollViews.count)")
    let lines = app.debugDescription.split(separator: "\n")
    let kept = lines.filter {
      $0.contains("sceneHandle") || $0.contains("gridTile-") || $0.contains("peekBandRow")
        || $0.contains("ScrollView") || $0.contains("sceneCard")
    }
    for line in kept.prefix(60) { print("PEEKBAND-TREE \(line)") }
    print("PEEKBAND-TREE total=\(lines.count) kept=\(kept.count)")
    let attachment = XCTAttachment(string: app.debugDescription)
    attachment.name = "peekband-tree-\(reason).txt"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  // MARK: - Probes

  private func launched() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-UITestStubGrid", "-UITestEnterSceneMode", "-UITestPeekBandsMeasure", "-UITestFrameMonitor",
    ]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "Action bar (Dislike button) never appeared within 30s.")
    XCTAssertTrue(
      app.descendants(matching: .any)["sceneHandle-80001"].firstMatch.waitForExistence(
        timeout: 20),
      "The stand-in folder never showed scene 80001.")
    return app
  }

  private func gridFrame(_ app: XCUIApplication) -> CGRect? {
    let view = app.scrollViews.containing(.any, identifier: "sceneHandle-80001").firstMatch
    return view.exists ? view.frame : nil
  }

  private func probe(_ app: XCUIApplication, _ identifier: String) -> String {
    (app.descendants(matching: .any)[identifier].firstMatch.value as? String) ?? "<absent>"
  }

  private func frames(_ app: XCUIApplication) -> Frames {
    var fields: [String: String] = [:]
    for pair in probe(app, "debugProbe.frames").split(separator: ";") {
      let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
      if parts.count == 2 { fields[parts[0]] = parts[1] }
    }
    return Frames(
      longFrames: Int(fields["longFrames"] ?? "") ?? -1,
      windows: Int(fields["windows"] ?? "") ?? -1,
      idle: fields["loading"] == "idle")
  }

  private func streamAnchor(_ app: XCUIApplication) -> String {
    let value = probe(app, "debugProbe.scroll")
    return value.components(separatedBy: ";").first?.replacingOccurrences(
      of: "streamAnchor=", with: "") ?? "none"
  }

  /// No browse page and no membership page in flight, every open band fully loaded.
  private func waitIdle(_ app: XCUIApplication, _ phase: String) {
    let element = app.descendants(matching: .any)["debugProbe.frames"].firstMatch
    let idle = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value CONTAINS %@", "loading=idle"), object: element)
    XCTAssertEqual(
      XCTWaiter().wait(for: [idle], timeout: 30), .completed,
      "\(phase): reads never settled ('\(probe(app, "debugProbe.frames"))').")
  }

  private func waitForBands(_ app: XCUIApplication, _ ids: String) {
    let element = app.descendants(matching: .any)["debugProbe.frames"].firstMatch
    let open = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value ENDSWITH %@", "bands=\(ids)"), object: element)
    XCTAssertEqual(
      XCTWaiter().wait(for: [open], timeout: 15), .completed,
      "Open bands read '\(probe(app, "debugProbe.frames"))', expected bands=\(ids).")
  }

  private func destination(_ app: XCUIApplication) -> String {
    let size = app.frame.size
    return "\(UIDevice.current.model)-\(Int(size.width))x\(Int(size.height))"
  }

  private func median(_ values: [Int]) -> Int {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
  }

  private func list(_ values: [Int]) -> String {
    values.map(String.init).joined(separator: ",")
  }
}
