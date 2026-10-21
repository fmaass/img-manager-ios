import ImgManagerAPI

/// WP28 P3 (IMGMGR-450): the grid's navigation title — the selected folder's display name, which
/// hosts the title menu's "Shoot Summary" row (plan Decision 1). The design record p4128
/// ("Content = Grid") puts a breadcrumb plus a count in that principal slot; this phase ships
/// only the name, and the breadcrumb and count are NOT here.
///
/// No new naming rule: the name is whatever the reader already sees for that folder in the
/// sidebar — the tree row's own `node.name` (`FolderTreeSection`'s folder row), from the mounted
/// tree or, before it mounts, the tree the queue store last remembered (`QueueStore.cachedTree`),
/// and, for a folder neither tree holds, the summary-backed section row's
/// `ShootName.of(_:)` (the queue card's derivation, `ShootName.swift`).
///
/// A shown folder ALWAYS has a title, because the title hosts the Summary entry: a cold restore
/// or launch pushes the grid before the Library tab's tree ever mounts, and a folder nobody names
/// yet then takes the neutral `fallback` until a tree load names it. No folder ⇒ nil, no title.
enum WorkspaceTitle {
  static let fallback = "Shoot"

  static func name(
    folderID: Int?, treeFolders: [FolderTreeTier: [Components.Schemas.FolderNode]],
    cachedTreeFolders: [FolderTreeTier: [Components.Schemas.FolderNode]]?,
    summaries: [Components.Schemas.FolderSummary]
  ) -> String? {
    guard let folderID else { return nil }
    for folders in treeFolders.values {
      if let node = folders.first(where: { $0.id == folderID }) { return node.name }
    }
    for folders in (cachedTreeFolders ?? [:]).values {
      if let node = folders.first(where: { $0.id == folderID }) { return node.name }
    }
    if let summary = summaries.first(where: { $0.folderId == folderID }) {
      return ShootName.of(summary)
    }
    return fallback
  }
}
