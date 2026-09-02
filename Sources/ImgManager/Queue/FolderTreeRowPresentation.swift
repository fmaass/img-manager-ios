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

  /// The row's own handle — `folderRow-` where a tap enters the grid, `folderContainer-` where it
  /// only expands. Unchanged strings; what changed (diff-gate r1, B1) is WHERE they are applied.
  ///
  /// They now sit on the NAME text rather than on the row container, because an identifier set on
  /// a container OVERRIDES its descendants': observed on an iPhone gate leg and documented at
  /// `GridView.swift:743-747`, where a row identifier made both of its own controls unaddressable.
  /// With the identifier on the container, this row's new cover and subline handles would not
  /// exist for XCUITest at all. The name text is also the element the shipped tree tests have
  /// been finding and tapping all along — the container identifier reached them by that same
  /// override — so the tap they drive lands exactly where it did before.
  static func rowIdentifier(for node: FolderTreeNode, id: Int) -> String {
    node.isSelectableShoot ? "folderRow-\(id)" : "folderContainer-\(id)"
  }

  /// The cover's test handle. Derived here and nowhere else, so the UI test and the view cannot
  /// drift apart on a rename; keyed by the server's folder id like every other identifier in
  /// this tree (`folderRow-` / `folderContainer-` / `folderDisclose-`).
  static func thumbnailIdentifier(for id: Int) -> String { "folderRowThumbnail-\(id)" }

  /// The subline's test handle, on the same terms.
  static func sublineIdentifier(for id: Int) -> String { "folderRowSubline-\(id)" }

  /// A MONTH FOLD's handle — `folderTreeMonth-<parentId>-<yyyy>-<mm>`, e.g.
  /// `folderTreeMonth-2-2026-09`. Derived here beside the folder-row identifiers above and
  /// nowhere else, so the walk a UI test drives and the string the view applies cannot drift.
  ///
  /// It is deliberately NOT keyed by a folder id, because a fold is no folder
  /// (`FolderTreeItemID`): the parent year folder plus the `yyyy-mm` it groups is the whole
  /// identity, which is the web's own synthetic key with `:` spelled as `-` for a legible
  /// accessibility identifier (`folderTree.ts:41-42`).
  static func monthIdentifier(for month: FolderTreeMonth) -> String {
    "folderTreeMonth-\(month.parentID)-\(month.year)-\(month.month)"
  }
}
