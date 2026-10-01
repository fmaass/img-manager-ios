import ImgManagerAPI

/// WP29 P1 (IMGMGR-452): the grid's breadcrumb — p4128's "[breadcrumb + count]" in the bar's
/// principal slot. The title is the shoot's name (`WorkspaceTitle.name`, unchanged); the count is
/// the SERVER's `FolderNode.image_count` for that folder, taken from the tree that named it. No
/// count is ever taken from loaded pages, and a folder no tree holds gets no count at all rather
/// than a guess (plan Decision 3). ADR-0007 is not touched: the breadcrumb carries no timestamp.
struct GridBreadcrumb: Equatable, Sendable {
  /// The navigation title; hosts the title menu's "Shoot Summary" row.
  let title: String
  /// The navigation subtitle, e.g. "12 photos". Nil when no tree carries the folder.
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
    return GridBreadcrumb(title: title, subtitle: node.flatMap { countText($0.imageCount) })
  }

  /// "1 photo", "12 photos"; nil for an absent count.
  static func countText(_ count: Int?) -> String? {
    guard let count else { return nil }
    return count == 1 ? "1 photo" : "\(count) photos"
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
