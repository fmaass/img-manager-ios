import Foundation
import ImgManagerAPI

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

  /// WHICH folder the tree PAINTS as selected (IMGMGR-405 rule 5). `selection` is the enclosing
  /// `List`'s own binding; `opened` is the folder whose grid is actually showing —
  /// `GridStore.query.folderID`, the field `selectShoot(folderID:sourceTier:)` records.
  ///
  /// It falls back rather than mirroring because a COLLAPSED `NavigationSplitView` is a stack:
  /// popping back out of the grid on the phone clears the List's selection, and a highlight read
  /// straight off that binding would vanish exactly when the reader returns to the tree to see
  /// where they have been — the opposite of what the owner asked for.
  ///
  /// The store, and not a `@State` of this view, is the retainer (round-2 finding 3): the home is
  /// rebuilt from scratch whenever `RootView.workspaceChrome` swaps its two-column and
  /// three-column branches, and view state does not survive that. The store does, and it is the
  /// same answer either way — the grid on the other side of the split is showing exactly one
  /// folder, and that is the one the tree should be pointing at. The path that makes the
  /// difference — a Compact pop-back clearing the selection, then a resize into the three-column
  /// branch that destroys the tree's view state — is exactly the one no simulator run can drive,
  /// which is why the retainer is chosen by construction here rather than pinned by a UI test.
  ///
  /// The List's own selection still WINS while it has one, so a selection made anywhere else —
  /// the restored initial shoot (`RootView.swift:294`), the fixture launch (`:311`) — moves the
  /// highlight without this tree having to be told.
  ///
  /// This value paints and nothing else. What a TAP means is decided against the List's actual
  /// selection instead (`FolderTreeItemRow.tapAction`'s `isSelected`); see `FolderTreeSection`
  /// for why the two must not be the same question.
  static func highlight(selection: Int?, opened: Int?) -> Int? { selection ?? opened }

  /// Whether THIS row is that folder. A month fold can never be: it has no folder id to compare
  /// (`FolderTreeItemID`), which is what keeps "exactly one row at a time" true by construction
  /// rather than by the view remembering to ask.
  static func isSelected(_ item: FolderTreeItem, highlightedFolderID: Int?) -> Bool {
    guard let node = item.node, let highlighted = highlightedFolderID else { return false }
    return node.id == highlighted
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

  /// The shoot row's READINESS, as the server said it (IMGMGR-350 P3). The badge states the
  /// served identifier's title and derives nothing: `ReadinessSection` is the one string table in
  /// this app (`QueueModels.swift:36-45`, shared with the widget), keyed by the wire value the
  /// server sent, exactly as `QueueSort.sections(from:)` keys its sections. A readiness this
  /// client does not know is rendered as NO badge rather than as a guess — the same
  /// unknown-vocabulary posture `ShootListFilter` takes for `kind` (IMGMGR-173).
  ///
  /// Whatever the ADR-0004 amendment round (IMGMGR-330, /link/3376) lands as the readiness VALUE
  /// is what this says: the badge consumes that contract and does not define it.
  ///
  /// Shoot rows only, for the same reason the cover and the subline are shoot-only: a container
  /// is a folder of folders and `/api/folder-summaries` has no row for it. A folder with no
  /// summary shows no badge — nothing here invents one from counts.
  static func readinessBadge(
    for node: FolderTreeNode, summaries: [Int: Components.Schemas.FolderSummary]
  ) -> String? {
    guard node.isSelectableShoot, let summary = summaries[node.id] else { return nil }
    return readinessBadge(for: summary)
  }

  /// The same badge for a surface that already HAS the summary and no tree node to join through —
  /// the pinned "Needs review" section (IMGMGR-389), which is a filter over the summaries
  /// themselves. Split out of the join above rather than written a second time: the wording of a
  /// readiness value must come from one place, or the pinned row and the tree row underneath it
  /// can say different things about the same shoot.
  static func readinessBadge(for summary: Components.Schemas.FolderSummary) -> String? {
    ReadinessSection(rawValue: summary.readiness.rawValue)?.title
  }

  /// The summaries as a `folder_id` join table — the ONE place the tree's rows meet the queue's
  /// answers. Last row wins on a duplicate id, which the server does not emit (one summary per
  /// folder); stated because a trapping `uniqueKeysWithValues` would turn a server-side surprise
  /// into a crash on the home screen.
  static func index(
    _ summaries: [Components.Schemas.FolderSummary]
  ) -> [Int: Components.Schemas.FolderSummary] {
    Dictionary(summaries.map { ($0.folderId, $0) }, uniquingKeysWith: { _, latest in latest })
  }

  /// The badge's test handle, keyed by the server's folder id like every other identifier here.
  static func readinessIdentifier(for id: Int) -> String { "folderReadiness-\(id)" }

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

  /// The EXPAND control's handle, for a folder row and a fold alike — `folderDisclose-<id>` where
  /// the row is a folder, unchanged, and `folderDisclose-<parentId>-<yyyy>-<mm>` where it is a
  /// fold. A fold has to be openable from a test for the same reason it is openable at all: it is
  /// where the year's shoots now live.
  static func discloseIdentifier(for id: FolderTreeItemID) -> String {
    switch id {
    case .folder(let folderID): return "folderDisclose-\(folderID)"
    case .month(let key): return "folderDisclose-\(key.replacingOccurrences(of: ":", with: "-"))"
    }
  }
}
