import Foundation
import ImgManagerAPI

/// WP28 P1 (IMGMGR-448): the tabs of the Compact shell (p4128 D3) — declared here as a value,
/// rendered by `CompactShell`. R3-18 (IMGMGR-550) removed the Search tab: two tabs remain.
/// Nothing persists a tab, so no stored value can name the removed case. "Compact" is the
/// `.compact` layout mode, never a device: an iPad in a narrow Split View gets these tabs too,
/// because `LayoutResolver` decides by width and size class alone.
enum CompactTab: String, CaseIterable, Hashable, Sendable {
  case shoots
  case library

  /// The tab bar button's accessibility identifier — what the UI tests address.
  var identifier: String { "tab.\(rawValue)" }

  var title: String {
    switch self {
    case .shoots: return "Shoots"
    case .library: return "Library"
    }
  }

  var systemImage: String {
    switch self {
    case .shoots: return "photo.on.rectangle.angled"
    case .library: return "folder"
    }
  }

  /// The Shoots tab's badge (IMGMGR-549 ruling d): the number of Untouched shoots — the FULL
  /// membership the Shoots tab's Untouched section draws its first eight rows from
  /// (`Untouched.members(from:since:)`), overflow included, so the badge and the rows under it
  /// can never be two answers to one question. The readiness count is no longer surfaced. Zero
  /// means no badge (`.badge(0)` renders none).
  static func badgeCount(summaries: [Components.Schemas.FolderSummary], since: Date) -> Int {
    Untouched.members(from: summaries, since: since).count
  }
}

/// The Shoots home's Recent section (IMGMGR-549, R3-2): the shoots last opened on THIS device
/// (`ShootShortcutsStore.recent`), narrowed to the tier the title menu's "Recent from" picker
/// names (ruling e). Pure, so the composition is something a unit test reads rather than a
/// `@ViewBuilder` it has to render.
enum ShootsHome {
  typealias ShootSummary = Components.Schemas.FolderSummary

  static let recentTitle = "Recent"

  static let recentSectionIdentifier = "recentSection"

  static let tierMenuIdentifier = "shootsTierMenu"

  /// Final audit F2: the title menu's Refresh row, the pull-to-refresh's visible twin.
  static let refreshMenuRowIdentifier = "shootsRefreshMenuRow"

  static func recentRowIdentifier(for folderID: Int) -> String { "recentRow-\(folderID)" }

  /// The title menu's picker label: it scopes Recent and nothing else.
  static let recentPickerTitle = "Recent from"

  /// The remembered opens as summaries, newest first, keeping only those in `tier`. An entry
  /// whose summary is not served right now is kept by the store and not drawn here.
  static func recent(
    entries: [ShootShortcutsStore.Entry], summaries: [ShootSummary], tier: FolderTreeTier
  ) -> [ShootSummary] {
    ShootRowPresentation.summaries(for: entries, in: summaries).filter { belongs($0, to: tier) }
  }

  /// Which tree tier a summary sits in: Archive is the archive source tier; Incoming and Edits
  /// share the local store and are told apart by the path prefix the tree itself uses
  /// (`FolderTreeTier.treePrefix`). A summary with an unknown source tier belongs to none.
  static func belongs(_ summary: ShootSummary, to tier: FolderTreeTier) -> Bool {
    guard let source = GridSourceTier(rawValue: summary.sourceTier) else { return false }
    guard source == tier.sourceTier else { return false }
    guard let prefix = tier.treePrefix else { return true }
    return summary.path == prefix || summary.path.hasPrefix(prefix + "/")
  }
}
