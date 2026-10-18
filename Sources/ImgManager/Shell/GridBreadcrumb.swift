import Foundation
import ImgManagerAPI

/// WP29 P1 (IMGMGR-452): the grid's breadcrumb — p4128's "[breadcrumb + count]" in the bar's
/// principal slot. The title is the shoot's name (`WorkspaceTitle.name`, unchanged); the count is
/// the SERVER's `FolderNode.image_count` for that folder, taken from the tree that named it. No
/// count is ever taken from loaded pages, and a folder no tree holds gets no count at all rather
/// than a guess (plan Decision 3). ADR-0007 is not touched: the breadcrumb carries no timestamp.
struct GridBreadcrumb: Equatable, Sendable {
  /// The navigation title; hosts the title menu's "Shoot Summary" row.
  let title: String
  /// The navigation subtitle, e.g. "184 photos · 23 picks · 12 edited" (R3-11). Nil when no tree
  /// carries the folder.
  let subtitle: String?

  /// Nil exactly when `WorkspaceTitle.name` is nil — no folder shown, no title.
  static func make(
    folderID: Int?, treeFolders: [FolderTreeTier: [Components.Schemas.FolderNode]],
    cachedTreeFolders: [FolderTreeTier: [Components.Schemas.FolderNode]]?,
    summaries: [Components.Schemas.FolderSummary]
  ) -> GridBreadcrumb? {
    guard
      let title = WorkspaceTitle.name(
        folderID: folderID, treeFolders: treeFolders, cachedTreeFolders: cachedTreeFolders,
        summaries: summaries)
    else { return nil }
    let node = folderID.flatMap { id in
      Self.node(id, in: treeFolders) ?? Self.node(id, in: cachedTreeFolders ?? [:])
    }
    let summary = folderID.flatMap { id in summaries.first(where: { $0.folderId == id }) }
    // `untouched` is P1's field and not in the vendored contract yet: deriving it here would
    // be a second, contradicting signal, so production passes nil until P8 re-vendors it and
    // P10 wires it.
    let subtitle = Self.subtitle(
      photoCount: node.flatMap { $0.imageCount }, summary: summary, untouched: nil)
    return GridBreadcrumb(title: title, subtitle: subtitle)
  }

  /// R3-11: the subtitle of counts — "184 photos · 23 picks · 12 edited", "1,726 photos ·
  /// untouched", "… · 12 marks not in Lightroom". The photo count is the tree's `image_count`;
  /// every other segment is a decided count from the folder's summary, shown only when it is
  /// non-zero. An unmarked, undecided or dislike count is NEVER stated: no mark is the default.
  /// "Not in Lightroom" counts the marks a sync would still write (`never` + `stale`); `refused`
  /// is the writer declining, which a sync cannot do, so it is not announced here.
  /// Nil without a photo count; just the photo count without a summary.
  static func subtitle(
    photoCount: Int?, summary: Components.Schemas.FolderSummary?, untouched: Bool?
  ) -> String? {
    guard let photos = countText(photoCount) else { return nil }
    var segments = [photos]
    if let summary {
      if summary.picked > 0 {
        segments.append(counted(summary.picked, "pick", "picks"))
      }
      if summary.edited > 0 {
        segments.append("\(grouped(summary.edited)) edited")
      }
    }
    if untouched == true {
      segments.append("untouched")
    }
    if let notInLightroom = notInLightroomText(summary) {
      segments.append(notInLightroom)
    }
    return segments.joined(separator: " · ")
  }

  /// The "N marks not in Lightroom" segment; nil when there are none.
  static func notInLightroomText(_ summary: Components.Schemas.FolderSummary?) -> String? {
    let count = (summary?.sync?.never ?? 0) + (summary?.sync?.stale ?? 0)
    guard count > 0 else { return nil }
    return counted(count, "mark not in Lightroom", "marks not in Lightroom")
  }

  /// "1 photo", "12 photos", "1,726 photos"; nil for an absent count.
  static func countText(_ count: Int?) -> String? {
    guard let count else { return nil }
    return counted(count, "photo", "photos")
  }

  private static func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(grouped(count)) \(count == 1 ? singular : plural)"
  }

  /// Grouped digits in a FIXED locale: the UI is English, and the count must not change shape
  /// with the device's region ("1,726").
  private static func grouped(_ count: Int) -> String {
    count.formatted(.number.locale(Locale(identifier: "en_US")))
  }

  /// WP31 P1 (IMGMGR-460): the same server count the subtitle states, as a number — Triage's
  /// "i of N". Nil when no tree carries the folder.
  static func imageCount(
    folderID: Int?, treeFolders: [FolderTreeTier: [Components.Schemas.FolderNode]],
    cachedTreeFolders: [FolderTreeTier: [Components.Schemas.FolderNode]]?
  ) -> Int? {
    guard let folderID else { return nil }
    let node =
      Self.node(folderID, in: treeFolders) ?? Self.node(folderID, in: cachedTreeFolders ?? [:])
    return node.flatMap { $0.imageCount }
  }

  private static func node(
    _ id: Int, in folders: [FolderTreeTier: [Components.Schemas.FolderNode]]
  ) -> Components.Schemas.FolderNode? {
    for tier in folders.values {
      if let node = tier.first(where: { $0.id == id }) { return node }
    }
    return nil
  }
}
