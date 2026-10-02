import XCTest

/// WP30 P1 (IMGMGR-456) acceptance: "header carries exactly three toolbar groups, no zoom pill
/// present, filmstrip renders as content not glass". Runs on both destinations; Compare and Info
/// are iPad-only (the Compact cover has no inspector path, and iPhone has no Compare).
final class LoupeToolbarUITests: OrientationPinnedUITestCase {

  /// The grid bar's own controls — none of them may be mounted while the loupe is open.
  /// IMGMGR-464 (WP32 P2) deleted `gridShortcutHelpControl`, so it is no longer listed.
  private static let gridBarIdentifiers = [
    "gridSelectCommand", "gridFilterControl", "gridArrangeControl", "gridMoreMenu",
    "inspectorChromeButton",
  ]

  // MARK: - Three groups, and no grid item

  @MainActor
  func testLoupeBarCarriesThreeGroupsAndNoGridItem() throws {
    let app = launchAndOpenLoupe()
    let isCompact = rendersCompactShell(app)
    let bar = loupeBar(app)
    XCTAssertTrue(bar.waitForExistence(timeout: 10), "No navigation bar carries loupeBack.")
    XCTAssertEqual(loupeBars(app).count, 1, "More than one navigation bar carries loupeBack.")
    XCTAssertEqual(
      app.buttons.matching(identifier: "loupeBack").count, 1, "Back is on screen more than once.")

    let back = bar.buttons["loupeBack"]
    let title = bar.staticTexts["loupeTitle"]
    let more = element(bar, "loupeMoreMenu")
    XCTAssertTrue(back.exists, "The leading group has no Back.")
    XCTAssertTrue(title.waitForExistence(timeout: 10), "The principal group has no title.")
    XCTAssertTrue(more.exists, "The trailing group has no More.")
    XCTAssertTrue(
      title.label.range(of: #"[0-9]+ of [0-9]+$"#, options: .regularExpression) != nil,
      "The title does not state the position in the scope: '\(title.label)'.")
    XCTAssertTrue(
      element(app, "loupeFidelityLabel").exists, "The fidelity label lost its home.")

    let compare = element(bar, "loupeCompareButton")
    let info = element(bar, "loupeInfoButton")
    if isCompact {
      XCTAssertFalse(compare.exists, "Compare is an iPad verb; the phone's bar carries it.")
      XCTAssertFalse(info.exists, "The Compact cover has no inspector path, yet Info is built.")
    } else {
      XCTAssertTrue(compare.exists, "The Regular trailing group has no Compare.")
      // WP30 P3 (IMGMGR-458) wired it: the flat fixture's scope holds far more than two images.
      XCTAssertTrue(compare.isEnabled, "Compare is disabled on a scope of two or more images.")
      XCTAssertTrue(info.exists, "The Regular trailing group has no Info.")
    }

    // Three groups, left to right: leading · principal · trailing.
    let trailingMinX = isCompact ? more.frame.minX : compare.frame.minX
    XCTContext.runActivity(
      named: "frames — back \(back.frame) | title \(title.frame) | trailing minX \(trailingMinX)"
    ) { _ in }
    XCTAssertLessThan(back.frame.maxX, title.frame.minX, "Back is not leading the title.")
    XCTAssertLessThan(title.frame.maxX, trailingMinX, "The trailing group is not after the title.")

    for identifier in Self.gridBarIdentifiers {
      XCTAssertFalse(
        element(bar, identifier).exists, "The loupe's bar carries the grid's `\(identifier)`.")
    }
    attach(app, name: "loupe-toolbar-three-groups")

    back.tap()
    XCTAssertTrue(back.waitForNonExistence(timeout: 10), "Back did not close the loupe.")
    XCTAssertTrue(
      element(app, "gridSelectCommand").waitForExistence(timeout: 10),
      "After Back the grid's toolbar did not come back.")
  }

  // MARK: - Info

  @MainActor
  func testInfoOpensAndClosesTheInspector() throws {
    let app = launchAndOpenLoupe()
    guard !rendersCompactShell(app) else {
      throw XCTSkip("Info on the loupe is iPad-only (the Compact cover has no inspector path).")
    }
    let info = element(loupeBar(app), "loupeInfoButton")
    XCTAssertTrue(info.waitForExistence(timeout: 10), "The loupe's bar has no Info.")
    let stats = app.buttons["Stats"]
    XCTAssertFalse(stats.exists, "The inspector is already shown before Info was tapped.")
    info.tap()
    XCTAssertTrue(stats.waitForExistence(timeout: 10), "Info did not open the inspector.")
    attach(app, name: "loupe-toolbar-inspector-open")
    element(loupeBar(app), "loupeInfoButton").tap()
    XCTAssertTrue(stats.waitForNonExistence(timeout: 10), "Info did not close the inspector.")
  }

  // MARK: - No zoom pill

  @MainActor
  func testNoZoomPillIsPresent() throws {
    let app = launchAndOpenLoupe()
    let content = element(app, "loupeContent")
    XCTAssertTrue(
      content.waitForExistence(timeout: 10), "The loupe's content container is missing.")
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "loupeContent").count, 1,
      "More than one loupe is presented.")
    XCTAssertEqual(loupeBars(app).count, 1, "The loupe's bar is missing or duplicated.")

    // The presented loupe, whole: its content, its navigation bar and its bottom bar all sit in
    // the loupe's column, so the scope is every element whose centre lies in that column — at
    // Regular this leaves out the sidebar beside it, nothing of the loupe's own. One snapshot,
    // walked in memory, so every button and static text is read, identified or not.
    let column = content.frame.minX...content.frame.maxX
    let offenders = LoupeScopeScan.offenders(in: try app.snapshot(), column: column)
    XCTContext.runActivity(named: "no-zoom scan, column \(column): \(offenders)") { _ in }
    XCTAssertEqual(offenders, [], "The presented loupe carries zoom chrome: \(offenders)")
  }

  // MARK: - Filmstrip is content

  @MainActor
  func testFilmstripRendersAsContentNotGlass() throws {
    let app = launchAndOpenLoupe()
    let strip = element(app, "loupeFilmstrip")
    XCTAssertTrue(strip.waitForExistence(timeout: 10), "The flat-browse loupe has no filmstrip.")
    XCTAssertEqual(
      strip.value as? String, "content",
      "The filmstrip's resolved MaterialPolicy role is not `content`.")
  }

  // MARK: - Mark group

  @MainActor
  func testMarkGroupReadsDislikeClearPickThenUndo() throws {
    let app = launchAndOpenLoupe()
    let ids = ["loupeDislikeButton", "loupeClearButton", "loupePickButton", "loupeUndoButton"]
    let controls = ids.map { app.buttons[$0] }
    for (id, control) in zip(ids, controls) {
      XCTAssertTrue(control.waitForExistence(timeout: 10), "The mark group has no `\(id)`.")
    }
    let markBar = element(app, "loupeMarkBar")
    XCTAssertTrue(markBar.exists, "The mark group lost `loupeMarkBar`.")
    // Containment: the verdict controls are inside `loupeMarkBar` (IMGMGR-280 `.contain` order
    // keeps their own ids); Undo sits after the fixed spacer, in its own bottom-bar item.
    for id in ["loupeDislikeButton", "loupeClearButton", "loupePickButton"] {
      XCTAssertTrue(markBar.buttons[id].exists, "`\(id)` is not inside `loupeMarkBar`.")
    }
    XCTAssertFalse(
      markBar.buttons["loupeUndoButton"].exists, "Undo is inside `loupeMarkBar`, not after it.")
    let minXs = controls.map(\.frame.minX)
    XCTContext.runActivity(named: "mark group minX \(minXs)") { _ in }
    XCTAssertEqual(minXs, minXs.sorted(), "The mark group is not Dislike · Clear · Pick · Undo.")
    XCTAssertEqual(Set(minXs).count, 4, "Two mark controls share a position.")
    attach(app, name: "loupe-mark-group")
  }

  @MainActor
  func testPickMarksTheFocusedPhotographAndUndoRevertsIt() throws {
    let app = launchAndOpenLoupe(extraArguments: ["-UITestStubNoAutoAdvance"])
    let pick = app.buttons["loupePickButton"]
    let clear = app.buttons["loupeClearButton"]
    let undo = app.buttons["loupeUndoButton"]
    XCTAssertTrue(pick.waitForExistence(timeout: 10), "The mark group has no Pick.")
    if (pick.value as? String) != "Not picked" {
      clear.tap()
      wait(for: [expectation(for: valueIs("Not picked"), evaluatedWith: pick)], timeout: 10)
    }
    pick.tap()
    wait(for: [expectation(for: valueIs("Picked"), evaluatedWith: pick)], timeout: 10)
    XCTAssertTrue(pick.isSelected, "A picked frame's Pick control does not read as selected.")
    undo.tap()
    wait(for: [expectation(for: valueIs("Not picked"), evaluatedWith: pick)], timeout: 10)
  }

  // MARK: - More › Share

  @MainActor
  func testMoreShareShowsTheShareSheet() throws {
    let app = launchAndOpenLoupe()
    let more = element(loupeBar(app), "loupeMoreMenu")
    XCTAssertTrue(more.waitForExistence(timeout: 10), "The loupe's bar has no More.")
    more.tap()
    let share = app.buttons["loupeShare"]
    XCTAssertTrue(share.waitForExistence(timeout: 10), "More carries no Share row.")
    share.tap()
    let ours = app.otherElements["loupeShareSheet"]
    let system = app.otherElements["ActivityListView"]
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline && !(ours.exists || system.exists) {
      Thread.sleep(forTimeInterval: 0.1)
    }
    attach(app, name: "loupe-more-share-sheet")
    XCTAssertTrue(ours.exists || system.exists, "More › Share did not present the share sheet.")
  }

  // MARK: - Looks (IMGMGR-382)

  /// Looks leads the trailing group — Looks · Compare · Info · More on the iPad, Looks · More on
  /// the phone — and choosing a look or None is stated on the control's value and, once the
  /// bytes are painted, on the loupe image's label.
  @MainActor
  func testLooksLeadsTheTrailingGroupAndChoosesALook() throws {
    let app = launchAndOpenLoupe()
    let isCompact = rendersCompactShell(app)
    let bar = loupeBar(app)
    XCTAssertTrue(bar.waitForExistence(timeout: 10), "No navigation bar carries loupeBack.")
    let looks = element(bar, "loupeLooksButton")
    XCTAssertTrue(looks.waitForExistence(timeout: 10), "The trailing group has no Looks.")

    var trailing = [looks]
    if !isCompact {
      trailing += [element(bar, "loupeCompareButton"), element(bar, "loupeInfoButton")]
    }
    trailing.append(element(bar, "loupeMoreMenu"))
    for item in trailing {
      XCTAssertTrue(item.exists, "A trailing item is missing: \(item.debugDescription)")
    }
    for (left, right) in zip(trailing, trailing.dropFirst()) {
      XCTAssertLessThan(
        left.frame.minX, right.frame.minX,
        "The trailing group is out of order: \(left.identifier) is not before \(right.identifier).")
    }

    // The catalogue arrives with the loupe; until then the control is disabled.
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "isEnabled == true"), object: looks)
    XCTAssertEqual(
      XCTWaiter().wait(for: [enabled], timeout: 15), .completed,
      "Looks never became choosable: the stub catalogue did not arrive.")
    XCTAssertEqual(looks.value as? String, "Off", "With no look chosen, Looks does not read Off.")

    let warm = element(app, "loupeLook-warm-film")
    XCTAssertTrue(
      openPresentation(looks, revealing: warm, timeout: 15), "Looks did not open its popover.")
    XCTAssertTrue(element(app, "loupeLook-none").exists, "The popover has no None row.")
    attach(app, name: "loupe-looks-popover")
    warm.tap()
    XCTAssertTrue(warm.waitForNonExistence(timeout: 10), "Choosing a look did not dismiss.")
    let named = XCTNSPredicateExpectation(predicate: valueIs("Warm Film"), object: looks)
    XCTAssertEqual(
      XCTWaiter().wait(for: [named], timeout: 10), .completed,
      "After choosing Warm Film, Looks reads '\(looks.value as? String ?? "nil")'.")
    // The render signal: the painted bytes went through the look (the label, not the value,
    // which stays the zoom state).
    let image = element(app, "loupeImage")
    let lookedLabel = NSPredicate(format: "label == %@", "Photograph, look Warm Film")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: lookedLabel, object: image)], timeout: 15),
      .completed, "The loupe never painted the looked render: '\(image.label)'.")
    attach(app, name: "loupe-looks-warm-film")

    let none = element(app, "loupeLook-none")
    XCTAssertTrue(
      openPresentation(looks, revealing: none, timeout: 15), "Looks did not reopen its popover.")
    none.tap()
    XCTAssertTrue(none.waitForNonExistence(timeout: 10), "Choosing None did not dismiss.")
    let off = XCTNSPredicateExpectation(predicate: valueIs("Off"), object: looks)
    XCTAssertEqual(
      XCTWaiter().wait(for: [off], timeout: 10), .completed,
      "After choosing None, Looks reads '\(looks.value as? String ?? "nil")'.")
    // "Photograph" is only ever the label of PAINTED unlooked bytes; nothing painted reads
    // "Photograph not loaded", so this wait needs a real image on screen.
    let unlookedLabel = NSPredicate(format: "label == %@", "Photograph")
    XCTAssertEqual(
      XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: unlookedLabel, object: image)], timeout: 15),
      .completed, "After None the loupe did not repaint unlooked: '\(image.label)'.")
  }

  // MARK: - Shared

  private func valueIs(_ value: String) -> NSPredicate {
    NSPredicate(format: "value == %@", value)
  }

  private func element(_ root: XCUIElement, _ identifier: String) -> XCUIElement {
    root.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// The navigation bar the loupe's toolbar renders on — the one that carries Back.
  private func loupeBar(_ app: XCUIApplication) -> XCUIElement {
    loupeBars(app).firstMatch
  }

  /// Every navigation bar carrying Back: exactly one, or a bar has leaked or been duplicated.
  private func loupeBars(_ app: XCUIApplication) -> XCUIElementQuery {
    app.navigationBars.containing(.button, identifier: "loupeBack")
  }

  /// Launches the stub grid and opens the loupe on the first tile (two taps: the first focuses,
  /// the second opens — `GridStore.tapTile`).
  private func launchAndOpenLoupe(extraArguments: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid"] + extraArguments
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "The stub grid never rendered its action bar.")
    let back = app.buttons["loupeBack"]
    for _ in 0..<3 where !back.exists {
      let tile = element(app, "gridTile-1")
      guard tile.waitForExistence(timeout: 15) else { break }
      tile.tap()
      _ = back.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(back.exists, "The loupe never opened from a tile tap.")
    return app
  }

  private func attach(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

/// WP30 P1 round 2: the no-zoom scan over one accessibility snapshot of the presented loupe.
/// Every button and static text in the loupe's column is inspected; an identifier containing
/// `zoom` on ANY element there is an offender too.
@MainActor
enum LoupeScopeScan {
  /// The zoom pill's vocabulary: "100 %", "Fit", any percentage.
  static let pillPattern = #"(%|\bFit\b|\b100\b)"#

  /// Narrow exclusions, each by identifier:
  /// - `loupeTitle`: "shoot · n of N" may legitimately read "… of 100";
  /// - `filmstripThumbnail-*`: a thumbnail's label is the photograph's FILENAME (photo content,
  ///   `FilmstripThumbnailAccessibility`), which the app does not choose.
  static func isExcluded(_ identifier: String) -> Bool {
    identifier == "loupeTitle" || identifier.hasPrefix("filmstripThumbnail-")
  }

  static func offenders(
    in root: any XCUIElementSnapshot, column: ClosedRange<CGFloat>
  ) -> [String] {
    var found: [String] = []
    var stack: [any XCUIElementSnapshot] = [root]
    while let node = stack.popLast() {
      stack.append(contentsOf: node.children)
      guard column.contains(node.frame.midX) else { continue }
      let id = node.identifier
      if id.lowercased().contains("zoom") {
        found.append("id:\(id)")
        continue
      }
      let isTextual = node.elementType == .button || node.elementType == .staticText
      guard isTextual, !isExcluded(id) else { continue }
      if node.label.range(of: pillPattern, options: .regularExpression) != nil {
        found.append("\(node.elementType.rawValue):\(id):\(node.label)")
      }
    }
    return found
  }
}
