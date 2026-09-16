import Foundation
import XCTest

/// How this target opens a popover or a menu (IMGMGR-404).
///
/// **WHY a helper and not one more `tap()`.** Two iPad gate legs went red on 2026-09-05 against
/// Sources that were identical to a green run: `SortGroupScreenshotUITests` tapped
/// `gridSortControl` and no menu row ever appeared (the control's label stayed "Sort: Date ↑"),
/// and `FilterPopoverUITests` tapped `gridFilterControl` and waited out its 10 s without
/// `filterPopoverRow-rating-4` existing. The iPhone destination was green in both runs and no
/// crash signature was present; merkur was carrying two other lanes (load average 200–700) each
/// time. A tap that the presentation machinery drops under that load is not something a longer
/// wait recovers — the presentation never started — so every opener in this target now goes
/// through ONE place that can tell the two failure shapes apart and re-tap exactly once.
///
/// **What it deliberately does NOT do (AC 4 of the ticket).** It never retries a test, a leg or
/// an assertion, it never loops beyond the single re-tap, and it decides nothing: it reports
/// whether the expected element arrived and the CALLER's own `XCTAssert` — with the CALLER's own
/// message — is still what turns a miss into a red. A helper that swallowed the miss would hide
/// exactly the regression these tests exist to catch.
///
/// **The budget is the caller's existing timeout, not a new one.** The whole open — settle, tap,
/// wait, re-tap, wait — is bounded by the `timeout` the call site already spent on its
/// `waitForExistence`, measured against one deadline, so converting a test cannot make a red run
/// slower than it was.
extension XCTestCase {

  /// Taps `control` and answers whether `expected` — the FIRST element the presentation is
  /// supposed to put on screen — arrived within `timeout`, re-tapping once if the tap was lost.
  ///
  /// The result is deliberately not `@discardableResult`: a call site that ignored it would be
  /// asserting nothing, so the compiler is what keeps the caller's assertion in the loop.
  ///
  /// - Parameters:
  ///   - control: the opener (a funnel, a Sort/Group control, a More or View menu).
  ///   - expected: the first row/element the open presentation must render.
  ///   - timeout: the TOTAL budget for the whole open, shared by both waits.
  /// - Returns: `true` when `expected` exists before the deadline.
  func openPresentation(
    _ control: XCUIElement,
    revealing expected: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)

    // Idle, as far as XCUITest lets a test observe it: a control the app has laid out but cannot
    // yet hit is a control whose tap would be delivered to whatever is still on top of it. This
    // is the wait the flaky runs never did; it costs nothing when the control is already settled.
    if !control.isHittable {
      let hittable = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "isHittable == true"), object: control)
      _ = XCTWaiter().wait(for: [hittable], timeout: Self.remaining(until: deadline))
    }

    control.tap()

    // Half of what is left of the budget for the presentation to arrive on its own.
    if expected.waitForExistence(timeout: Self.remaining(until: deadline) / 2) { return true }

    // ONE re-tap, and only from the state that actually means "the tap was lost": the opener is
    // still hittable, so nothing is presented over it, and the expected element is still absent.
    // A presentation that is merely SLOW puts its own blocking overlay between the test and the
    // opener, which makes the opener unhittable — so this guard leaves that case alone and spends
    // the rest of the budget waiting, rather than tapping a presented menu closed again.
    guard control.exists, control.isHittable, !expected.exists else {
      return expected.waitForExistence(timeout: Self.remaining(until: deadline))
    }
    control.tap()

    return expected.waitForExistence(timeout: Self.remaining(until: deadline))
  }

  /// The grid's More menu, opened the same way — the ONE definition of an opener two test classes
  /// had each written for themselves (`GridMoreMenuUITests` and `SceneAbsorbUITests` carried
  /// identical private `openMoreMenu` helpers, and identical is how they both stayed un-retried).
  /// The existence assertion is the one those two already made, message included.
  ///
  /// - Returns: `true` when `expected` is on screen; the caller still asserts it.
  func openMoreMenu(
    in app: XCUIApplication,
    revealing expected: XCUIElement,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Bool {
    let more = app.descendants(matching: .any)["gridMoreMenu"]
    XCTAssertTrue(
      more.waitForExistence(timeout: 10),
      "Nothing named 'gridMoreMenu' is on the action bar.", file: file, line: line)
    return openPresentation(more, revealing: expected, timeout: timeout)
  }

  /// What is left of a budget, never negative — `waitForExistence` treats a negative timeout as
  /// an error rather than as "already out of time".
  private static func remaining(until deadline: Date) -> TimeInterval {
    max(0, deadline.timeIntervalSinceNow)
  }
}
