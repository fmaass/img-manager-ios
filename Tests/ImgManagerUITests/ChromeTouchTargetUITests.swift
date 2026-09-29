import UIKit
import XCTest

/// WP28 P4 (IMGMGR-451): every chrome control's hit frame, measured (plan Phase 4, p4128
/// "Materials and sizing rules"). Below 28 pt in either dimension is a failure for a control the
/// APP owns; below 44 pt is a WATCH row.
///
/// Coverage is a CENSUS, not a hand-picked list (`chromeCensus`, ChromeCensus.swift): in each
/// surface state the test visits, every control-type element under the navigation bars,
/// toolbars and tab bars is measured, plus the app's own bars by identifier (the Compact options
/// row and the bottom action bar, which live in the content, not in a system bar). Every bar on
/// screen must hold a counted control, and each state's census must contain that state's known
/// controls — the positive control that keeps an empty or wrong query from passing. The states
/// only the materials matrix reaches (search active, select bar, the sheets, Regular-2) are
/// censused there, in the default mode.
///
/// Ownership is by identifier first (`ChromeOwnership`): an identifier in the app's namespace is
/// ALWAYS app-owned; a control without one is system-owned only on a closed list (back button,
/// sidebar toggle, tab bar button, search field, navigation title menu). A system-owned control
/// under 28 pt is a WATCH row, not a failure: growing it would need custom chrome, which the
/// plan forbids (fold round 1 ruling). The title menu's accessibility frame is its title text
/// (Compact 36 × 20.7, Regular 211 × 21 pt, gate on 832e6f1).
///
/// Layout comes from the measured window; a destination that cannot reach a layout skips it with
/// the measured window.
final class ChromeTouchTargetUITests: OrientationPinnedUITestCase {

  private static let regular3WidthThreshold: CGFloat = 1197

  /// Clear folds into More at the narrow tiers, so it is measured when it renders and not
  /// required (the required bar is `gridActionBarIdentifiers`).
  private static let optionalActionBarIdentifiers = ["gridClearButton"]

  /// The ownership rule's precedence, without a simulator: an app identifier wins over every
  /// system shape (a system label, a tab bar, a search field), and an app-owned control under
  /// 28 pt FAILS even when its label is one the system uses.
  func testOwnershipIsByIdentifierFirst() {
    let owner = Self.ownerInTitleMenuState
    XCTAssertNil(
      owner("gridMoreMenu", "stub, Actions Menu", .button, "navigationBar", false),
      "An app id with the title menu's label is still the app's.")
    XCTAssertNil(owner("tab.search", "Search", .button, "tabBar", false))
    XCTAssertNil(owner("folderSearchField", "Search", .searchField, "navigationBar", true))
    XCTAssertNil(owner("", "More", .button, "toolbar", false), "A label alone is not system.")
    XCTAssertNil(owner("", "Search", .button, "navigationBar", false))
    XCTAssertNil(owner("", "Show Sidebar", .button, "navigationBar", false))
    XCTAssertNil(owner("", "stub", .staticText, "navigationBar", false))
    XCTAssertEqual(
      owner("", "stub, Actions Menu", .button, "navigationBar", false),
      ChromeOwnership.titleMenuReason)
    XCTAssertEqual(
      owner("", "Shoots, Actions Menu", .button, "navigationBar", false),
      ChromeOwnership.titleMenuReason, "The tab's own title menu carries the system suffix.")
    XCTAssertNil(
      owner("", "Shoots", .button, "navigationBar", false),
      "A title that is not a fixture title, without the suffix, is the app's.")
    // The declared state's OWN title, bare: the system labelled the Shoots root's trigger
    // "Shoots" on one gate of c71718c and "Shoots, Actions Menu" on another.
    XCTAssertEqual(
      Self.owner(label: "Shoots", titleMenu: true, stateTitles: [CompactTabTitle.shoots]),
      ChromeOwnership.titleMenuReason, "The Shoots root's own title, bare, is its title menu.")
    XCTAssertNil(
      Self.owner(label: "Shoots", titleMenu: false, stateTitles: [CompactTabTitle.shoots]),
      "A state that declares no title menu has no bare title to excuse.")
    XCTAssertNil(
      Self.owner(
        identifier: "shootsRefreshMenuRow", label: "Shoots", titleMenu: true,
        stateTitles: [CompactTabTitle.shoots]),
      "An app id labelled with the state's title is still the app's.")
    XCTAssertNil(
      Self.owner(label: "Library", titleMenu: true, stateTitles: [CompactTabTitle.shoots]),
      "Only the declared state's own title counts, not another tab's.")
    XCTAssertEqual(
      owner("", "Shoot", .button, "navigationBar", false), ChromeOwnership.titleMenuReason,
      "The workspace's neutral fallback title is a fixture-shaped title (final audit F1).")
    XCTAssertNil(
      Self.owner(label: "Shoot", titleMenu: false, stateTitles: []),
      "The fallback title in a state without a title menu is the app's.")
    XCTAssertNil(
      ChromeOwnership.systemOwner(
        identifier: "", label: "Shoots, Actions Menu", type: .button, container: "navigationBar",
        insideSearch: false, titleMenu: false),
      "A state that declares no title menu has none to excuse.")
    XCTAssertNil(
      ChromeOwnership.systemOwner(
        identifier: "", label: "stub, Actions Menu", type: .button, container: "navigationBar",
        insideSearch: false, insideControl: true, titleMenu: true),
      "A button inside another control is not the bar's title menu.")
    XCTAssertNil(owner("", "stub, Actions Menu", .button, "toolbar", false))
    XCTAssertNotNil(owner("BackButton", "Back", .button, "navigationBar", false))
    XCTAssertNotNil(owner("ToggleSidebar", "Hide Sidebar", .button, "navigationBar", false))
    XCTAssertNotNil(owner("", "Library", .button, "tabBar", false))
    XCTAssertNotNil(owner("", "Clear text", .button, "navigationBar", true))

    let small = CGSize(width: 22, height: 22)
    let reused = ChromeTargetRow(
      state: "rule", source: "navigationBar", identifier: "gridMoreMenu", label: "More",
      elementType: .button,
      systemReason: owner("gridMoreMenu", "More", .button, "navigationBar", false), size: small)
    XCTAssertEqual(reused.verdict, "FAIL", "An app control reusing a system label fails under 28.")
    let system = ChromeTargetRow(
      state: "rule", source: "navigationBar", identifier: "", label: "stub",
      elementType: .button,
      systemReason: owner("", "stub", .button, "navigationBar", false), size: small)
    XCTAssertEqual(system.verdict, "WATCH")
  }

  /// `ChromeOwnership.systemOwner` for a top-level, unidentified navigation-bar button.
  private static func owner(
    identifier: String = "", label: String, titleMenu: Bool, stateTitles: [String]
  ) -> String? {
    ChromeOwnership.systemOwner(
      identifier: identifier, label: label, type: .button, container: "navigationBar",
      insideSearch: false, titleMenu: titleMenu, stateTitles: stateTitles)
  }

  /// `ChromeOwnership.systemOwner` for a top-level control in a state with a title menu.
  private static func ownerInTitleMenuState(
    _ id: String, _ label: String, _ type: XCUIElement.ElementType, _ bar: String, _ search: Bool
  ) -> String? {
    ChromeOwnership.systemOwner(
      identifier: id, label: label, type: type, container: bar, insideSearch: search,
      titleMenu: true)
  }

  @MainActor
  func testCompactChromeTouchTargets() throws {
    continueAfterFailure = true
    let roots = launch(extraArguments: ["-UITestStubSkipAutoSelect"], orientation: .portrait)
    guard rendersCompactShell(roots) else {
      throw XCTSkip(
        "IMGMGR-451 Compact touch targets: window=\(roots.windows.firstMatch.frame.size) is not "
          + "Compact.")
    }
    XCTAssertTrue(
      anyElement(roots, "needsReviewRow-1").waitForExistence(timeout: 30),
      "The Shoots root never rendered.")
    let shoots = chromeCensus(
      roots, state: "shoots", titleMenu: true, stateTitles: [CompactTabTitle.shoots],
      requiring: ["accountToolbarButton", "Shoots", "Library", "Search"])
    var rows = shoots.rows
    var problems = shoots.problems
    selectCompactTab(roots, title: "Library")
    XCTAssertTrue(
      anyElement(roots, "folderTreeViewMenu").waitForExistence(timeout: 15),
      "The Library root never rendered its View menu.")
    let library = chromeCensus(roots, state: "library", requiring: ["folderTreeViewMenu"])
    rows += library.rows
    problems += library.problems

    let grid = launch(extraArguments: [], orientation: .portrait)
    XCTAssertTrue(
      grid.buttons["Dislike"].waitForExistence(timeout: 30), "The pushed grid never rendered.")
    XCTAssertTrue(
      gridInfoControl(grid).waitForExistence(timeout: 15), "The grid's Info control is missing.")
    let pushed = chromeCensus(grid, state: "grid", titleMenu: true, requiring: ["Info"])
    rows += pushed.rows
    problems += pushed.problems
    let appBars = Self.gridViewOptionIdentifiers + Self.gridActionBarIdentifiers
    rows += measureAppBars(grid, state: "grid", identifiers: appBars, already: rows)
    rows += measureTitleMenuTrigger(in: grid, state: "grid", already: rows)
    reportChromeTargets(rows, problems: problems, name: "compact")
  }

  @MainActor
  func testRegularChromeTouchTargets() throws {
    continueAfterFailure = true
    let app = launch(extraArguments: [], orientation: .landscapeLeft)
    let window = app.windows.firstMatch.frame.size
    guard window.width >= Self.regular3WidthThreshold else {
      throw XCTSkip(
        "IMGMGR-451 Regular touch targets: window=\(window) does not resolve Regular-3.")
    }
    XCTAssertTrue(
      anyElement(app, "gridFilterControl").waitForExistence(timeout: 30),
      "The Regular grid bar never rendered.")
    let census = chromeCensus(
      app, state: "regular3", titleMenu: true,
      requiring: ["accountToolbarButton", "folderTreeViewMenu", "Info"]
        + Self.gridViewOptionIdentifiers)
    var rows = census.rows
    rows += measureAppBars(
      app, state: "regular3", identifiers: Self.gridActionBarIdentifiers, already: rows)
    rows += measureTitleMenuTrigger(in: app, state: "regular3", already: rows)
    print("TOUCH-TARGET regular: the three tabs are Compact-only (no tab bar at Regular)")
    reportChromeTargets(rows, problems: census.problems, name: "regular3")
  }

  // MARK: - Launch and the app's own bars

  private func launch(
    extraArguments: [String], orientation: UIDeviceOrientation
  ) -> XCUIApplication {
    XCUIDevice.shared.orientation = orientation
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"] + extraArguments
    app.launch()
    XCUIDevice.shared.orientation = orientation
    Thread.sleep(forTimeInterval: 2.0)
    return app
  }

  /// The app's own bars by identifier — controls that sit in the content, not in a system bar.
  /// A control the census already counted is not measured twice.
  private func measureAppBars(
    _ app: XCUIApplication, state: String, identifiers: [String], already rows: [ChromeTargetRow]
  ) -> [ChromeTargetRow] {
    var measured: [ChromeTargetRow] = []
    let all = identifiers + Self.optionalActionBarIdentifiers
    for identifier in all where !rows.contains(where: { $0.identifier == identifier }) {
      let element = anyElement(app, identifier)
      let required = identifiers.contains(identifier)
      guard element.waitForExistence(timeout: required ? 15 : 2) else {
        if required {
          XCTFail("\(identifier) is not on screen, so its touch target cannot be measured.")
        } else {
          print("TOUCH-TARGET \(state): \(identifier) not rendered (folded into More)")
        }
        continue
      }
      measured.append(
        ChromeTargetRow(
          state: state, source: "app bar", identifier: identifier, label: element.label,
          elementType: element.elementType, systemReason: nil, size: element.frame.size))
    }
    return measured
  }

  /// The title-menu trigger when the census did not already count it (at Regular it can be the
  /// title's static text rather than a button). System-owned unless it carries an app id.
  private func measureTitleMenuTrigger(
    in app: XCUIApplication, state: String, already rows: [ChromeTargetRow]
  ) -> [ChromeTargetRow] {
    if rows.contains(where: { $0.systemReason == ChromeOwnership.titleMenuReason }) { return [] }
    let title = gridTitleMenuTrigger(app, names: Self.materialsFolderOneNames)
    guard title.waitForExistence(timeout: 5) else {
      XCTFail("The title menu trigger is not on screen, so it cannot be measured.")
      return []
    }
    var reason: String? = ChromeOwnership.titleMenuReason
    if ChromeOwnership.isAppIdentifier(title.identifier) { reason = nil }
    let row = ChromeTargetRow(
      state: state, source: "navigationBar", identifier: title.identifier, label: title.label,
      elementType: title.elementType, systemReason: reason, size: title.frame.size)
    return [row]
  }
}
