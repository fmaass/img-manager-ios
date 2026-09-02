import UIKit
import XCTest

/// The base every UI test class in this target inherits: it pins the simulator's device
/// orientation in `setUp` and returns it to portrait in `tearDown`.
///
/// WHY a base class and not a per-class override (IMGMGR-336): device orientation is
/// SIMULATOR-GLOBAL and outlives the class that set it, so a class that pins nothing runs
/// against whatever the previously-sorted class happened to leave behind. That has cost this
/// repo two gate cycles already — `RegularThreeScreenshotUITests` left the iPad in
/// `landscapeLeft` and the classes sorting after it ran every assertion against a layout they
/// were not written for (7 tests / 20 assertions red on iPad; one iPhone pan assertion at
/// 874x402). Commit `71dd737` pinned the three classes it had evidence for and recorded the
/// lesson in a comment; six classes still pinned nothing, so the trap stayed armed for whichever
/// class is added or renamed next. A comment is not a mechanism.
///
/// Subclasses declare their orientation by overriding `pinnedOrientation` — NEVER by overriding
/// `setUp`, because an override that forgets `super.setUp()` re-arms exactly the trap this type
/// exists to disarm. `bin/mac-gate.sh`'s `ui-orientation-base-grep` leg is what keeps a new
/// class from subclassing `XCTestCase` directly and slipping out of it.
class OrientationPinnedUITestCase: XCTestCase {

  /// The orientation this class's assertions are written for. Portrait unless the layout under
  /// test IS the landscape one.
  class var pinnedOrientation: UIDeviceOrientation { .portrait }

  override func setUp() {
    super.setUp()
    XCUIDevice.shared.orientation = Self.pinnedOrientation
  }

  /// Portrait, never `pinnedOrientation`: what a class leaves behind is the next class's
  /// starting state, and a landscape class that restored its own pin would export the very
  /// state this type exists to stop travelling.
  override func tearDown() {
    XCUIDevice.shared.orientation = .portrait
    super.tearDown()
  }
}
