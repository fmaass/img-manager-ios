import XCTest

/// WP28 P1 (IMGMGR-448): reaching the Compact tab shell from a UI test.
///
/// Whether the shell is on screen is read off the SCREEN — the window's width — never off the
/// device idiom, for the same reason the app decides it that way (`LayoutResolver`; the
/// idiom-grep leg scans `Tests/` too). The ceiling sits between the iPhone destination's portrait
/// width (402 pt) and the iPad destination's narrowest full-screen width (1032 pt), so it is
/// meant for the portrait-pinned classes that use it (`OrientationPinnedUITestCase`'s default).
extension XCTestCase {
  static var compactShellWidthCeiling: CGFloat { 700 }

  func rendersCompactShell(_ app: XCUIApplication) -> Bool {
    let window = app.windows.firstMatch
    _ = window.waitForExistence(timeout: 30)
    return window.frame.width < Self.compactShellWidthCeiling
  }

  /// The tab bar's button titled `title` (Shoots, Library, Search), addressed by LABEL inside the
  /// system tab bar. On iOS 26.5 the system tab buttons do not carry the SwiftUI tab ids: as
  /// measured on gate run 2 (08367cc), `.accessibilityIdentifier` on a `Tab`'s label never
  /// reaches the tab button and the `tab.*` identifiers matched nothing. That is why every tab
  /// here is addressed by label; the identifiers stay in `CompactTab` and are not relied on.
  func compactTabButton(_ app: XCUIApplication, title: String) -> XCUIElement {
    app.tabBars.firstMatch.buttons[title].firstMatch
  }

  func selectCompactTab(
    _ app: XCUIApplication, title: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let button = compactTabButton(app, title: title)
    XCTAssertTrue(
      button.waitForExistence(timeout: 15),
      "The Compact tab bar carries no \(title) tab.", file: file, line: line)
    button.tap()
  }

  /// At Compact the folder tree is the Library tab's (the launch tab is Shoots); at Regular it
  /// is the split's sidebar and this does nothing.
  func showLibraryIfCompact(
    _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard rendersCompactShell(app) else { return }
    selectCompactTab(app, title: "Library", file: file, line: line)
  }

  /// IMGMGR-462 (WP31 P3): opens a tree tier the way the tree walks always have — a tap on its
  /// label — but only while `child`, a row that tier shows once open, is absent. At Compact the
  /// Library tab now launches with Incoming already OPEN (`FolderTreeState.compactLaunchTiers`),
  /// where an unconditional tap would CLOSE it; at Regular every tier still launches closed and
  /// this taps exactly as before. The row's presence is the read because the system
  /// `DisclosureGroup` label publishes no open/closed state of its own. The app applies the
  /// opening in the same main-actor turn that publishes the rows, so a tier label on screen
  /// already carries its launch state when this reads it.
  func openTreeTier(_ tier: XCUIElement, showing child: XCUIElement) {
    if !child.exists { tier.tap() }
  }

  /// Taps a search field and returns once THIS field provably takes typing: the keyboard is up,
  /// and a probe character typed at the app level changes this field's own value (it is deleted
  /// again straight away). `typeText` into an unfocused field fails as "Neither element nor any
  /// descendant has keyboard focus" (iPhone gate on ee16fad, `CompactTabShellUITests:165`, the
  /// Search tab's field at {{88,798},{286,48}}): the tap had not handed it focus yet when typing
  /// began — and a keyboard that is up for some OTHER field would not have caught that, which is
  /// why the probe reads this field's value instead (the shape of P2's
  /// `expandRegularToolbarSearch`). No private or KVC attribute is read.
  ///
  /// ONE deadline of 10 s covers the whole call: the first tap, the wait for the keyboard, the
  /// probe, and at most one re-tap when the first did not take. Every check here is an XCUITest
  /// snapshot query that can itself take a second or more on a loaded host, and the probe types
  /// two keys, so a call that fails can overrun the deadline by that last query and probe — a few
  /// seconds — but it never starts a new tap, a new wait or the probe after the deadline.
  ///
  /// The probe is typed through the APP, not the field: an app-level `typeText` lands wherever
  /// focus is and records no failure, so a probe that went elsewhere is observed (this field's
  /// value did not gain exactly one "q") and taken back (the delete lands where the probe did,
  /// and the field must read as before it — a probe left behind is a failure too).
  ///
  /// - Parameters:
  ///   - tap: how to tap it; the field's own centre unless a caller needs a specific point.
  /// - Returns: whether the field took the probe; when it never does, the failure names `name`.
  func focusForTyping(
    _ field: XCUIElement, named name: String, tap: (() -> Void)? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    let app = XCUIApplication()
    let keyboard = app.keyboards.firstMatch
    let deadline = Date(timeIntervalSinceNow: 10)
    var taps = 0
    var reading = "no tap"
    while taps < 2 && Date() < deadline {
      if let tap { tap() } else { field.tap() }
      taps += 1
      // The first tap may use half of what is left; the re-tap gets the rest.
      let remaining = deadline.timeIntervalSinceNow
      let waitUntil = Date(timeIntervalSinceNow: taps == 1 ? remaining / 2 : remaining)
      var keyboardUp = keyboard.exists
      while !keyboardUp && Date() < waitUntil {
        Thread.sleep(forTimeInterval: 0.25)
        keyboardUp = keyboard.exists
      }
      guard keyboardUp else {
        reading = "tap \(taps): no keyboard"
        continue
      }
      guard Date() < deadline else {
        reading = "tap \(taps): the keyboard came up after the deadline; no probe typed"
        break
      }
      let before = searchFieldText(field)
      app.typeText("q")
      let after = searchFieldText(field)
      app.typeText(XCUIKeyboardKey.delete.rawValue)
      let took = after.filter { $0 == "q" }.count == before.filter { $0 == "q" }.count + 1
      guard took else {
        reading = "tap \(taps): keyboard up, but the probe left the field at \"\(after)\""
        continue
      }
      let restored = searchFieldText(field)
      if restored == before { return true }
      XCTFail(
        "\(name) took the probe but did not give it back: \"\(before)\" became \"\(restored)\".",
        file: file, line: line)
      return false
    }
    XCTFail(
      "\(name) did not take typing within one 10 s deadline (\(taps) tap(s); last: \(reading)) — "
        + "typing into it would be lost.", file: file, line: line)
    return false
  }
}

/// The Compact tabs' titles — the app's `CompactTab.title` (`Shell/CompactTab.swift`), spelled
/// ONCE here because a UI-test bundle runs out of process and cannot import the app module.
enum CompactTabTitle {
  static let shoots = "Shoots"
  static let library = "Library"
  static let search = "Search"
}
