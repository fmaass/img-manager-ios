import Foundation

/// What ONE line of the Folders tree shows, as values rather than as a shape only a screenshot
/// could disagree with — WP16 P5, p3332 decision 2 (IMGMGR-296).
///
/// The decision is "sidebar shoot rows gain a cover thumbnail + count subline", and the surface
/// it lands on is this tree: the queue's readiness cards already ship that anatomy
/// (`QueueCardRow`, a 64×64 hero over "N photos · M picked"), while the tree still rendered a
/// bare name and a trailing number. A shoot row now leads with a cover and states its count
/// underneath the name; a CONTAINER row is untouched, trailing count included — it is not a
/// shoot, it has no cover, and decision 2 says shoot rows.
///
/// Three properties are worth stating because they are what the tests pin:
///
/// - the cover and the subline are the SAME question (`isSelectableShoot`, still
///   `ShootListFilter`'s single definition of a browsable shoot) — there is no second rule here
///   that could let one appear without the other;
/// - the subline is the server's own `descendant_image_count`, never a client-side roll-up: it
///   is exactly the population a tap opens (`/api/images` resolves `folder_id` to the whole
///   subtree), which is what keeps the row and the grid from stating different numbers;
/// - the count MOVES into the subline on a shoot row rather than being drawn twice, so
///   `trailingCount` is nil there — a row states its number once.
enum FolderTreeRowPresentation {

  /// Whether this row leads with a cover thumbnail. Shoots only, for the same reason only shoots
  /// navigate: a container is a folder of folders, and the "cover" it would show is an arbitrary
  /// frame from whichever descendant happened to sort first.
  static func showsThumbnail(_ node: FolderTreeNode) -> Bool { node.isSelectableShoot }

  /// The shoot row's second line: the server's roll-up, formatted the way the queue card's own
  /// subline formats the same kind of number (`"\(summary.total) photos · …"`). `nil` on a
  /// container, which keeps its trailing count instead.
  static func subline(for node: FolderTreeNode) -> String? {
    guard showsThumbnail(node) else { return nil }
    return "\(node.descendantImageCount) photos"
  }

  /// The trailing count a container row has always shown — unchanged, and deliberately absent on
  /// a shoot row, where the same number now reads as the subline.
  static func trailingCount(for node: FolderTreeNode) -> String? {
    guard !showsThumbnail(node) else { return nil }
    return node.descendantImageCount.formatted()
  }

  /// The cover's test handle. Derived here and nowhere else, so the UI test and the view cannot
  /// drift apart on a rename; keyed by the server's folder id like every other identifier in
  /// this tree (`folderRow-` / `folderContainer-` / `folderDisclose-`).
  static func thumbnailIdentifier(for id: Int) -> String { "folderRowThumbnail-\(id)" }

  /// The subline's test handle, on the same terms.
  static func sublineIdentifier(for id: Int) -> String { "folderRowSubline-\(id)" }
}
