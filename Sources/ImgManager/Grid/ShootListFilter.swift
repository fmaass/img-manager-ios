import ImgManagerAPI

/// Which `FolderNode`s the sidebar lists as browsable shoots (ADR-0004: shoot ≡ folder).
///
/// The backend's `FolderKind` vocabulary is `dated / dated_split / import / project /
/// template / other` (app/models.py; classifier app/indexer/classify.py) — there is NO
/// "day" kind. P4 shipped filtering on `"day"`, which the API never emits, so the shoot
/// list rendered empty against production while every test stayed green on fixtures that
/// used the same invented value (IMGMGR-173). The vendored schema types `kind` as a plain
/// string, so the compiler cannot catch vocabulary drift — this ONE definition, pinned by
/// tests that reject the retired value, is the guard.
enum ShootListFilter {
  /// The dated-shoot leaves: `dated` (YYYY/YYYY-MM-DD[-slug]) and `dated_split`
  /// (`...-1` / `...-2` continuation directories). Deliberately narrower than the full
  /// tree — import/project/template/other stay out of the shoot list, as P4 intended
  /// ("browsable shoot leaves, not the full tree").
  // TEMPORARY — mutation-loop RED probe (reverted in the next commit): the retired "day"
  // value, so this commit's gate run proves the vocabulary pins fail when the filter is wrong.
  static let shootKinds: Set<String> = ["day"]

  static func shoots(
    _ nodes: [Components.Schemas.FolderNode]
  ) -> [Components.Schemas.FolderNode] {
    nodes.filter { shootKinds.contains($0.kind) }
  }
}
