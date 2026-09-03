import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-350 P1: the two transforms the web's folder tree has and the native one did not — the
/// TIER-ROOT HOIST and the MONTH FOLD — ported from `lib/folderTree.ts` (`:166`, `:222`, composed
/// in the order of `:277`) and pinned here as values, before any view renders them.
///
/// Provenance of the shapes below, so nothing is invented: the live probe of 2026-08-30
/// (read-only, `GET /api/folders`, both tiers) found the local tier single-rooted at
/// `photo_incoming` and the archive a forest of 14 roots, with dated leaves named
/// `YYYY-MM-DD — Title` under `YYYY` containers. The tier root's `path` is the server's own
/// configured prefix (img-manager `app/config.py:113-114`).
///
/// The counts are deliberately NOT self-consistent: a year folder claims 999 descendants while
/// its two members hold 5 and 7. A month row that rolled its parent's number up, or that summed
/// anything but its own members, cannot pass.
@Suite("Folder tree tier items — the hoist and the month fold (IMGMGR-350)")
struct FolderTreeTierItemsTests {

  private func node(
    id: Int, parent: Int? = nil, kind: String = "dated", name: String? = nil,
    path: String? = nil, own: Int = 0, descendant: Int = 0
  ) -> Components.Schemas.FolderNode {
    .init(
      descendantImageCount: descendant, id: id, imageCount: own, kind: kind,
      name: name ?? "folder-\(id)", parentId: parent, path: path ?? "p\(id)")
  }

  private func items(_ nodes: [Components.Schemas.FolderNode], tier: FolderTreeTier)
    -> [FolderTreeItem]
  {
    FolderTreeModel.tierItems(FolderTreeModel.forest(nodes), tier: tier)
  }

  /// The narrow identity check, both ways round: the tier's OWN root row disappears and its
  /// children render directly under the tier label, while a top-level folder that merely looks
  /// like a root keeps its row.
  @Test("the tier root is hoisted away only when the tier IS that root")
  func theTierRootIsHoistedAwayOnlyWhenTheTierIsThatRoot() {
    let nodes = [
      node(
        id: 1, kind: "other", name: "photo_incoming", path: "photo_incoming", descendant: 12),
      node(
        id: 2, parent: 1, kind: "other", name: "2026", path: "photo_incoming/2026",
        descendant: 12),
    ]

    #expect(items(nodes, tier: .incoming).map(\.id) == [.folder(2)])

    // The SAME response read as the archive tier keeps every row: the archive's top level is 14
    // real trees, not one wrapper, so it is never hoisted (`folderTree.ts:168`).
    #expect(items(nodes, tier: .archive).map(\.id) == [.folder(1)])

    // A single root whose path is NOT the tier's tree is a real folder — an orphan the forest
    // promoted, say — and keeps its row (`folderTree.ts:171`).
    let stranger = [node(id: 5, kind: "other", name: "2019", path: "somewhere/else")]
    #expect(items(stranger, tier: .incoming).map(\.id) == [.folder(5)])

    // Two top-level rows are not "the tier is its root" either (`folderTree.ts:169`).
    let two = [
      node(id: 1, kind: "other", name: "photo_incoming", path: "photo_incoming"),
      node(id: 6, kind: "other", name: "2019", path: "photo_incoming-2"),
    ]
    #expect(items(two, tier: .incoming).map(\.id) == [.folder(1), .folder(6)])
  }

  /// The fold itself: a year folder's dated children become month rows, in calendar order, each
  /// carrying its own members. The row is a fold and NOT a folder — no id, nothing selectable —
  /// and its count is the sum of its members' server counts, never the parent's own.
  @Test("a year folder's dated children fold into month rows that are no folder at all")
  func aYearFoldersDatedChildrenFoldIntoMonthRowsThatAreNoFolderAtAll() {
    let nodes = [
      node(id: 2, kind: "other", name: "2026", path: "photo_incoming/2026", descendant: 999),
      node(
        id: 3, parent: 2, kind: "dated", name: "2026-09-14 — Wandern",
        path: "photo_incoming/2026/2026-09-14-wandern", descendant: 5),
      node(
        id: 4, parent: 2, kind: "dated", name: "2026-09-27 — Stadt",
        path: "photo_incoming/2026/2026-09-27-stadt", descendant: 7),
      node(
        id: 5, parent: 2, kind: "dated", name: "2026-03-01 — Fruehling",
        path: "photo_incoming/2026/2026-03-01-fruehling", descendant: 3),
      // Not a date, and a thirteenth month that is a NAME rather than a month
      // (`folderTree.ts:243-247`): both keep their place, after the folds.
      node(id: 6, parent: 2, kind: "other", name: "misc", path: "photo_incoming/2026/misc"),
      node(
        id: 7, parent: 2, kind: "dated", name: "2026-13-01 — Nope",
        path: "photo_incoming/2026/2026-13-01"),
    ]

    let year = items(nodes, tier: .archive)
    #expect(year.map(\.id) == [.folder(2)])

    let children = year[0].children
    // Months first in calendar order, then the two rows that are not months, in wire order.
    #expect(
      children.map(\.id) == [
        .month("2:2026-03"), .month("2:2026-09"), .folder(6), .folder(7),
      ])

    guard case .month(let september, let members) = children[1] else {
      Issue.record("the second row of 2026 is not a month fold")
      return
    }
    // A fold is no folder: nothing here can be handed to selectShoot(folderID:sourceTier:).
    #expect(children[1].node == nil)
    #expect(september.parentID == 2)
    #expect(september.year == "2026")
    #expect(september.month == "09")
    #expect(september.label == "september")
    // 5 + 7 — its own members' server counts, never the parent's 999.
    #expect(september.count == 12)
    #expect(members.map(\.id) == [.folder(3), .folder(4)])

    guard case .month(let march, _) = children[0] else {
      Issue.record("the first row of 2026 is not a month fold")
      return
    }
    #expect(march.count == 3)
  }

  /// Two years under one tier: the keys carry their parent, so nothing collides, and a member's
  /// own year decides the label when it differs from the folder it hangs under.
  @Test("two years produce distinct month keys, and a mismatched year is said out loud")
  func twoYearsProduceDistinctMonthKeys() {
    let nodes = [
      node(id: 10, kind: "other", name: "2025", path: "a/2025"),
      node(
        id: 11, parent: 10, kind: "dated", name: "2025-09-02", path: "a/2025/2025-09-02",
        descendant: 4),
      node(id: 20, kind: "other", name: "2026", path: "b/2026"),
      node(
        id: 21, parent: 20, kind: "dated", name: "2026-09-02", path: "b/2026/2026-09-02",
        descendant: 6),
      // A year folder holding a date from ANOTHER year: the label says which year it is
      // (`folderTree.ts:212-214`).
      node(
        id: 22, parent: 20, kind: "dated", name: "2024-01-05", path: "b/2026/2024-01-05",
        descendant: 1),
    ]

    let tree = items(nodes, tier: .archive)

    #expect(tree.map(\.id) == [.folder(10), .folder(20)])
    #expect(tree[0].children.map(\.id) == [.month("10:2025-09")])
    #expect(tree[1].children.map(\.id) == [.month("20:2024-01"), .month("20:2026-09")])

    guard case .month(let foreign, _) = tree[1].children[0],
      case .month(let own, _) = tree[1].children[1]
    else {
      Issue.record("2026 did not fold into two month rows")
      return
    }
    #expect(foreign.label == "january 2024")
    #expect(own.label == "september")
  }

  /// The accessibility identifier a UI test walks, derived in ONE place beside the folder-row
  /// identifiers. The shape below is the DEBUG fixture's own year folder (id 2, holding
  /// `2026-09-14 — Wandern`), so the string this pins is the string `TierHomeUITests` looks for.
  @Test("a month fold's identifier is folderTreeMonth-<parentId>-<yyyy>-<mm>")
  func aMonthFoldsIdentifierIsParentAndYearMonth() {
    let nodes = [
      node(id: 2, kind: "other", name: "2026", path: "2026", descendant: 12),
      node(
        id: 3, parent: 2, kind: "dated", name: "2026-09-14 — Wandern",
        path: "2026/2026-09-14-wandern", descendant: 12),
    ]

    let children = items(nodes, tier: .archive)[0].children
    guard case .month(let september, _) = children.first else {
      Issue.record("the fixture's year folder did not fold")
      return
    }

    #expect(
      FolderTreeRowPresentation.monthIdentifier(for: september) == "folderTreeMonth-2-2026-09")
  }

  /// A folder that is not a year is left alone entirely — the fold is scoped to `^\d{4}$` parents
  /// (`folderTree.ts:226`), so a project folder full of dated shoots keeps its rows.
  @Test("only a year folder folds; every other parent keeps its dated children")
  func onlyAYearFolderFolds() {
    let nodes = [
      node(id: 30, kind: "project", name: "argentina", path: "a/argentina"),
      node(
        id: 31, parent: 30, kind: "dated", name: "2026-09-14 — Ruta", path: "a/argentina/x",
        descendant: 2),
    ]

    let tree = items(nodes, tier: .archive)

    #expect(tree.map(\.id) == [.folder(30)])
    #expect(tree[0].children.map(\.id) == [.folder(31)])
  }

  /// The rendered line-up over the folded tree: a closed fold contributes its own row and nothing
  /// beneath it, and the depth is the one the row's inset is drawn from.
  @Test("visible rows walk folds and folders alike, carrying their depth")
  func visibleRowsWalkFoldsAndFoldersAlike() {
    let nodes = [
      node(id: 2, kind: "other", name: "2026", path: "2026"),
      node(id: 3, parent: 2, kind: "dated", name: "2026-09-14 — Wandern", path: "2026/w"),
    ]
    let tree = items(nodes, tier: .archive)

    let closed = FolderTreeModel.visibleRows(tree) { _ in false }
    #expect(closed.map(\.id) == [.folder(2)])
    #expect(closed.map(\.isExpandable) == [true])

    let yearOpen = FolderTreeModel.visibleRows(tree) { $0 == .folder(2) }
    #expect(yearOpen.map(\.id) == [.folder(2), .month("2:2026-09")])
    #expect(yearOpen.map(\.depth) == [0, 1])

    let allOpen = FolderTreeModel.visibleRows(tree) { _ in true }
    #expect(allOpen.map(\.id) == [.folder(2), .month("2:2026-09"), .folder(3)])
    #expect(allOpen.map(\.depth) == [0, 1, 2])
  }

  /// The tier type is the PAIR the API takes, and `edits` is the half `GridSourceTier` cannot
  /// say: both local-store tiers differ only in the `tree` prefix (`app/api/folders.py:38`,
  /// `:54`; `entryPoint.ts:30-38`).
  @Test("a browse tier is (source_tier, tree), and edits is a tree prefix")
  func aBrowseTierIsTheSourceTierAndTreePair() {
    #expect(FolderTreeTier.allCases.map(\.rawValue) == ["incoming", "edits", "archive"])
    #expect(FolderTreeTier.incoming.sourceTier == .local)
    #expect(FolderTreeTier.edits.sourceTier == .local)
    #expect(FolderTreeTier.archive.sourceTier == .archive)
    #expect(FolderTreeTier.incoming.treePrefix == "photo_incoming")
    #expect(FolderTreeTier.edits.treePrefix == "photo_edits")
    #expect(FolderTreeTier.archive.treePrefix == nil)
    #expect(FolderTreeTier.allCases.map(\.label) == ["Incoming", "Edits", "Archive"])
  }
}
