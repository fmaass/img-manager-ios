import UIKit
import XCTest

/// WP16 P2 (IMGMGR-298), the half of decision 4 that is not about a panel: **the facet counts
/// survive the inspector being gone.**
///
/// At `4753450` the ONLY trigger for `GridStore.refreshFacets()` was
/// `InspectorView`'s `.task(id: store.queryIdentity)`, so on a screen with no inspector the
/// counts were never fetched at all. Decision 4 removes the one width where that view was always
/// present, and the phase moves the trigger onto `RootView.workspace` through an injectable
/// `FacetsRefreshInstaller`. This test is the observation of that move ON THE REAL SURFACE.
///
/// **Why it does not simply show the inspector and read a count.** Against the shipped app the
/// act of showing `InspectorView` STARTS the refresh, so any post-show reading observes a fetch
/// the show itself began — it cannot tell the two builds apart. The observation is therefore
/// taken while the inspector has never been on screen, through a DEBUG-only counter the fixture
/// transport increments (`DebugProbe`, `#if DEBUG`) and `GridView` publishes as an accessibility
/// value. Reading an `@Observable` property inside a view body registers the dependency, so the
/// value re-renders when the counter moves; nothing here polls.
///
/// **Against `4753450` this is RED twice over**, and no timing window can make it otherwise:
/// there is no `debugProbe` element in that build at all, so the predicate never matches and the
/// waiter times out; and at Regular-3 the inspector is a permanent column, so the
/// `statsSegment.exists == false` precondition fails as well.
///
/// Makes no device-idiom decision. After the move the trigger is layout-independent, so the same
/// contract is asserted on both gate destinations: the iPhone leg observes it with the inspector
/// behind its sheet, the iPad leg with the Regular-3 inspector collapsed — which since IMGMGR-390
/// is the launch state itself, so no launch argument is needed to reach it. WP28 P3 (IMGMGR-450):
/// the inspector is the system `.inspector` at every width; this contract is unchanged by it.
final class FacetsWithoutInspectorUITests: OrientationPinnedUITestCase {

  /// LANDSCAPE: it is what puts the iPad destination at Regular-3, the width decision 4 changes;
  /// the iPhone destination is Compact in either orientation.
  override class var pinnedOrientation: UIDeviceOrientation { .landscapeLeft }

  func testTheFacetsFetchRunsWhileTheInspectorIsNeverOnScreen() {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    let dislike = app.buttons["Dislike"]
    XCTAssertTrue(
      dislike.waitForExistence(timeout: 30),
      "Action bar (Dislike) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else (sign-in, blank, or a failed stub).")

    // The rotation's own layout pass, then the resolver's `.onGeometryChange` reaction to it —
    // the same settle this target's sibling waits out before reading geometry-dependent state.
    Thread.sleep(forTimeInterval: 2.0)

    let statsSegment = app.buttons["Stats"]
    let probe = app.descendants(matching: .any)["debugProbe"]

    // The precondition, asserted BEFORE the wait: nothing inspector-shaped is on screen, so the
    // fetch this test is about to observe cannot have been started by the inspector.
    XCTAssertFalse(
      statsSegment.exists,
      "The inspector is on screen at launch, so a facets fetch observed below would prove "
        + "nothing — `RootView.showInspector` no longer defaults to collapsed (IMGMGR-390), or "
        + "this build presents the inspector unconditionally.")
    // Positive control for that 0-hit reading: the app really is up and its hierarchy really is
    // being searched, so "no Stats segment" cannot pass vacuously on a blank screen.
    XCTAssertTrue(
      dislike.exists,
      "Positive control failed: the action bar is gone, so the absence check above is vacuous.")

    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value MATCHES %@", "facetsRequests=[1-9][0-9]*"),
      object: probe)
    let outcome = XCTWaiter().wait(for: [expectation], timeout: 10)

    print(
      "WP16P2-FACETS-PROBE: window=\(app.frame.size) probeExists=\(probe.exists) "
        + "probeValue=\(probe.exists ? String(describing: probe.value) : "<absent>") "
        + "statsSegmentExists=\(statsSegment.exists) outcome=\(outcome.rawValue)")
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "P2-facets-without-inspector"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertEqual(
      outcome, .completed,
      "The facet counts were never fetched with the inspector off screen. The `debugProbe` "
        + "element's value stayed at "
        + "\(probe.exists ? String(describing: probe.value) : "<absent>") — the refresh trigger "
        + "is still tied to a view that was never built.")

    // ...and it stayed off screen for the whole window, so nothing about the observation depended
    // on the inspector appearing part way through.
    XCTAssertFalse(
      statsSegment.exists,
      "The inspector appeared while the counter was being observed — the fetch cannot be "
        + "attributed to the workspace-level trigger this phase installed.")
  }
}
