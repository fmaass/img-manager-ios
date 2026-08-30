import Foundation
import ImgManagerAPI

/// One folder of the sidebar's browse tree, with whatever the server's own `parent_id` chain
/// puts under it.
///
/// The node keeps the wire `FolderNode` whole rather than copying fields out of it: every number
/// this row shows is the server's answer, and the only way to keep that true is to never hold a
/// second copy that could drift. `id` is the server's folder id — the stable identity every
/// `ForEach` over this tree keys on (IMGMGR-210: no index identity anywhere).
struct FolderTreeNode: Identifiable {
  let folder: Components.Schemas.FolderNode
  let children: [FolderTreeNode]

  var id: Int { folder.id }
  var name: String { folder.name }
  var kind: String { folder.kind }

  /// This folder's own active images, as the server counted them.
  var imageCount: Int { FolderTreeModel.wireCount(folder.imageCount) }

  /// This folder AND everything under it, as the server counted it — never a client-side sum of
  /// `children`. It is also exactly the population a tap on this row opens: `/api/images` resolves
  /// `folder_id` to the folder's whole subtree (`app/api/images.py:2245-2251`, param documented
  /// "folder and everything under it"), so this is the number the grid will agree with. Probed
  /// 2026-08-30 against production: on every one of the 685 leaf folders across both tiers
  /// `image_count == descendant_image_count`, so the two only diverge where there is a subtree.
  var descendantImageCount: Int { FolderTreeModel.wireCount(folder.descendantImageCount) }

  /// Whether tapping this row navigates. `ShootListFilter` stays the ONE definition of what a
  /// browsable shoot is (ADR-0004: shoot ≡ folder; IMGMGR-173: the vocabulary is the server's);
  /// P7 only adds the other half of the answer — a folder that is not a shoot is a container that
  /// expands and does not navigate, instead of being absent from the tree altogether.
  var isSelectableShoot: Bool { ShootListFilter.shootKinds.contains(kind) }
}

/// One rendered line of the tree: a node, and how deep it sits. Identity is the server's folder
/// id, so a `ForEach` over these is index-free (IMGMGR-210) even as branches open and close.
struct FolderTreeOutlineRow: Identifiable {
  let node: FolderTreeNode
  let depth: Int

  var id: Int { node.id }
  var isExpandable: Bool { !node.children.isEmpty }
}

/// The pure half of the folder tree: flat `[FolderNode]` in, forest out, plus the client-side
/// filter the search field drives. No view, no fetch, no state — so every property below is
/// readable by a test.
///
/// Built from `parent_id` and NOTHING else. `path` is present on the wire and is deliberately
/// never split: re-deriving the hierarchy from a path string would be a second, client-side
/// definition of the server's own structure, and the two would drift silently (the phase's Do
/// NOT says so, and `buildsTheForestFromParentIdAndNeverFromPath` is the pin).
///
/// Live shape, probed 2026-08-30 through the running container (read-only, both tiers): local
/// 166 nodes under ONE root (`photo_incoming`); archive 689 nodes under **14** roots — the
/// archive tier is a forest, not a single-rooted tree, so "the tier root" is a plural. Zero
/// orphans in either tier today; the phase's pre-decided pivot (surface, never drop, never
/// re-parent by guessing) is implemented anyway because a folder the indexer has not yet linked
/// is a thing the API can legitimately return tomorrow.
enum FolderTreeModel {

  /// The parent→children forest, siblings in the response's own order (the server orders by
  /// `path`, so that order is the taxonomy's order and this adds no second sort).
  ///
  /// Every input node comes out exactly once. A node whose `parent_id` names a folder that is not
  /// in this response — an orphan — is surfaced at the top level rather than dropped, and so is a
  /// node stranded inside a `parent_id` cycle the server could never mean: the guard is one place
  /// (nothing is built twice, nothing is left behind) instead of a special case per cause.
  static func forest(_ nodes: [Components.Schemas.FolderNode]) -> [FolderTreeNode] {
    let present = Set(nodes.map(\.id))
    var childrenByParent: [Int: [Components.Schemas.FolderNode]] = [:]
    var tops: [Components.Schemas.FolderNode] = []
    for node in nodes {
      if let parent = node.parentId, parent != node.id, present.contains(parent) {
        childrenByParent[parent, default: []].append(node)
      } else {
        tops.append(node)
      }
    }

    var built: Set<Int> = []
    func build(_ node: Components.Schemas.FolderNode) -> FolderTreeNode {
      built.insert(node.id)
      let children = (childrenByParent[node.id] ?? [])
        .filter { !built.contains($0.id) }
        .map(build)
      return FolderTreeNode(folder: node, children: children)
    }

    var forest = tops.map(build)
    // Whatever a parent cycle kept out of every root's subtree is still the reader's folder.
    for node in nodes where !built.contains(node.id) {
      forest.append(build(node))
    }
    return forest
  }

  /// The tree narrowed to `query`, client-side over the already-loaded folder list — never a
  /// server call, and never the image-level free-text `q` filter, which answers a different
  /// question (that one searches photographs; this one searches the 855 folder names already in
  /// memory).
  ///
  /// A node that matches keeps its whole subtree, so a match on a container is something you can
  /// drill into. A node that does not match survives only if something under it did, which is what
  /// keeps an ancestor chain visible above a deep hit.
  static func filter(_ forest: [FolderTreeNode], matching query: String) -> [FolderTreeNode] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return forest }
    return forest.compactMap { pruned($0, matching: needle) }
  }

  private static func pruned(_ node: FolderTreeNode, matching needle: String) -> FolderTreeNode? {
    if matches(node.name, needle) { return node }
    let kept = node.children.compactMap { pruned($0, matching: needle) }
    guard !kept.isEmpty else { return nil }
    return FolderTreeNode(folder: node.folder, children: kept)
  }

  /// The rows that are actually on screen, in order, each carrying its own depth — the tree
  /// rendered as a flat list rather than as nested `DisclosureGroup`s.
  ///
  /// Why flat (gate run 1cfa3f4): the nested-disclosure version could not be driven through the
  /// real UI at all — a tap on a second-level container never produced its children for
  /// `FolderTreeHierarchyUITests`, and there was no way to tell an unopened branch from an
  /// unrendered one. A flat list makes both halves explicit and separable: the chevron is its own
  /// chrome Button and the name is its own tap target, so on the 110 production folders that are
  /// BOTH a shoot and a parent, expanding no longer also navigates.
  ///
  /// `isExpanded` is supplied by the caller so this stays a pure function of the tree: the rule
  /// itself (the reader's choice, or everything while a search is live) lives with the
  /// presentation, not here.
  static func visibleRows(
    _ forest: [FolderTreeNode], isExpanded: (Int) -> Bool
  ) -> [FolderTreeOutlineRow] {
    var rows: [FolderTreeOutlineRow] = []
    func walk(_ nodes: [FolderTreeNode], depth: Int) {
      for node in nodes {
        rows.append(FolderTreeOutlineRow(node: node, depth: depth))
        if !node.children.isEmpty, isExpanded(node.id) {
          walk(node.children, depth: depth + 1)
        }
      }
    }
    walk(forest, depth: 0)
    return rows
  }

  /// The shoot rows reachable in `forest`, flattened in render order — the P6 acceptance property
  /// ("the phone reaches every shoot the iPad reaches") expressed over the tree that actually
  /// ships, rather than over a parallel list only a test walks.
  static func selectableShoots(in forest: [FolderTreeNode]) -> [Components.Schemas.FolderNode] {
    ShootListFilter.shoots(flattened(forest))
  }

  /// Every node of the forest, parents before their own children.
  static func flattened(_ forest: [FolderTreeNode]) -> [Components.Schemas.FolderNode] {
    forest.flatMap { [$0.folder] + flattened($0.children) }
  }

  /// Case- and diacritic-insensitive substring match on the folder's NAME. Never on `path`: the
  /// tree shows names, a filesystem path is never surfaced in this UI, and matching on something
  /// the reader cannot see produces hits they cannot explain.
  static func matches(_ name: String, _ query: String) -> Bool {
    name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  /// `image_count` and `descendant_image_count` are non-required in the schema with a documented
  /// default of 0 (`FolderNode`, vendored `openapi.json`), so an absent count reads as the
  /// server's own default rather than as an unwrap. Taking `Int?` also keeps this one call site
  /// correct whichever way the generator renders a defaulted non-required integer.
  static func wireCount(_ value: Int?) -> Int { value ?? 0 }
}
