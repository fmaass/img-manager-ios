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

  /// Taps a Compact search field and waits until it can take typing: the keyboard is up or the
  /// field reports keyboard focus, polled for at most 5 s, with ONE retap if it is not focused —
  /// at most 10 s in all. Returns whether focus arrived; when it never does, the failure names
  /// `name`. `typeText` into an unfocused field fails as "Neither element nor any descendant has
  /// keyboard focus" (iPhone gate on ee16fad, `CompactTabShellUITests:165`, the Search tab's
  /// field at {{88,798},{286,48}}): the tap had not handed it focus yet when typing began.
  ///
  /// - Parameters:
  ///   - tap: how to tap it; the field's own centre unless a caller needs a specific point.
  func focusForTyping(
    _ field: XCUIElement, named name: String, tap: (() -> Void)? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    let keyboard = XCUIApplication().keyboards.firstMatch
    for _ in 0..<2 {
      if let tap { tap() } else { field.tap() }
      let deadline = Date(timeIntervalSinceNow: 5)
      while Date() < deadline {
        let focused = (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
        if focused || keyboard.exists { return true }
        Thread.sleep(forTimeInterval: 0.25)
      }
    }
    XCTFail(
      "\(name) never took keyboard focus after two taps (10 s): no keyboard, and the field does "
        + "not report focus — typing into it would be lost.", file: file, line: line)
    return false
  }
}
