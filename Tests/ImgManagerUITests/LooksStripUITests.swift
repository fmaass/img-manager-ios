import XCTest

/// IMGMGR-543 (P16a, R3-10): the Looks strip, driven through the real app on both destinations —
/// the Compact loupe cover and the docked Regular loupe.
///
/// AC4 (`LooksStripUITests`): open the strip, preview a look, Cancel restores the unlooked photo.
/// The keys (`LooksStripKeysUITests`): bare ←→↑↓, Return, Space and Esc pressed as hardware keys
/// (`typeKey`), read back through the strip's and the loupe's own accessibility values. Bare keys
/// reach the gate's simulators (`SilentKeysUITests`), so a key that does not arrive is a FAILURE.
class LooksStripUITestCase: OrientationPinnedUITestCase {

  /// The DEBUG fixture grid with advance-on-mark off, the loupe open on its first photograph and
  /// the look catalogue arrived (the Looks control enabled).
  func launchIntoTheLoupe() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITestStubGrid", "-UITestStubNoAutoAdvance"]
    app.launch()
    XCTAssertTrue(
      app.buttons["Dislike"].waitForExistence(timeout: 30),
      "The DEBUG fixture grid never rendered its action bar.")
    let back = app.buttons["loupeBack"]
    for _ in 0..<3 where !back.exists {
      let tile = element(app, "gridTile-1")
      guard tile.waitForExistence(timeout: 15) else { break }
      tile.tap()
      _ = back.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(back.exists, "Tapping gridTile-1 never opened the loupe.")
    let looks = element(app, "loupeLooksButton")
    XCTAssertTrue(looks.waitForExistence(timeout: 10), "The loupe has no Looks control.")
    XCTAssertTrue(
      waitFor(looks, "isEnabled == true", timeout: 15),
      "Looks never became choosable: the stub catalogue did not arrive.")
    return app
  }

  /// Opens the strip with the Looks control and waits for its None tile.
  func openStrip(_ app: XCUIApplication) {
    element(app, "loupeLooksButton").tap()
    XCTAssertTrue(
      element(app, "loupeLookTile-none").waitForExistence(timeout: 10),
      "Looks did not open the strip.")
    XCTAssertTrue(element(app, "loupeLooksStrip").exists, "The strip has no container.")
  }

  func element(_ root: XCUIElement, _ identifier: String) -> XCUIElement {
    root.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  func waitFor(
    _ element: XCUIElement, _ format: String, _ args: Any..., timeout: TimeInterval = 10
  ) -> Bool {
    let predicate = NSPredicate(format: format, argumentArray: args)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  /// Taps a strip control at its centre. XCUITest computes NO hit point for the strip's tiles
  /// ({-1, -1} on both destinations, gate run 2026-10-23 18:21), so `tap()` refuses before it
  /// presses; a coordinate tap still lands on the real control, and every caller asserts the
  /// tap's effect, so a press that reaches nothing still fails.
  func press(_ element: XCUIElement) {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
  }

  /// The DEBUG key-receipt probe (`DebugKeyReceipt`): every key press the app received, Esc
  /// spelled `<esc>`. "<absent>" where the probe is not in the tree (under the Compact cover).
  func keyReceipts(_ app: XCUIApplication) -> String {
    let value = element(app, "debugProbe.keyReceipts").value as? String ?? "<absent>"
    return value.replacingOccurrences(of: "\u{1B}", with: "<esc>")
  }

  func strength(_ app: XCUIApplication) -> Int? {
    let value = element(app, "loupeLookStrength").value as? String ?? ""
    return Int(value.replacingOccurrences(of: " %", with: ""))
  }
}

final class LooksStripUITests: LooksStripUITestCase {

  /// AC4: the strip replaces the filmstrip, a tile previews its look on the main image, Apply is
  /// present but inert, and Cancel brings back the unlooked photograph and the filmstrip.
  func testStripPreviewsALookAndCancelRestoresTheUnlookedPhoto() throws {
    let app = launchIntoTheLoupe()
    let image = element(app, "loupeImage")
    XCTAssertTrue(
      waitFor(image, "label == %@", "Photograph", timeout: 15),
      "The loupe never painted the unlooked photograph: '\(image.label)'.")
    let hadFilmstrip = element(app, "loupeFilmstrip").exists

    openStrip(app)
    if hadFilmstrip {
      XCTAssertTrue(
        waitFor(element(app, "loupeFilmstrip"), "exists == false"),
        "The strip did not take the filmstrip's place.")
    }
    let warm = element(app, "loupeLookTile-warm-film")
    XCTAssertTrue(warm.waitForExistence(timeout: 10), "The strip has no Warm Film tile.")
    press(warm)
    XCTAssertTrue(waitFor(warm, "value == %@", "Selected"), "Warm Film is not selected.")
    XCTAssertTrue(
      waitFor(image, "label == %@", "Photograph, look Warm Film", timeout: 15),
      "The loupe never painted the looked preview: '\(image.label)'.")
    XCTAssertTrue(element(app, "loupeLookStrength").isEnabled, "Strength is off with a look.")
    XCTAssertEqual(strength(app), 100, "The strength does not start at 100 %.")
    let apply = element(app, "loupeLooksApply")
    XCTAssertTrue(apply.exists, "The strip has no Apply.")
    XCTAssertFalse(apply.isEnabled, "Apply is live before P16b.")
    attach(app, name: "looks-strip-warm-film")

    press(element(app, "loupeLooksCancel"))
    XCTAssertTrue(
      waitFor(element(app, "loupeLooksStrip"), "exists == false"), "Cancel left the strip up.")
    XCTAssertTrue(
      waitFor(image, "label == %@", "Photograph", timeout: 15),
      "Cancel did not repaint the unlooked photograph: '\(image.label)'.")
    XCTAssertTrue(
      waitFor(element(app, "loupeLooksButton"), "value == %@", "Off"),
      "After Cancel, Looks does not read Off.")
    if hadFilmstrip {
      XCTAssertTrue(
        element(app, "loupeFilmstrip").waitForExistence(timeout: 10),
        "Cancel did not bring the filmstrip back.")
    }
    attach(app, name: "looks-strip-cancelled")
  }

  private func attach(_ app: XCUIApplication, name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }
}

final class LooksStripKeysUITests: LooksStripUITestCase {

  /// → selects the next tile, ↑/↓ move the strength by 10 and stop at 0, and the photograph in
  /// front of the reader never changes.
  func testArrowsWalkLooksAndNudgeStrength() throws {
    let app = launchIntoTheLoupe()
    let title = element(app, "loupeTitle")
    let position = title.label
    openStrip(app)
    pressRightUntilWarmFilm(app)
    let image = element(app, "loupeImage")
    XCTAssertTrue(
      waitFor(image, "label == %@", "Photograph, look Warm Film", timeout: 15),
      "→ did not preview Warm Film: '\(image.label)'.")
    // One press at a time, each answered by exactly one step of 10: thirteen ↓ typed back to
    // back on the iPad registered three (gate run 2026-10-23 19:48).
    for expected in [110, 120] {
      XCTAssertTrue(
        nudge(app, XCUIKeyboardKey.upArrow, to: expected),
        "↑ did not take the strength to \(expected) %: \(String(describing: strength(app))).")
    }
    for expected in stride(from: 110, through: 0, by: -10) {
      XCTAssertTrue(
        nudge(app, XCUIKeyboardKey.downArrow, to: expected),
        "↓ did not take the strength to \(expected) %: \(String(describing: strength(app))).")
    }
    app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
    Thread.sleep(forTimeInterval: 1)
    XCTAssertEqual(strength(app), 0, "↓ did not stop at 0 %.")
    XCTAssertEqual(title.label, position, "The arrows moved the loupe to another photograph.")
  }

  /// A dragged slider must not take the arrows: ↑ still nudges by 10 and ← still walks back.
  func testArrowsStillWorkAfterTheSliderWasDragged() throws {
    let app = launchIntoTheLoupe()
    openStrip(app)
    // Twice: the iPad lost the arrows after a drag on the system Slider in two of three runs.
    for round in 1...2 {
      pressRightUntilWarmFilm(app)
      let track = element(app, "loupeLookStrength")
      XCTAssertTrue(waitFor(track, "isEnabled == true"), "Strength is off with a look.")
      let before = strength(app)
      drag(app, track, to: round == 1 ? 0.75 : 0.25)
      let deadline = Date(timeIntervalSinceNow: 5)
      while strength(app) == before, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
      let dragged = try XCTUnwrap(strength(app), "The track reads no strength.")
      XCTAssertNotEqual(dragged, before, "Round \(round): dragging did not change the strength.")
      app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
      let expected = min(dragged + 10, 200)
      XCTAssertTrue(
        waitFor(track, "value == %@", "\(expected) %"),
        "Round \(round): ↑ after a drag did not nudge \(dragged) % to \(expected) %: "
          + "\(String(describing: strength(app))).")
      app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
      XCTAssertTrue(
        waitFor(element(app, "loupeLookTile-none"), "value == %@", "Selected"),
        "Round \(round): ← after a drag did not walk back to None.")
    }
  }

  /// Presses `key` and waits for the strength to read `value`; re-pressed once only while the
  /// strength has not moved at all (a press that never registered), never past a step.
  private func nudge(_ app: XCUIApplication, _ key: XCUIKeyboardKey, to value: Int) -> Bool {
    let before = strength(app)
    for _ in 0..<2 {
      app.typeKey(key.rawValue, modifierFlags: [])
      if waitFor(element(app, "loupeLookStrength"), "value == %@", "\(value) %", timeout: 4) {
        return true
      }
      guard strength(app) == before else { return false }
    }
    return false
  }

  /// Drags the strength track's thumb from where it sits to `fraction` of the track.
  private func drag(_ app: XCUIApplication, _ track: XCUIElement, to fraction: CGFloat) {
    let value = CGFloat(strength(app) ?? 100) / 200
    let start = track.coordinate(withNormalizedOffset: CGVector(dx: value, dy: 0.5))
    let end = track.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
    start.press(forDuration: 0.1, thenDragTo: end)
  }

  /// Return and Space share Open, and both are inert in the strip: Apply arrives with P16b.
  func testReturnAndSpaceAreInertInTheStrip() throws {
    let app = launchIntoTheLoupe()
    let title = element(app, "loupeTitle")
    let position = title.label
    openStrip(app)
    pressRightUntilWarmFilm(app)
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.space.rawValue, modifierFlags: [])
    Thread.sleep(forTimeInterval: 2)
    XCTAssertTrue(element(app, "loupeLooksStrip").exists, "Return or Space closed the strip.")
    XCTAssertEqual(
      element(app, "loupeLookTile-warm-film").value as? String, "Selected",
      "Return or Space changed the previewed look.")
    XCTAssertEqual(strength(app), 100, "Return or Space changed the strength.")
    XCTAssertFalse(element(app, "loupeLooksApply").isEnabled, "Apply became live.")
    XCTAssertTrue(app.buttons["loupeBack"].exists, "Return or Space left the loupe.")
    XCTAssertEqual(title.label, position, "Return or Space moved to another photograph.")
  }

  /// Esc cancels the strip and stays in the loupe; a second Esc does not close the loupe.
  func testEscapeCancelsLooksWithoutLeavingTheLoupe() throws {
    let app = launchIntoTheLoupe()
    openStrip(app)
    pressRightUntilWarmFilm(app)
    let receiptsBefore = keyReceipts(app)
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    guard waitFor(element(app, "loupeLooksStrip"), "exists == false") else {
      // PeekBandUITests.pressEscape's rule: a press the app never received is not a verdict on
      // the app. The gate's simulators withhold Esc (IMGMGR-508; PeekBand's own Esc tests skip
      // there too), so with no new key receipt this skips, and a received Esc that left the
      // strip up fails. Esc's dispatch is LookStripTests.escapeCancelsTheStrip, through the
      // real declaration. Under the Compact cover the probe is not in the tree: read it after
      // Back, from the workspace.
      let receiptsInLoupe = keyReceipts(app)
      app.buttons["loupeBack"].firstMatch.tap()
      _ = element(app, "debugProbe.keyReceipts").waitForExistence(timeout: 5)
      let receiptsAfter = keyReceipts(app)
      guard receiptsAfter.contains("<esc>") else {
        throw XCTSkip(
          "Esc never reached the app (\(receiptsAfter)), so hardware keys are not delivered on "
            + "this destination; Esc's dispatch is LookStripTests.escapeCancelsTheStrip.")
      }
      XCTFail(
        "Esc reached the app and left the strip up. Key receipts before Esc: "
          + "\(receiptsBefore); in the loupe: \(receiptsInLoupe); after Back: \(receiptsAfter).")
      return
    }
    let image = element(app, "loupeImage")
    XCTAssertTrue(
      waitFor(image, "label == %@", "Photograph", timeout: 15),
      "Esc did not repaint the unlooked photograph: '\(image.label)'.")
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    Thread.sleep(forTimeInterval: 2)
    XCTAssertTrue(app.buttons["loupeBack"].exists, "Esc closed the loupe.")
  }

  /// With the tag sheet over the strip, Esc belongs to the sheet: the previewed look survives.
  func testEscapeServesTheTagSheetFirst() throws {
    let app = launchIntoTheLoupe()
    openStrip(app)
    pressRightUntilWarmFilm(app)
    app.typeKey("t", modifierFlags: [])
    let sheet = app.navigationBars["Add tag"]
    XCTAssertTrue(sheet.waitForExistence(timeout: 10), "T did not open the tag sheet.")
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    Thread.sleep(forTimeInterval: 1)
    if sheet.exists { sheet.buttons["Cancel"].firstMatch.tap() }
    XCTAssertTrue(waitFor(sheet, "exists == false"), "The tag sheet did not close.")
    XCTAssertTrue(element(app, "loupeLooksStrip").exists, "Esc under the sheet cancelled Looks.")
    XCTAssertEqual(
      element(app, "loupeLookTile-warm-film").value as? String, "Selected",
      "Esc under the sheet changed the previewed look.")
  }

  /// → once, re-pressed only while nothing has moved: the first press can land before the freshly
  /// mounted loupe has registered its key commands (`SilentKeysUITests`). A key that never
  /// arrives still fails.
  private func pressRightUntilWarmFilm(_ app: XCUIApplication) {
    let warm = element(app, "loupeLookTile-warm-film")
    let none = element(app, "loupeLookTile-none")
    for _ in 0..<3 where none.value as? String == "Selected" {
      app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
      _ = waitFor(warm, "value == %@", "Selected", timeout: 3)
    }
    XCTAssertEqual(warm.value as? String, "Selected", "→ did not reach the strip's first look.")
  }
}
