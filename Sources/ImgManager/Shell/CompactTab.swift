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

  /// The Shoots tab's badge: the number of shoots awaiting review — the SAME membership the
  /// pinned section lists (`NeedsReview.members(from:)`), so the badge and the rows under it can
  /// never be two answers to one question. Zero means no badge (`.badge(0)` renders none).
  static func badgeCount(summaries: [Components.Schemas.FolderSummary]) -> Int {
    NeedsReview.members(from: summaries).count
  }
}

/// The Shoots home's second section (plan Decision 3): the queue summaries that are NOT awaiting
/// review, narrowed to the tier the title menu names, newest first. Pure, so the composition is
/// something a unit test reads rather than a `@ViewBuilder` it has to render.
enum ShootsHome {
  typealias ShootSummary = Components.Schemas.FolderSummary

  static let recentTitle = "Recent"

  static let recentSectionIdentifier = "recentSection"

  static let tierMenuIdentifier = "shootsTierMenu"

  /// Final audit F2: the title menu's Refresh row, the pull-to-refresh's visible twin.
  static let refreshMenuRowIdentifier = "shootsRefreshMenuRow"

  static func recentRowIdentifier(for folderID: Int) -> String { "recentRow-\(folderID)" }

  /// Every summary outside the Needs-review set whose tier is `tier`, most recently touched
  /// first; a shoot the server reports no `last_touched` for sorts after every dated one, and
  /// ties keep the server's order.
  static func recent(from summaries: [ShootSummary], tier: FolderTreeTier) -> [ShootSummary] {
    let members = Set(NeedsReview.members(from: summaries).map(\.folderId))
    let kept = summaries.enumerated().filter { _, summary in
      !members.contains(summary.folderId) && belongs(summary, to: tier)
    }
    let ordered = kept.sorted { lhs, rhs in
      switch (lhs.element.lastTouched, rhs.element.lastTouched) {
      case (let left?, let right?) where left != right: return left > right
      case (.some, nil): return true
      case (nil, .some): return false
      default: return lhs.offset < rhs.offset
      }
    }
    return ordered.map(\.element)
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
