import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-362 (WP21 P3): the ARCHIVE PRUNE, ported from the web's `pruneMirrored`
/// (`frontend/src/lib/folderTree.ts:188-197`) and composed exactly where the web composes it
/// (`buildTierItems`, `:283`: archive only, before the hoist and therefore before the fold).
///
/// The oracle is the DEBUG fixture the shipped UI already browses, not a shape invented here:
/// `DebugStubTransport`'s archive answer is one year container (id 20, count 4) over a real shoot
/// (id 21, count 4) and one fully mirrored folder counting zero (id 22, "2025-11-01 — Mirrored").
/// P1 shipped that row as the CONTROL proving no prune ran; this suite is the inversion its own
/// doc comment predicted. The fixture is read, never edited (the phase's Do NOT).
///
/// Two properties, and the second is the one a careless implementation breaks:
///
/// - ON, the mirrored folder is gone AND so is the month row that folded only it — the prune runs
///   BEFORE `groupMonths`, so an emptied month is impossible rather than something to clean up
///   afterwards (`folderTree.ts:184-186`).
/// - OFF, `tierItems` returns today's WHOLE forest, asserted element-wise over every rendered row
///   rather than by spot-checking three ids. `pruneMirrored` itself has no OFF mode: the flag
///   lives at the composition, so the OFF path must be byte-for-byte the shipped one.
@Suite("Folder tree — the archive prune (IMGMGR-362)")
struct FolderTreePruneMirroredTests {

  private func node(
    id: Int, parent: Int? = nil, kind: String = "dated", name: String? = nil,
    path: String? = nil, own: Int = 0, descendant: Int = 0
  ) -> Components.Schemas.FolderNode {
    .init(
      descendantImageCount: descendant, id: id, imageCount: own, kind: kind,
      name: name ?? "folder-\(id)", parentId: parent, path: path ?? "p\(id)")
  }

  /// A READABLE sketch of the rendered rows — order, depth, identity and the number shown. It is
  /// deliberately LOSSY (no names, no paths, no kinds, no parent ids, no month labels), so it is
  /// used only where the claim is about SHAPE: which rows survived the prune. The OFF path, whose
  /// claim is "nothing about the tree changed at all", is asserted by VALUE EQUALITY on
  /// `FolderTreeItem` instead — a signature can only pin the fields somebody remembered to put in
  /// it, and the OFF test has to fail on any field mutation.
  private func signature(_ items: [FolderTreeItem], depth: Int = 0) -> [String] {
    items.flatMap { item -> [String] in
      let indent = String(repeating: "·", count: depth)
      let line: String
      switch item {
      case .folder(let folder, _):
        line = "\(indent)folder(\(folder.id)) n=\(folder.descendantImageCount)"
      case .month(let month, _):
        line = "\(indent)month(\(month.key)) n=\(month.count)"
      }
      return [line] + signature(item.children, depth: depth + 1)
    }
  }

  /// Every folder id the rendered rows carry, folds walked through — a month row has no id of its
  /// own, so this is exactly the set of real folders on screen.
  private func renderedFolderIDs(_ items: [FolderTreeItem]) -> Set<Int> {
    var found: Set<Int> = []
    func walk(_ rows: [FolderTreeItem]) {
      for row in rows {
        if let node = row.node { found.insert(node.id) }
        walk(row.children)
      }
    }
    walk(items)
    return found
  }

  #if DEBUG
    private var archiveFixture: [Components.Schemas.FolderNode] {
      DebugStubTransport.fixtureFolders(
        sourceTier: FolderTreeTier.archive.sourceTier.rawValue,
        tree: FolderTreeTier.archive.treePrefix)
    }

    /// The DEBUG archive fixture written out BY HAND, node for node and field for field — the
    /// yardstick both value-equality tests below measure against. Hand-written on purpose: an
    /// expectation derived from the transform under test would assert against itself.
    /// `theFixtureStillHoldsTheZeroCountOracle` is what keeps these literals honest.
    private var mirroredNode: FolderTreeNode {
      FolderTreeNode(
        folder: .init(
          descendantImageCount: 0, id: 22, imageCount: 0, kind: "dated",
          name: "2025-11-01 — Mirrored", parentId: 20, path: "2025/2025-11-01-mirrored"),
        children: [])
    }

    private var shootNode: FolderTreeNode {
      FolderTreeNode(
        folder: .init(
          descendantImageCount: 4, id: 21, imageCount: 4, kind: "dated",
          name: "2025-12-24 — Archive Shoot", parentId: 20, path: "2025/2025-12-24-archive-shoot"),
        children: [])
    }

    /// The year container, with whatever subtree the caller says it has: the prune REBUILDS this
    /// node around its surviving children, so "which children the node itself carries" is part of
    /// what the two tests below disagree about.
    private func yearNode(children: [FolderTreeNode]) -> FolderTreeNode {
      FolderTreeNode(
        folder: .init(
          descendantImageCount: 4, id: 20, imageCount: 0, kind: "other", name: "2025",
          path: "2025"),
        children: children)
    }

    private func month(_ number: String, label: String, count: Int, members: [FolderTreeItem])
      -> FolderTreeItem
    {
      .month(
        FolderTreeMonth(parentID: 20, year: "2025", month: number, label: label, count: count),
        members: members)
    }

    private func archiveItems(prune: Bool) -> [FolderTreeItem] {
      FolderTreeModel.tierItems(
        FolderTreeModel.forest(archiveFixture), tier: .archive, pruneMirroredArchive: prune)
    }

    /// The fixture is the oracle, so this states what it IS before anything asserts against it.
    /// Without this, every expectation below could pass against a fixture that had quietly lost
    /// its zero-count row — which is the one thing that would make the whole suite vacuous.
    @Test("the DEBUG archive fixture still holds the zero-count oracle (id 22) beside 20 and 21")
    func theFixtureStillHoldsTheZeroCountOracle() {
      let byID = Dictionary(uniqueKeysWithValues: archiveFixture.map { ($0.id, $0) })
      #expect(Set(byID.keys) == [20, 21, 22])
      #expect(FolderTreeModel.wireCount(byID[20]?.descendantImageCount) == 4)
      #expect(FolderTreeModel.wireCount(byID[21]?.descendantImageCount) == 4)
      #expect(FolderTreeModel.wireCount(byID[22]?.descendantImageCount) == 0)
      #expect(byID[22]?.name == "2025-11-01 — Mirrored")
    }

    /// ON: the mirrored row is gone, the real shoot and its container are kept, and the month row
    /// that folded ONLY the mirrored folder went with it.
    @Test("with the flag on, the mirrored archive folder and its emptied month row are dropped")
    func theFlagDropsTheMirroredFolderAndTheMonthThatOnlyHeldIt() {
      let rendered = archiveItems(prune: true)

      #expect(
        signature(rendered) == [
          "folder(20) n=4",
          "·month(20:2025-12) n=4",
          "··folder(21) n=4",
        ])
      #expect(renderedFolderIDs(rendered) == [20, 21])
      #expect(!renderedFolderIDs(rendered).contains(22))
      // The emptied month is not merely empty, it is ABSENT: the prune runs before the fold, so
      // no synthetic row is ever left standing over nothing (`folderTree.ts:184-186`).
      #expect(!signature(rendered).contains { $0.contains("month(20:2025-11)") })
      // And the same claim by VALUE, which the shape sketch above cannot make: the survivor is
      // the untouched year node REBUILT around its one surviving child — every other field of
      // every remaining node is exactly what the server sent.
      #expect(
        rendered == [
          .folder(
            yearNode(children: [shootNode]),
            children: [
              month("12", label: "december", count: 4, members: [.folder(shootNode, children: [])])
            ])
        ])
    }

    /// OFF: the WHOLE forest, by VALUE — not a signature of it.
    ///
    /// `pruneMirrored` has no OFF mode (the flag is read at the composition), so the default state
    /// must be byte-for-byte the tree IMGMGR-350 shipped. The expected value below is written out
    /// by hand — every wire field of every node, both children lists each `.folder` case carries
    /// (the UNFOLDED taxonomy on the node, the RENDERED rows on the case), and every field of both
    /// month folds including the ported English label — and compared with `==`. So a mutation
    /// anywhere in the tree fails this test, including in a field no assertion mentions by name.
    ///
    /// Hand-written rather than derived: a test that built its expectation by calling the same
    /// transform would be asserting against itself. The literals are the DEBUG fixture's own
    /// values, and `theFixtureStillHoldsTheZeroCountOracle` is what says they still are.
    @Test("with the flag off, tierItems returns today's whole archive forest, field for field")
    func theOffPathReturnsTodaysWholeForest() {
      // The year container keeps its UNFOLDED children in the server's own response order (21
      // before 22) while the rows under it are the two month folds in CALENDAR order (11 before
      // 12). Both are part of the value, so this pins the fold's ordering rule as well.
      let expected: [FolderTreeItem] = [
        .folder(
          yearNode(children: [shootNode, mirroredNode]),
          children: [
            month(
              "11", label: "november", count: 0,
              members: [.folder(mirroredNode, children: [])]),
            month(
              "12", label: "december", count: 4, members: [.folder(shootNode, children: [])]),
          ])
      ]

      #expect(archiveItems(prune: false) == expected)
      // The default caller — no argument at all — IS the OFF path, which is what keeps every
      // shipped call site (and IMGMGR-350's own suites) on today's tree.
      #expect(
        FolderTreeModel.tierItems(FolderTreeModel.forest(archiveFixture), tier: .archive)
          == expected)
      // Whole-forest equality the other way round too: every folder the server sent still
      // renders, so nothing was dropped anywhere in the tree, not only where a literal names it.
      #expect(renderedFolderIDs(archiveItems(prune: false)) == Set(archiveFixture.map(\.id)))
    }
  #endif

  /// The recursion, on a shape the fixture does not have: a PARTIALLY mirrored container keeps
  /// its own row and loses only the mirrored children beneath it, and a zero-count node's whole
  /// subtree goes with it — `descendant_image_count` is a ROLLUP (img-manager
  /// `app/api/folders.py`), so a folder reporting zero cannot be hiding a child with photographs.
  @Test("the prune recurses into survivors and takes a zero-count node's whole subtree")
  func thePruneRecursesIntoSurvivorsAndTakesWholeSubtrees() {
    let nodes = [
      node(id: 1, kind: "other", name: "partly", path: "partly", descendant: 3),
      node(id: 2, parent: 1, name: "kept", path: "partly/kept", own: 3, descendant: 3),
      node(id: 3, parent: 1, name: "mirrored", path: "partly/mirrored", descendant: 0),
      node(id: 4, parent: 3, name: "under-mirrored", path: "partly/mirrored/under", descendant: 0),
      node(id: 5, kind: "other", name: "gone", path: "gone", descendant: 0),
    ]
    let kept = FolderTreeModel.pruneMirrored(FolderTreeModel.forest(nodes))

    #expect(kept.map(\.id) == [1])
    #expect(kept.first?.children.map(\.id) == [2])
    // Positive control for the two 0-hit facts below: the unpruned forest really did hold them.
    let untouched = FolderTreeModel.flattened(FolderTreeModel.forest(nodes)).map(\.id)
    #expect(untouched.sorted() == [1, 2, 3, 4, 5])
    let survivors = FolderTreeModel.flattened(kept).map(\.id)
    #expect(!survivors.contains(4), "a zero-count node's subtree survived the prune")
    #expect(!survivors.contains(5), "a zero-count root survived the prune")
  }

  /// The prune is the ARCHIVE's alone (`folderTree.ts:283`, and the phase's Do NOT): a zero count
  /// means "already in the incoming library" only on the tier whose counts are dedup-adjusted.
  @Test("the incoming and edits tiers are never pruned, whatever the flag says")
  func theIncomingAndEditsTiersAreNeverPruned() {
    let nodes = [
      node(id: 1, kind: "other", name: "2026", path: "photo_incoming/2026", descendant: 0),
      node(
        id: 2, parent: 1, name: "2026-09-14 — Empty", path: "photo_incoming/2026/empty",
        descendant: 0),
    ]
    for tier in [FolderTreeTier.incoming, .edits] {
      let on = FolderTreeModel.tierItems(
        FolderTreeModel.forest(nodes), tier: tier, pruneMirroredArchive: true)
      let off = FolderTreeModel.tierItems(
        FolderTreeModel.forest(nodes), tier: tier, pruneMirroredArchive: false)
      #expect(on == off, "the flag changed the \(tier.rawValue) tier")
      #expect(!signature(on).isEmpty, "positive control: the \(tier.rawValue) tier rendered rows")
    }
  }
}
