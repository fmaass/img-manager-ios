import Foundation
import ImgManagerAPI

/// WHICH shoots the sidebar's "Untouched" section lists — IMGMGR-549 (design R3-1, R3-2), the
/// section that replaces "Needs review".
///
/// The rule, in the record's words: Incoming-tier folders whose server flag says `untouched`,
/// dated on or after Settings › Library › "Untouched since"; never the archive; newest first.
/// Pure, so every half of it is a test over a fixture list (`UntouchedTests`).
///
/// - `untouched` is the SERVER's answer (0 picks, 0 dislikes, 0 edits and no Lightroom-side
///   signal); nothing here re-derives it from counts.
/// - The tier is `ShootsHome.belongs(_:to: .incoming)` — local storage AND the `photo_incoming/`
///   prefix — rather than `source_tier == "local"`, because the local store also holds the Edits
///   tree, which "Incoming-tier" excludes.
/// - A folder's date is the calendar day its last path segment starts with
///   (`FolderTreeModel.dayStamp(of:)`), compared as 00:00 UTC of that day against the stored
///   horizon snapped to its own UTC day. Both sides are UTC midnights, so the horizon day itself
///   is included and no time zone moves a folder across the boundary: the folder name is a
///   calendar day, never converted through Europe/Zurich (Zurich only shapes the picker,
///   `UntouchedSince`).
/// - Only shoot kinds (`ShootListFilter.shootKinds`) and dated names qualify; an undated folder
///   is never a member.
enum Untouched {

  /// The section's own name, in one place.
  static let title = "Untouched"

  /// How many rows the section shows before "N more ›" (R3-1).
  static let visibleLimit = 8

  static let sectionIdentifier = "untouchedSection"

  static let moreIdentifier = "untouchedMore"

  static let allSheetIdentifier = "untouchedAllSheet"

  static func rowIdentifier(for folderID: Int) -> String { "untouchedRow-\(folderID)" }

  static func tileIdentifier(for folderID: Int) -> String { "untouchedTile-\(folderID)" }

  /// The folder's day as 00:00 UTC, or `nil` when its last path segment starts with no valid day.
  static func day(of summary: Components.Schemas.FolderSummary) -> Date? {
    guard let stamp = FolderTreeModel.dayStamp(of: ShootName.of(summary)) else { return nil }
    return utcCalendar.date(
      from: DateComponents(year: stamp.year, month: stamp.month, day: stamp.day))
  }

  /// Whether one summary is a member against `since` (the stored `library.untouchedSince`).
  static func includes(_ summary: Components.Schemas.FolderSummary, since: Date) -> Bool {
    guard summary.untouched, ShootListFilter.shootKinds.contains(summary.kind),
      ShootsHome.belongs(summary, to: .incoming), let folderDay = day(of: summary)
    else { return false }
    return folderDay >= utcCalendar.startOfDay(for: since)
  }

  /// Every member, newest day first; members of the same day keep the server's order. The FULL
  /// membership: the section shows `visible(_:)` of it, the overflow grid all of it, and the
  /// Shoots tab's badge counts it.
  static func members(
    from summaries: [Components.Schemas.FolderSummary], since: Date
  ) -> [Components.Schemas.FolderSummary] {
    var dated: [(offset: Int, day: Date, summary: Components.Schemas.FolderSummary)] = []
    for (offset, summary) in summaries.enumerated() {
      guard includes(summary, since: since), let folderDay = day(of: summary) else { continue }
      dated.append((offset: offset, day: folderDay, summary: summary))
    }
    dated.sort { lhs, rhs in
      lhs.day != rhs.day ? lhs.day > rhs.day : lhs.offset < rhs.offset
    }
    return dated.map { $0.summary }
  }

  /// The rows the section draws: the newest `limit`.
  static func visible(
    _ members: [Components.Schemas.FolderSummary], limit: Int = visibleLimit
  ) -> [Components.Schemas.FolderSummary] {
    Array(members.prefix(max(0, limit)))
  }

  /// How many members the section does not draw.
  static func overflowCount(
    _ members: [Components.Schemas.FolderSummary], limit: Int = visibleLimit
  ) -> Int {
    max(0, members.count - max(0, limit))
  }

  /// The overflow row's text — "N more ›" — or `nil` when nothing overflows, which renders no row.
  static func overflowLabel(count: Int) -> String? {
    count > 0 ? "\(count) more ›" : nil
  }

  private static let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
  }()
}
