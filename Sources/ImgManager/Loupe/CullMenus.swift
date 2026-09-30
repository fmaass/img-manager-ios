import Foundation

/// WP30 P2 (IMGMGR-457): one verb of the Cull loupe's two menus — the bar's More and the
/// photograph's context menu. Both menus are rendered FROM the pure tables below
/// (`CullMoreMenuModel`, `LoupeContextMenuModel`), so the value a unit test pins is the menu the
/// view draws. No verb here declares a key equivalent (`ShortcutCatalog` is unchanged).
enum CullCommand: String, CaseIterable, Hashable, Sendable {
  case pick
  case dislike
  case clear
  case tag
  case share
  case lockPick
  case lockDislike
  case zoomToOneToOne
  case advanceAfterMarking

  var title: String {
    switch self {
    case .pick: "Pick"
    case .dislike: "Dislike"
    case .clear: "Clear"
    case .tag: "Tag"
    case .share: "Share"
    case .lockPick: "Lock Pick"
    case .lockDislike: "Lock Dislike"
    case .zoomToOneToOne: "Zoom to 100%"
    case .advanceAfterMarking: "Advance after marking"
    }
  }

  /// Every row carries an icon (plan Phase 2 Build). Pick, Dislike and Clear use the mark bar's
  /// own glyphs, and Share the share lane's.
  var systemImage: String {
    switch self {
    case .pick: "hand.thumbsup"
    case .dislike: "hand.thumbsdown"
    case .clear: "xmark.circle"
    case .tag: "tag"
    case .share: "square.and.arrow.up"
    case .lockPick: "lock"
    case .lockDislike: "lock.rectangle"
    case .zoomToOneToOne: "1.magnifyingglass"
    case .advanceAfterMarking: "forward.end"
    }
  }

  /// A check row: it states a mode and shows ✓ while that mode is on, rather than running a
  /// one-shot action.
  var isToggle: Bool {
    switch self {
    case .lockPick, .lockDislike, .zoomToOneToOne, .advanceAfterMarking: true
    case .pick, .dislike, .clear, .tag, .share: false
    }
  }

  /// The grid latch a Lock row switches (`GridStore.lockFromMenu`); nil for every other verb.
  var latchVerb: LatchVerb? {
    switch self {
    case .lockPick: .pick
    case .lockDislike: .dislike
    default: nil
    }
  }

  /// The verdict a mark row writes through the loupe's own mark path (`applyLoupeMark`).
  var markState: MarkStateValue? {
    switch self {
    case .pick: MarkStateValue.pick
    case .dislike: MarkStateValue.dislike
    case .clear: MarkStateValue.none
    default: nil
    }
  }
}

/// One section of the loupe's More.
struct CullMoreMenuSection: Identifiable, Equatable, Sendable {
  /// Stable and unique — the menu `ForEach`'s identity, never an index (IMGMGR-210).
  let id: String
  let commands: [CullCommand]
}

/// The loupe's More (p4128 D4, IMGMGR-457): two sections, six rows, an icon on every row —
/// Share · Tag · Lock Pick · Lock Dislike | Zoom to 100% ✓ · Advance after marking ✓.
///
/// "Open in Lightroom-ready view" is NOT here: owner decision D-a (IMGMGR-457 comment 9718)
/// dropped it. The two Lock rows are plain rows rather than an in-menu `ControlGroup` palette:
/// a palette draws icons without the ✓ the rows must show, and the plan's own fallback is "else
/// two rows".
enum CullMoreMenuModel {
  static let sections: [CullMoreMenuSection] = [
    CullMoreMenuSection(id: "actions", commands: [.share, .tag, .lockPick, .lockDislike]),
    CullMoreMenuSection(id: "view", commands: [.zoomToOneToOne, .advanceAfterMarking]),
  ]

  /// Every row, in menu order — derived from the sections, never a second list.
  static var rows: [CullCommand] { sections.flatMap(\.commands) }

  /// Share keeps `loupeShare`, the identifier it has carried since IMGMGR-348; every other row
  /// is `loupeMore.<verb>`.
  static func accessibilityIdentifier(for command: CullCommand) -> String {
    command == .share ? "loupeShare" : "loupeMore.\(command.rawValue)"
  }
}

/// A submenu of the photograph's context menu: one level down, never further.
struct LoupeContextSubmenu: Equatable, Sendable {
  let title: String
  let systemImage: String
  let accessibilityIdentifier: String
  let commands: [CullCommand]
}

/// One entry of a context-menu group.
enum LoupeContextMenuNode: Identifiable, Equatable, Sendable {
  case command(CullCommand)
  case submenu(LoupeContextSubmenu)

  var id: String {
    switch self {
    case .command(let command): LoupeContextMenuModel.accessibilityIdentifier(for: command)
    case .submenu(let submenu): submenu.accessibilityIdentifier
    }
  }

  var title: String {
    switch self {
    case .command(let command): command.title
    case .submenu(let submenu): submenu.title
    }
  }
}

/// One group of the context menu (a `Section`, drawn with a separator).
struct LoupeContextMenuGroup: Identifiable, Equatable, Sendable {
  let id: String
  let nodes: [LoupeContextMenuNode]
}

/// The photograph's context menu (`.contextMenu` on the loupe image): [Pick, Dislike, Clear] |
/// [Tag, Share] | [Lock ▸ Lock Pick, Lock Dislike] — three groups, depth two (the kickoff's
/// "≤ 6 rows per touch menu, depth ≤ 2").
enum LoupeContextMenuModel {
  static let lock = LoupeContextSubmenu(
    title: "Lock", systemImage: "lock", accessibilityIdentifier: "loupeContext.lock",
    commands: [.lockPick, .lockDislike])

  static let groups: [LoupeContextMenuGroup] = [
    LoupeContextMenuGroup(
      id: "marks", nodes: [.command(.pick), .command(.dislike), .command(.clear)]),
    LoupeContextMenuGroup(id: "photo", nodes: [.command(.tag), .command(.share)]),
    LoupeContextMenuGroup(id: "lock", nodes: [.submenu(lock)]),
  ]

  /// Levels of menu the reader walks: 1 for a flat menu, 2 once any entry is a submenu. A
  /// submenu holds commands only, so it can never be deeper than that.
  static var depth: Int {
    let hasSubmenu = groups.flatMap(\.nodes).contains {
      if case .submenu = $0 { return true }
      return false
    }
    return hasSubmenu ? 2 : 1
  }

  /// The top level, as the reader sees it on a long press.
  static var topLevelTitles: [String] { groups.flatMap(\.nodes).map(\.title) }

  static func accessibilityIdentifier(for command: CullCommand) -> String {
    "loupeContext.\(command.rawValue)"
  }
}

/// The Lock rows are the GRID's latch (`GridStore.lockFromMenu` → `pickLock.forceLatch`), a mode
/// that takes no image id and drives grid tap-to-mark; `applyLoupeMark` never reads it. ✓ while
/// the row's verb is latched; selecting a latched row unlatches it; the OTHER verb's row is
/// inert while a lock is on — the same mutual exclusion the grid's long-press command makes
/// visible by disabling itself.
enum CullLockRow {
  enum Action: Equatable, Sendable {
    case latch
    case unlatch
  }

  /// What selecting the row does; nil while the other verb holds the latch (the row disables).
  static func action(for verb: LatchVerb, latchedVerb: LatchVerb?) -> Action? {
    switch latchedVerb {
    case nil: .latch
    case verb?: .unlatch
    default: nil
    }
  }

  static func isChecked(_ verb: LatchVerb, latchedVerb: LatchVerb?) -> Bool {
    latchedVerb == verb
  }
}

/// Zoom to 100%: ✓ while the photograph shows 1:1 against the proxy — the same rounding the
/// photograph's own spoken value uses (`LoupeZoomState.accessibilityValue`), so the row and the
/// reading cannot disagree. Selecting it runs the loupe's ONE zoom toggle (`zoomToggleAction`).
enum CullZoomRow {
  static func isAtOneToOne(_ zoom: LoupeZoomState) -> Bool {
    guard zoom.isZoomed, zoom.oneToOneScale > 0 else { return false }
    return Int((zoom.scale / zoom.oneToOneScale * 100).rounded()) >= 100
  }
}

/// Where tag entry (`TagEntrySheet`, raised by `GridStore.isTagEntryPresented`) is hosted. The
/// grid hosts it while it is on screen; while the loupe is open the LOUPE does — the docked
/// Regular loupe replaces the grid (`WorkspaceContent`), and the Compact loupe is a full-screen
/// cover over it, so a grid-hosted sheet could not present in either. Exactly one host answers
/// true for any state, so the sheet is never presented twice.
enum TagEntryHost: CaseIterable, Sendable {
  case grid
  case loupe

  func presents(isTagEntryPresented: Bool, isLoupeOpen: Bool) -> Bool {
    guard isTagEntryPresented else { return false }
    switch self {
    case .grid: return !isLoupeOpen
    case .loupe: return isLoupeOpen
    }
  }
}

extension GridStore {
  /// The loupe's Lock rows: latch through the grid's own menu command, or unlatch a latched
  /// verb. Inert while the other verb is latched (`CullLockRow.action`).
  func toggleLockFromLoupe(_ verb: LatchVerb) {
    switch CullLockRow.action(for: verb, latchedVerb: pickLock.latchedVerb) {
    case .latch: lockFromMenu(verb)
    case .unlatch: pickLock.unlatch()
    case nil: break
    }
  }

  /// Whether `host` presents tag entry right now (`TagEntryHost`).
  func presentsTagEntry(on host: TagEntryHost) -> Bool {
    host.presents(isTagEntryPresented: isTagEntryPresented, isLoupeOpen: isLoupeOpen)
  }
}
