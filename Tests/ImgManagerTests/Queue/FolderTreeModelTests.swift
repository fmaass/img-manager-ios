import ImgManagerAPI
import Testing

@testable import ImgManager

/// P7 (IMGMGR-217): the sidebar's browse surface becomes a real tree — the server's hierarchy,
/// the server's counts, and a client-side filter over folder names.
///
/// The fixtures below are shaped from the LIVE response, probed 2026-08-30 read-only through the
/// running `img-manager` container (`GET /api/folders`, both tiers): 855 nodes, kinds
/// {other, dated, dated_split, import, project, template}, local single-rooted at
/// `photo_incoming`, archive a forest of 14 roots, 0 orphans, depth ≤ 4, 110 shoot-kind folders
/// that DO have children (`template`/`project` subfolders), and `image_count ==
/// descendant_image_count` on all 685 leaves. That is the IMGMGR-173 discipline: the server's
/// vocabulary and the server's shape are pinned against the real API, never against a fixture
/// this suite also wrote.
@Suite("Folder tree model — hierarchy, counts, search")
struct FolderTreeModelTests {

  private func node(
    id: Int, parent: Int? = nil, kind: String = "dated", name: String? = nil,
    path: String? = nil, own: Int = 0, descendant: Int = 0
  ) -> Components.Schemas.FolderNode {
    .init(
      descendantImageCount: descendant, id: id, imageCount: own, kind: kind,
      name: name ?? "folder-\(id)", parentId: parent, path: path ?? "p\(id)")
  }

  /// The hierarchy is the `parent_id` chain and nothing else. `path` is on the wire and is a
  /// deliberate non-input: splitting it would be a second, client-side definition of the server's
  /// own structure. The fixture makes the two disagree so only one of them can be right.
  @Test("the forest follows parent_id, never the path string")
  func buildsTheForestFromParentIdAndNeverFromPath() {
    let nodes = [
      node(id: 1, kind: "other", name: "2025", path: "2025"),
      node(id: 2, parent: 1, kind: "dated", name: "2025-03-04", path: "9999/2025-03-04"),
      node(id: 3, kind: "other", name: "9999", path: "9999"),
    ]

    let forest = FolderTreeModel.forest(nodes)

    #expect(forest.map(\.id) == [1, 3])
    #expect(forest[0].children.map(\.id) == [2])
    // The folder whose PATH claims the child gets nothing: path never parents anything.
    #expect(forest[1].children.isEmpty)
  }

  /// The phase's pre-decided pivot, made real: a node whose parent is not in this response is
  /// surfaced at the top level with its own name — never dropped, and never re-parented by
  /// guessing from `path`. The tier roots stay real roots at the same time, so this is not the
  /// degenerate "everything is a root" answer.
  @Test("an orphan is surfaced at the tier root rather than dropped")
  func orphanNodesAreSurfacedAtTheTierRootRatherThanDropped() {
    let nodes = [
      node(id: 10, kind: "other", name: "2024"),
      node(id: 11, parent: 10, kind: "dated", name: "2024-05-06"),
      node(id: 12, parent: 999, kind: "dated", name: "2024-08-20"),
    ]

    let forest = FolderTreeModel.forest(nodes)

    #expect(forest.map(\.id) == [10, 12])
    #expect(forest[0].children.map(\.id) == [11])
    #expect(FolderTreeModel.flattened(forest).map(\.id) == [10, 11, 12])
  }

  /// The archive tier is a FOREST — 14 `parent_id: null` roots on 2026-08-30, not the single
  /// tier root the phase's first action expected. Every one of them has to reach the reader.
  @Test("every root of a multi-root tier is surfaced, in the response's own order")
  func everyRootOfAMultiRootTierIsSurfacedInWireOrder() {
    let nodes = [
      node(id: 1, kind: "other", name: "2019"),
      node(id: 2, parent: 1, kind: "project", name: "argentina"),
      node(id: 3, kind: "other", name: "2022"),
      node(id: 4, parent: 3, kind: "dated", name: "2022-07-01"),
    ]

    let forest = FolderTreeModel.forest(nodes)

    #expect(forest.map(\.id) == [1, 3])
    #expect(forest.map { $0.children.map(\.id) } == [[2], [4]])
  }

  /// Search-as-you-filter: a hit keeps its ancestors (so you can see where it lives) and its own
  /// subtree (so you can drill into it), and a branch with no hit disappears entirely.
  @Test("a search keeps the ancestors of every match and drops the branches without one")
  func searchMatchesDescendantsAndKeepsTheirAncestorsVisible() {
    let nodes = [
      node(id: 1, kind: "other", name: "2024"),
      node(id: 2, parent: 1, kind: "dated", name: "2024-05-06-teneriffa"),
      node(id: 3, parent: 2, kind: "template", name: "edits"),
      node(id: 4, kind: "other", name: "2025"),
      node(id: 5, parent: 4, kind: "dated", name: "2025-01-18"),
    ]
    let forest = FolderTreeModel.forest(nodes)

    let hits = FolderTreeModel.filter(forest, matching: "TENERIFFA")

    #expect(hits.map(\.id) == [1])
    #expect(hits[0].children.map(\.id) == [2])
    #expect(hits[0].children[0].children.map(\.id) == [3])
    #expect(FolderTreeModel.flattened(hits).map(\.id) == [1, 2, 3])
    // A query that is only whitespace is not a filter at all.
    #expect(FolderTreeModel.filter(forest, matching: "   ").map(\.id) == [1, 4])
    // Case and diacritics are folded, so a name nobody can type still comes back.
    #expect(FolderTreeModel.matches("Zürich", "zurich"))
    #expect(!FolderTreeModel.matches("2025-01-18", "teneriffa"))
  }

  /// Both counts are the server's own numbers. The fixture's parent claims 999 descendants while
  /// its only child holds 1, so a client-side roll-up cannot pass this.
  @Test("counts come from the response and are never summed client-side")
  func countsComeFromTheResponseAndAreNeverSummedClientSide() {
    let nodes = [
      node(id: 1, kind: "dated", name: "2024-05-06", own: 5, descendant: 999),
      node(id: 2, parent: 1, kind: "template", name: "edits", own: 1, descendant: 1),
    ]

    let forest = FolderTreeModel.forest(nodes)

    #expect(forest.count == 1)
    #expect(forest[0].children.map(\.id) == [2])
    #expect(forest[0].imageCount == 5)
    #expect(forest[0].descendantImageCount == 999)
    #expect(forest[0].children[0].descendantImageCount == 1)
  }

  /// The rendered line-up: only the branches that are open, each with the depth its inset is
  /// drawn from. A closed branch contributes exactly its own row and nothing beneath it.
  @Test("visible rows show only the open branches and carry their depth")
  func visibleRowsShowOnlyTheOpenBranchesAndCarryTheirDepth() {
    let nodes = [
      node(id: 1, kind: "other", name: "2024"),
      node(id: 2, parent: 1, kind: "dated", name: "2024-05-06"),
      node(id: 3, parent: 2, kind: "template", name: "edits"),
      node(id: 4, kind: "dated", name: "2024-08-20"),
    ]
    let forest = FolderTreeModel.forest(nodes)

    let closed = FolderTreeModel.visibleRows(forest) { _ in false }
    #expect(closed.map(\.id) == [1, 4])
    #expect(closed.map(\.depth) == [0, 0])
    #expect(closed.map(\.isExpandable) == [true, false])

    let oneOpen = FolderTreeModel.visibleRows(forest) { $0 == 1 }
    #expect(oneOpen.map(\.id) == [1, 2, 4])
    #expect(oneOpen.map(\.depth) == [0, 1, 0])

    let allOpen = FolderTreeModel.visibleRows(forest) { _ in true }
    #expect(allOpen.map(\.id) == [1, 2, 3, 4])
    #expect(allOpen.map(\.depth) == [0, 1, 2, 0])
  }

  /// One boundary guard, both causes: nothing the response contained may vanish from the tree,
  /// whether its parent is missing or its parent chain closes on itself. A cycle is not something
  /// a filesystem tree can produce, but the tree is rendered by a RECURSIVE view — a dropped node
  /// is a bug and an endless one is a hang, so the model refuses both at the same place.
  @Test("a parent cycle strands no node and never recurses forever")
  func aParentCycleStrandsNoNodeAndNeverRecursesForever() {
    let nodes = [node(id: 1, parent: 2), node(id: 2, parent: 1), node(id: 3)]

    let flat = FolderTreeModel.flattened(FolderTreeModel.forest(nodes)).map(\.id).sorted()

    #expect(flat == [1, 2, 3])
  }
}
