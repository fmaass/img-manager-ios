import ImgManagerAPI

/// What a summary-backed row calls its shoot (IMGMGR-549 moved it here from the retired
/// "Needs review" predicate, unchanged).
///
/// `FolderSummary` carries `path` and no name — unlike `FolderNode`, which the tree's own rows
/// read `name` off — so the shoot leaf's own path segment is the closest available answer. One
/// owner for every surface that names a shoot from a summary: the sidebar's Untouched, Pinned and
/// Recent rows, the overflow grid's tiles, the queue card and the workspace title's fallback.
enum ShootName {
  static func of(_ summary: Components.Schemas.FolderSummary) -> String {
    summary.path.split(separator: "/").last.map(String.init) ?? summary.path
  }
}
