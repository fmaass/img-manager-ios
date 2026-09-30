import UIKit
import XCTest

/// WP28 P4 (IMGMGR-451): the chrome touch-target census, shared by `ChromeTouchTargetUITests`
/// (the shell's resting states) and `MaterialsScreenshotUITests` (the states only the materials
/// matrix reaches: search active, the select bar, the inspector and summary sheets, Regular-2).
///
/// One row per control-type element (button, menu, pop-up, search field, toggle, segmented
/// control, link) with a non-empty frame inside the window, found by snapshotting every
/// navigation bar, toolbar and tab bar. Below 28 pt in either dimension is a FAIL for an
/// app-owned control and a WATCH for a system-owned one; below 44 pt is a WATCH.
struct ChromeTargetRow {
  static let failBelow: CGFloat = 28
  static let watchBelow: CGFloat = 44

  let state: String
  let source: String
  let identifier: String
  let label: String
  let elementType: XCUIElement.ElementType
  /// Nil for an app-owned control; the closed-list reason for a system-owned one.
  let systemReason: String?
  let size: CGSize

  var name: String { identifier.isEmpty ? "label=\"\(label)\"" : identifier }

  var verdict: String {
    let side = min(size.width, size.height)
    if side < Self.failBelow { return systemReason == nil ? "FAIL" : "WATCH" }
    return side < Self.watchBelow ? "WATCH" : "OK"
  }

  /// `key` is an identifier or a label; `a|b` accepts either. "Info" also matches the badged
  /// label ("Info, 1 filter active"); `ChromeOwnership.searchFieldKey` matches by element type.
  func matches(_ key: String) -> Bool {
    key.split(separator: "|").contains { alternative in
      let key = String(alternative)
      if key == ChromeOwnership.searchFieldKey { return elementType == .searchField }
      if key == "Info" && label.hasPrefix("Info") { return true }
      if key == "Info" && identifier == "inspectorChromeButton" { return true }
      return identifier == key || label == key
    }
  }
}

/// Who owns a control, decided by identifier FIRST.
///
/// 1. An identifier in the app's namespace — every `.accessibilityIdentifier` this app sets
///    starts with a lowercase ASCII letter (`gridMoreMenu`, `tab.search`, `shootSummaryDone`) —
///    is ALWAYS app-owned, whatever its label, type or bar. An app control that reuses a system
///    label ("More", "Search", "stub, Actions Menu") is judged against the 28 pt floor.
/// 2. Otherwise the control is system-owned ONLY when it matches this closed list: the
///    identifiers `BackButton` and `ToggleSidebar`; a button in a tab bar; a search field or
///    anything inside one; the navigation title menu (`toolbarTitleMenu`) — ONLY in a state the
///    census declares as carrying one, and only for a navigation-bar button with no identifier
///    that sits in no other control and whose label ends with ", Actions Menu" (the suffix the
///    system generates), is exactly a fixture title or the workspace's neutral fallback title
///    (the bare form the gate on bd47740 showed at Regular-3 with the inspector shown), or is
///    exactly the declared state's OWN title (`stateTitles`: the Compact Shoots root read bare
///    "Shoots" on one gate of c71718c and "Shoots, Actions Menu" on another — the system's
///    label for the same trigger varies).
/// 3. Everything else is app-owned. A label alone never makes a control the system's.
enum ChromeOwnership {
  static let titleMenuReason = "system navigation title menu"
  static let searchFieldKey = "<searchField>"

  static func isAppIdentifier(_ identifier: String) -> Bool {
    guard let first = identifier.unicodeScalars.first else { return false }
    return first.value >= 0x61 && first.value <= 0x7A
  }

  static func systemOwner(
    identifier: String, label: String, type: XCUIElement.ElementType, container: String,
    insideSearch: Bool, insideControl: Bool = false, titleMenu: Bool = false,
    stateTitles: [String] = []
  ) -> String? {
    if isAppIdentifier(identifier) { return nil }
    if identifier == "BackButton" { return "system back button" }
    if identifier == "ToggleSidebar" { return "system sidebar toggle" }
    if container == "tabBar" && type == .button { return "system tab bar button" }
    if type == .searchField || insideSearch { return "system search field" }
    let titleShaped =
      label.hasSuffix(", Actions Menu")
      || XCTestCase.isTitleMenuLabel(label, names: XCTestCase.materialsFolderOneNames)
      || label == XCTestCase.workspaceFallbackTitle || stateTitles.contains(label)
    if titleMenu && container == "navigationBar" && type == .button && identifier.isEmpty
      && !insideControl && titleShaped
    {
      return titleMenuReason
    }
    return nil
  }
}

/// What one bar's walk carries down the tree.
private struct CensusWalk {
  let state: String
  let bar: String
  let window: CGRect
  let titleMenu: Bool
  let stateTitles: [String]
}

extension XCTestCase {

  private static var censusControlTypes: Set<XCUIElement.ElementType> {
    [.button, .menuButton, .popUpButton, .searchField, .toggle, .segmentedControl, .link]
  }

  /// The census of one surface state. Every navigation bar, toolbar and tab bar on screen is
  /// snapshotted (a snapshot is main-actor work, hence the isolation) and each must hold at
  /// least one counted control, unless it holds nothing but text (a title-only bar, reported
  /// as `title-only`). `alsoMeasure` adds controls that live in the content rather than in a
  /// system bar, each measured unless a bar row already matches its key, and each required.
  /// Every key in `required` must match a row. `titleMenu` declares that this state carries a
  /// `toolbarTitleMenu`; only then can a control be the system title menu (`ChromeOwnership`).
  /// `stateTitles` names that state's own navigation title, which the trigger may carry bare.
  /// Problems are RETURNED, not failed, so a caller can print every row before it fails
  /// (`reportChromeTargets`).
  @MainActor
  func chromeCensus(
    _ app: XCUIApplication, state: String, titleMenu: Bool = false,
    stateTitles: [String] = [], requiring required: [String] = [],
    alsoMeasure extras: [(key: String, element: XCUIElement)] = []
  ) -> (rows: [ChromeTargetRow], problems: [String]) {
    let window = app.windows.firstMatch.frame
    let bars: [(kind: String, query: XCUIElementQuery)] = [
      ("navigationBar", app.navigationBars),
      ("toolbar", app.toolbars),
      ("tabBar", app.tabBars),
    ]
    var rows: [ChromeTargetRow] = []
    var problems: [String] = []
    for bar in bars {
      for (index, element) in bar.query.allElementsBoundByIndex.enumerated() {
        let snapshot: any XCUIElementSnapshot
        do {
          snapshot = try element.snapshot()
        } catch {
          problems.append("\(state): the \(bar.kind) #\(index) snapshot failed: \(error)")
          continue
        }
        guard !snapshot.frame.isEmpty, window.intersects(snapshot.frame) else { continue }
        let before = rows.count
        let walk = CensusWalk(
          state: state, bar: bar.kind, window: window, titleMenu: titleMenu,
          stateTitles: stateTitles)
        collectControls(snapshot, walk, insideSearch: false, insideControl: false, into: &rows)
        let line = "TOUCH-TARGET BAR \(state) \(bar.kind)#\(index) controls=\(rows.count - before)"
        if rows.count > before {
          print(line)
        } else if Self.holdsOnlyText(snapshot) {
          print("\(line) title-only")
        } else {
          problems.append(
            "\(line): a bar on screen with no counted control; it holds "
              + "\(Self.elementTypes(snapshot)) — the census does not reach it.")
        }
      }
    }
    for extra in extras where !rows.contains(where: { $0.matches(extra.key) }) {
      guard extra.element.waitForExistence(timeout: 10) else {
        problems.append("\(state): \(extra.key) is not on screen, so it cannot be measured.")
        continue
      }
      let element = extra.element
      rows.append(
        ChromeTargetRow(
          state: state, source: "content", identifier: element.identifier,
          label: element.label, elementType: element.elementType,
          systemReason: ChromeOwnership.systemOwner(
            identifier: element.identifier, label: element.label, type: element.elementType,
            container: "content", insideSearch: false),
          size: element.frame.size))
    }
    if rows.isEmpty { problems.append("\(state): no control counted at all.") }
    for key in required where !rows.contains(where: { $0.matches(key) }) {
      problems.append(
        "\(state): \(key) is not among the \(rows.count) controls counted — the census does "
          + "not reach the bars it claims to cover.")
    }
    return (rows, problems)
  }

  @MainActor
  private func collectControls(
    _ node: any XCUIElementSnapshot, _ walk: CensusWalk, insideSearch: Bool, insideControl: Bool,
    into rows: inout [ChromeTargetRow]
  ) {
    let isControl = Self.censusControlTypes.contains(node.elementType)
    if isControl, !node.frame.isEmpty, walk.window.intersects(node.frame) {
      rows.append(
        ChromeTargetRow(
          state: walk.state, source: walk.bar, identifier: node.identifier, label: node.label,
          elementType: node.elementType,
          systemReason: ChromeOwnership.systemOwner(
            identifier: node.identifier, label: node.label, type: node.elementType,
            container: walk.bar, insideSearch: insideSearch, insideControl: insideControl,
            titleMenu: walk.titleMenu, stateTitles: walk.stateTitles),
          size: node.frame.size))
    }
    let search = insideSearch || node.elementType == .searchField
    for child in node.children {
      collectControls(
        child, walk, insideSearch: search, insideControl: insideControl || isControl, into: &rows)
    }
  }

  /// A title-only bar: nothing but `other` and `staticText` below it, and at least one
  /// non-empty text. An empty bar, or one holding only empty containers, is not title-only.
  @MainActor
  private static func holdsOnlyText(_ node: any XCUIElementSnapshot) -> Bool {
    var queue = node.children
    var text = false
    while let next = queue.popLast() {
      switch next.elementType {
      case .staticText:
        text = text || !next.label.isEmpty
      case .other:
        break
      default:
        return false
      }
      queue += next.children
    }
    return text
  }

  @MainActor
  private static func elementTypes(_ node: any XCUIElementSnapshot) -> [UInt] {
    var types: Set<UInt> = []
    var queue = node.children
    while let next = queue.popLast() {
      types.insert(next.elementType.rawValue)
      queue += next.children
    }
    return types.sorted()
  }

  /// Prints EVERY row as a `TOUCH-TARGET` line and a `CENSUS` summary, attaches them as
  /// `touch-targets-<name>`, and only then fails — once, naming each FAIL row and each census
  /// problem — so a matrix that stops on its first failure still logs the whole state. With
  /// `failNow: false` it only returns those failures, for the caller to assert later.
  @MainActor
  @discardableResult
  func reportChromeTargets(
    _ rows: [ChromeTargetRow], problems: [String], name: String, failNow: Bool = true
  ) -> [String] {
    var lines: [String] = []
    for row in rows {
      let owner = row.systemReason.map { "system(\($0))" } ?? "app"
      let size = String(format: "%.1f x %.1f pt", row.size.width, row.size.height)
      lines.append(
        "TOUCH-TARGET \(row.verdict) \(name)/\(row.state) owner=\(owner) "
          + "\(row.source)/\(row.name) \(size)")
    }
    let system = rows.filter { $0.systemReason != nil }.count
    let failing = lines.filter { $0.hasPrefix("TOUCH-TARGET FAIL ") }
    lines.append(
      "TOUCH-TARGET CENSUS \(name) controls=\(rows.count) app=\(rows.count - system) "
        + "system=\(system) fail=\(failing.count) "
        + "watch=\(rows.filter { $0.verdict == "WATCH" }.count) problems=\(problems.count)")
    lines += problems.map { "TOUCH-TARGET PROBLEM \($0)" }
    for line in lines { print(line) }
    let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
    attachment.name = "touch-targets-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
    var failures = failing.map { "\($0) — an app-owned control below the 28 × 28 pt floor." }
    failures += problems.map { "TOUCH-TARGET census \($0)" }
    if failNow && !failures.isEmpty { XCTFail(failures.joined(separator: "\n")) }
    return failures
  }
}
