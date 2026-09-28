import ImgManagerAPI

/// WP28 P3 (IMGMGR-450): the grid's navigation title — the selected folder's display name, which
/// hosts the title menu's "Shoot Summary" row (plan Decision 1). The design record p4128
/// ("Content = Grid") puts a breadcrumb plus a count in that principal slot; this phase ships
/// only the name, and the breadcrumb and count are NOT here.
///
/// No new naming rule: the name is whatever the reader already sees for that folder in the
/// sidebar — the tree row's own `node.name` (`FolderTreeSection`'s folder row), and, for a
/// folder the tree has not loaded, the pinned Needs-review row's `NeedsReview.shootName(for:)`
/// (the queue card's derivation, `NeedsReviewSection.swift`). Neither known ⇒ nil, no title.
enum WorkspaceTitle {
  static func name(
    folderID: Int?, treeFolders: [FolderTreeTier: [Components.Schemas.FolderNode]],
    summaries: [Components.Schemas.FolderSummary]
  ) -> String? {
    guard let folderID else { return nil }
    for folders in treeFolders.values {
      if let node = folders.first(where: { $0.id == folderID }) { return node.name }
    }
    if let summary = summaries.first(where: { $0.folderId == folderID }) {
      return NeedsReview.shootName(for: summary)
    }
    return nil
  }
}
