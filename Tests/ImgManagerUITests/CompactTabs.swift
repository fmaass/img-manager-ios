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

  /// The tab bar's button titled `title` (Shoots, Library), addressed by LABEL inside the
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
  ///
  /// Both handles are identifiers, never positions: every caller passes the tier's label
  /// (`folderTreeTier-<label>`) and a child keyed by the server's folder id (`folderRow-<id>`,
  /// `FolderTreeRowPresentation.rowIdentifier`), so a reordered tree changes nothing here
  /// (IMGMGR-500).
  ///
  /// IMGMGR-500 AC1, recorded: the two-tap goal is MET for Incoming and the Shoots tab — owner
  /// ruling of 2026-10-02 on IMGMGR-500 comment 10234: only Incoming auto-opens at Compact (its
  /// shoots are two taps from Triage), and dated shoots filed under year/month are reached
  /// through the Shoots tab, not by auto-opening more of the tree.
  func openTreeTier(_ tier: XCUIElement, showing child: XCUIElement) {
    if !child.exists { tier.tap() }
  }
}

/// The Compact tabs' titles — the app's `CompactTab.title` (`Shell/CompactTab.swift`), spelled
/// ONCE here because a UI-test bundle runs out of process and cannot import the app module.
enum CompactTabTitle {
  static let shoots = "Shoots"
  static let library = "Library"
}
