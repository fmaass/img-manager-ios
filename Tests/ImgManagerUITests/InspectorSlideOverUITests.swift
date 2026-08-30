import UIKit
import XCTest

/// WP13 P10 (IMGMGR-219), on the real simulator surface. Two jobs, one code path:
///
/// 1. **The phase's live probe** — which real configurations resolve to which layout mode. Every
///    input is a fact the app RENDERED: the iPad-only "Folders" disclosure (`QueueView` is handed
///    `treeSection: nil` on Compact) and the inspector's own "Stats" segment already on screen
///    with nothing tapped (only Regular-3's permanent column does that). Plus the measured window
///    size, printed for the record. Never a device idiom — this target is inside the gate's
///    device-idiom absence grep like every other source directory.
///
/// 2. **The acceptance assertion** — at Regular-2 the inspector is a NON-MODAL panel: the grid's
///    own controls stay hittable beside it. Under the pre-P10 modal sheet that assertion fails,
///    which is exactly the RED this phase had to observe before flipping the placement.
///
/// Both `bin/mac-gate.sh` destinations run this file, and each asserts the contract of the mode
/// it actually resolved — so the iPhone leg pins "Compact still presents the sheet" through the
/// same code that pins the slide-over on the iPad leg.
final class InspectorSlideOverUITests: XCTestCase {

  private enum ResolvedLayout: String {
    case compact
    case regular2
    case regular3
  }

  func testInspectorPresentationInPortrait() {
    assertInspectorContract(orientation: .portrait, orientationName: "portrait")
  }

  func testInspectorPresentationInLandscape() {
    assertInspectorContract(orientation: .landscapeLeft, orientationName: "landscape")
  }

  private func assertInspectorContract(
    orientation: UIDeviceOrientation, orientationName: String
  ) {
    XCUIDevice.shared.orientation = orientation

    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"]
    app.launch()

    let dislike = app.buttons["Dislike"]
    XCTAssertTrue(
      dislike.waitForExistence(timeout: 30),
      "Action bar (Dislike) never appeared within 30s — expected the DEBUG fixture "
        + "composition's populated grid, got something else (sign-in, blank, or a failed stub).")

    // The rotation's own layout pass, then the resolver's `.onGeometryChange` reaction to it.
    Thread.sleep(forTimeInterval: 2.0)

    let foldersDisclosure = app.descendants(matching: .any)["Folders"]
    let statsSegment = app.buttons["Stats"]
    let chromeInfo = app.navigationBars.buttons
      .matching(NSPredicate(format: "label BEGINSWITH 'Info'")).firstMatch

    let hasFolders = foldersDisclosure.exists
    let inspectorAlreadyOnScreen = statsSegment.exists
    let hasChromeInfo = chromeInfo.exists
    let resolved: ResolvedLayout =
      !hasFolders ? .compact : (inspectorAlreadyOnScreen ? .regular3 : .regular2)

    // The probe's record. `print` (not only an activity) because the gate copies back the
    // xcodebuild log, which is where this has to be readable afterwards.
    print(
      "P10-PROBE \(orientationName): window=\(app.frame.size) folders=\(hasFolders) "
        + "inspectorAtLaunch=\(inspectorAlreadyOnScreen) chromeInfo=\(hasChromeInfo) "
        + "resolvedLayout=\(resolved.rawValue)")
    attach(app: app, named: "P10-\(orientationName)-\(resolved.rawValue)-atLaunch")

    switch resolved {
    case .compact:
      XCTAssertTrue(
        hasChromeInfo, "Compact must reach the inspector from the persistent chrome control.")
      chromeInfo.tap()
      XCTAssertTrue(
        statsSegment.waitForExistence(timeout: 10), "The inspector never appeared after Info.")
      // Fold item 7's ONE Info/Stats sheet is modal by design and STAYS modal at Compact — the
      // grid behind it is covered, so its controls are not hittable. This is the pin that keeps
      // P10's reversal scoped to the one width it is meant for.
      XCTAssertFalse(
        dislike.isHittable,
        "Compact must still present the modal sheet — the grid is not reachable behind it.")

    case .regular2:
      XCTAssertTrue(
        hasChromeInfo, "Regular-2 must reach the inspector from the persistent chrome control.")
      chromeInfo.tap()
      XCTAssertTrue(
        statsSegment.waitForExistence(timeout: 10), "The inspector never appeared after Info.")
      // THE phase assertion ([/link/3220] §2.2, IMGMGR-219): a slide-over, not a modal. The grid
      // is still on screen AND still takes taps beside the panel. RED under the shipped sheet.
      XCTAssertTrue(
        dislike.isHittable,
        "Regular-2's inspector must not block the grid — a panel that stops the grid taking "
          + "taps is the modal sheet with a different animation.")

    case .regular3:
      XCTAssertFalse(
        hasChromeInfo,
        "Regular-3's inspector is a permanent column — there is nothing for a chrome control to "
          + "open.")
      XCTAssertTrue(dislike.isHittable, "The grid stays interactive beside the permanent column.")
    }

    attach(app: app, named: "P10-\(orientationName)-\(resolved.rawValue)-inspectorShown")
  }

  private func attach(app: XCUIApplication, named name: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTContext.runActivity(named: "\(name) — captured size \(screenshot.image.size)") { _ in }
  }
}
