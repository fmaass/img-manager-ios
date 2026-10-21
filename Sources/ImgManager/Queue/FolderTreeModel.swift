import Foundation
import ImgManagerAPI

/// One folder of the sidebar's browse tree, with whatever the server's own `parent_id` chain
/// puts under it.
///
/// The node keeps the wire `FolderNode` whole rather than copying fields out of it: every number
/// this row shows is the server's answer, and the only way to keep that true is to never hold a
/// second copy that could drift. `id` is the server's folder id — the stable identity every
/// `ForEach` over this tree keys on (IMGMGR-210: no index identity anywhere).
/// `Equatable` (IMGMGR-362) is SYNTHESIZED, over the whole wire node and the whole subtree — so
/// two nodes are equal only when every served field and every descendant agrees. It exists so the
/// prune's OFF path can be pinned as "the rendered forest is EXACTLY today's", rather than as a
/// hand-written projection of it that would keep passing while a field it forgot mutated.
/// `Components.Schemas.FolderNode` already conforms (the generator emits `Codable, Hashable,
/// Sendable`, which is what lets `FolderTreeLoad`'s own synthesized `Equatable` compile over a
/// dictionary of them, `FolderTreeSection.swift:304-330`).
struct FolderTreeNode: Identifiable, Equatable {
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

/// The identity of one RENDERED row: the server's folder id, or a month fold's synthetic key.
///
/// Two cases rather than one `Int`, because a month row IS no folder. The web says it plainly —
/// its `MonthItem` "has no `node` and no id on purpose … it can be expanded and collapsed, never
/// selected, so nothing downstream can mistake it for a browsable folder"
/// (img-manager `frontend/src/lib/folderTree.ts:36-37`). Spelling that as a separate case is how
/// the same promise is carried by the type system here: there is no folder id on a fold to hand
/// to `GridStore.selectShoot(folderID:sourceTier:)`, so nothing can.
enum FolderTreeItemID: Hashable, Sendable {
  case folder(Int)
  case month(String)
}

/// A synthetic month row — presentation only, ported from the web's `MonthItem`
/// (`folderTree.ts:39-47`). It folds the `YYYY-MM-DD…` children of ONE year folder: no folder
/// identity, never navigable, and no workflow value of any kind. Whether a year or month row may
/// ever show a readiness roll-up is IMGMGR-342's AC4; this consumes that answer, default none.
struct FolderTreeMonth: Equatable, Sendable {
  /// The year folder this fold sits under — what makes `key` unique across the whole tree.
  let parentID: Int
  /// `2026` and `09`, exactly as they were read off the member folders' own names.
  let year: String
  let month: String
  /// What the row says; `monthLabel`'s rule, ported verbatim.
  let label: String
  /// The sum of its members' SERVER counts (`descendant_image_count`; `folderTree.ts:44-45`,
  /// `:262`) — display arithmetic over image counts, never over workflow state, and never a
  /// substitute for a folder row's own served number.
  let count: Int

  /// `${parentFolderId}:${yyyy}-${mm}` — the web's own synthetic key (`folderTree.ts:41-42`,
  /// `:254`), unique tree-wide, hence a string identity rather than a number.
  var key: String { "\(parentID):\(year)-\(month)" }
}

/// One row of the tree as it RENDERS: a real folder, or a month fold of a year folder's dated
/// children. The web's `TreeItem` (`folderTree.ts:49`).
///
/// A `.folder` case keeps the `FolderTreeNode` the forest built — whose own `children` are the
/// UNFOLDED taxonomy — beside the children that actually render, because the fold changes that
/// shape and nothing else about the node. Everything on screen reads the case's `children`
/// (`visibleRows`, the row view), so there is exactly one answer to "what is under this row".
/// `Equatable` for the reason `FolderTreeNode` states: a whole rendered forest is one comparable
/// value, folds and unfolded taxonomy included, so a test can assert the OFF path equals today's
/// tree without inventing a lossy signature of it.
enum FolderTreeItem: Identifiable, Equatable {
  case folder(FolderTreeNode, children: [FolderTreeItem])
  case month(FolderTreeMonth, members: [FolderTreeItem])

  var id: FolderTreeItemID {
    switch self {
    case .folder(let node, _): return .folder(node.id)
    case .month(let month, _): return .month(month.key)
    }
  }

  /// The rows drawn one level in.
  var children: [FolderTreeItem] {
    switch self {
    case .folder(_, let children): return children
    case .month(_, let members): return members
    }
  }

  /// The folder this row IS, or `nil` on a fold. The single place the "a month is no folder"
  /// promise is enforced: a caller that needs a folder cannot obtain one from a month row.
  var node: FolderTreeNode? {
    switch self {
    case .folder(let node, _): return node
    case .month: return nil
    }
  }
}

/// One rendered line of the folded tree: a row and how deep it sits, keyed by the row's own
/// identity — the row contract the un-folded tree used, widened so a fold can carry a line too.
struct FolderTreeItemRow: Identifiable {
  let item: FolderTreeItem
  let depth: Int

  var id: FolderTreeItemID { item.id }
  var isExpandable: Bool { !item.children.isEmpty }

  /// The folder this row navigates AS, or `nil` on a fold — `FolderTreeItem.node`'s promise read
  /// once, at the row. The view's tap MECHANISM turns on exactly this question (a tagged folder
  /// row carries a gesture, a fold carries a Button; see `FolderTreeSection`), so it is a named
  /// row property rather than an `item.node` unwrap repeated inside a view builder.
  var folderID: Int? { item.node?.id }

  /// What a tap ANYWHERE on this row does (IMGMGR-405, widening IMGMGR-400). Derived here rather
  /// than decided inside the view, so the rule is one value a unit test reads instead of a branch
  /// only a device could disagree with — which is how each half of two device-pass reports stayed
  /// shipped: a container's name did nothing, a non-dated folder did nothing at all, and then a
  /// month row still expanded only from its chevron.
  ///
  /// The web is the design decision (p3396, "the same folder view on the ios app as on web"):
  /// `FolderTreeBranch.vue:63` selects ANY folder on its name, `:95`/`:103` toggle a month on its
  /// label, and the chevron (`:50`) toggles either way. IMGMGR-405 adds what the desktop trees
  /// this one is modelled on (Google Drive, the VS Code explorer, `DisclosureGroup`) all do: a
  /// row with children opens on the same tap that enters it, and a second tap on the row you are
  /// already standing in closes it again.
  ///
  /// Which is why this takes the view's state instead of being a property: "already open" and
  /// "already the selected folder" are the two facts that separate an opening tap from a closing
  /// one, and neither is knowable from the tree alone. A FOLD is no folder
  /// (`FolderTreeItemID`), so it only ever toggles; a row with neither children nor a folder is
  /// inert rather than pretending to be one of them.
  ///
  /// `isSelectableShoot` is deliberately NOT read here. It still answers which rows are SHOOTS —
  /// cover thumbnail, count subline, readiness badge, the `folderRow-`/`folderContainer-`
  /// identifier split (`FolderTreeRowPresentation`) — and that vocabulary is unchanged; only the
  /// tap was widened.
  func tapAction(isOpen: Bool, isSelected: Bool) -> FolderTreeRowTapAction {
    guard let folderID else {
      guard isExpandable else { return .inert }
      return isOpen ? .collapse : .expand
    }
    guard isExpandable else { return .openFolder(folderID, expanding: false) }
    guard isOpen else { return .openFolder(folderID, expanding: true) }
    // Standing in the folder already: the tap is the reader closing the branch, so it must not
    // re-enter a grid that is already on screen. Not selected means the row is merely open under
    // someone else's selection, and a tap there is still "take me into this folder".
    return isSelected ? .collapse : .openFolder(folderID, expanding: false)
  }
}

/// What a tap on a tree row can do (IMGMGR-405, recut from IMGMGR-400's three). A value rather
/// than a closure so the decision is testable apart from the view that performs it.
enum FolderTreeRowTapAction: Equatable, Sendable {
  /// Select the row and enter the grid — `GridStore.selectShoot(folderID:sourceTier:)`, the one
  /// path every row into the grid has always taken. `expanding` is the collapsed-parent case: one
  /// tap both opens the branch and enters it, which is what a tree the reader is browsing with
  /// one thumb has to do to be worth the tap.
  case openFolder(Int, expanding: Bool)
  /// Open this row's children without navigating — a fold, which has no folder to enter.
  case expand
  /// Close this row's children, leaving whatever is on the other side of the split view alone.
  case collapse
  /// Nothing to open and nothing to expand.
  case inert
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

  // MARK: - The tier's rendered rows (IMGMGR-350 P1, ported from lib/folderTree.ts)

  /// The rows ONE tier renders, in the web's own composition order (`buildTierItems`,
  /// `folderTree.ts:277-286`): the archive prune, then the tier-root hoist, then the month fold.
  ///
  /// IMGMGR-362 (WP21 P3) added the first of those. `pruneMirroredArchive` is the reader's
  /// persisted switch (`GridPreferences.pruneMirroredArchive`, default OFF), and it defaults to
  /// `false` HERE too so that every caller that asks for nothing gets exactly the tree IMGMGR-350
  /// shipped — the OFF path is not a second code path, it is this one with no prune in it.
  ///
  /// The prune is the ARCHIVE's alone (`folderTree.ts:283`): a zero count means "already in the
  /// incoming library" only on the tier whose counts are dedup-adjusted, so the incoming and
  /// edits tiers are never pruned however the flag stands.
  ///
  /// Takes an already-built forest rather than the wire rows, so the client-side NAME FILTER —
  /// the native-only step the web has no equivalent of — runs between `forest` and this. That
  /// order is what keeps a search hit's ancestors visible before anything is folded, and it keeps
  /// a month row impossible to build over a member the filter dropped.
  static func tierItems(
    _ forest: [FolderTreeNode], tier: FolderTreeTier, pruneMirroredArchive: Bool = false
  ) -> [FolderTreeItem] {
    let kept = tier == .archive && pruneMirroredArchive ? pruneMirrored(forest) : forest
    return groupMonths(hoistTierRoot(kept, tier: tier))
  }

  /// Drop every folder whose dedup-adjusted count is zero — the archive's fully mirrored ones.
  /// Ported from the web's `pruneMirrored` (`folderTree.ts:188-197`).
  ///
  /// Per node, and that is enough: `descendant_image_count` is a ROLLUP (each folder's own
  /// visible images plus every descendant's, img-manager `app/api/folders.py`), so a folder
  /// reporting zero has an all-zero subtree and cannot be hiding a child with photographs in it.
  /// A partially mirrored folder counts its archive-only members, keeps its row, and loses only
  /// the mirrored children beneath it — which is why this recurses into the SURVIVORS rather than
  /// filtering a flattened list.
  ///
  /// Composed BEFORE the month fold (see `tierItems`), which is what makes an emptied month row
  /// impossible rather than something to clean up afterwards: a month exists only if a surviving
  /// date folder asked for it.
  ///
  /// No OFF mode of its own, deliberately: the flag is read once, at the composition. A
  /// `pruneMirrored(forest, enabled:)` that returned its input would put the reader's preference
  /// in two places, and the OFF path would then be a code path that can drift from the shipped
  /// tree instead of being it.
  static func pruneMirrored(_ forest: [FolderTreeNode]) -> [FolderTreeNode] {
    forest.compactMap { node in
      // `== 0`, exactly the web's test (`folderTree.ts:191`) and not `> 0`: the rule is "the
      // server counted nothing here", never a client-side opinion about what a number means.
      guard node.descendantImageCount != 0 else { return nil }
      return FolderTreeNode(folder: node.folder, children: pruneMirrored(node.children))
    }
  }

  /// Drop the tier's own root row when — and only when — the tier IS that root: a single
  /// top-level node, indexed as a root (`parent_id` null), whose `path` is the tier's canonical
  /// tree. Ported from `hoistTierRoot` (`folderTree.ts:166-175`).
  ///
  /// `archive` is never hoisted: its top level is 14 real trees, not one wrapper. The identity
  /// check stays as narrow as the web's for the same reason — `forest` also promotes orphans
  /// whose parent row is simply absent from the response, and a lone orphan is a real folder that
  /// must keep its row.
  ///
  /// This is the one place `path` is read, and it is read as an IDENTITY, never as a hierarchy:
  /// the forest is still built from `parent_id` and nothing else (this type's own note above).
  /// The question is "is this row the tier's own root directory", which is exactly what the web
  /// asks of the same field.
  ///
  /// The web additionally returns the hoisted root's id so the tier LABEL can carry that folder's
  /// selection (`TierItems.hoistedRootId`, `:51-56`). The native tier label is a disclosure
  /// control and not a navigable row, so there is nothing here to carry it — omitted knowingly,
  /// not dropped.
  static func hoistTierRoot(_ forest: [FolderTreeNode], tier: FolderTreeTier) -> [FolderTreeNode] {
    guard tier != .archive, let prefix = tier.treePrefix else { return forest }
    guard forest.count == 1, let root = forest.first else { return forest }
    guard root.folder.parentId == nil, root.folder.path == prefix else { return forest }
    return root.children
  }

  /// Group the `YYYY-MM-DD…` children of every YEAR folder into synthetic month rows, ported from
  /// `groupMonths` (`folderTree.ts:222-229`). Anything else the year holds keeps its place after
  /// the months (`groupChildrenByMonth`, `:231-266`), so a stray `misc` folder stays visible
  /// rather than being sorted into a month it is not in.
  static func groupMonths(_ forest: [FolderTreeNode]) -> [FolderTreeItem] {
    forest.map { node in
      let children = groupMonths(node.children)
      guard isYearName(node.name) else { return .folder(node, children: children) }
      return .folder(node, children: foldByMonth(parent: node, children: children))
    }
  }

  /// One year folder's children, folded. Months first in calendar order (the key is `yyyy-mm`, so
  /// sorting the keys IS the calendar order — `folderTree.ts:232-233`, `:264`), everything else
  /// after them in the order it already had.
  private static func foldByMonth(parent: FolderTreeNode, children: [FolderTreeItem])
    -> [FolderTreeItem]
  {
    var keys: [String] = []
    var members: [String: [FolderTreeItem]] = [:]
    var counts: [String: Int] = [:]
    var stamps: [String: (year: String, month: String)] = [:]
    var rest: [FolderTreeItem] = []
    for child in children {
      // A fold cannot itself be folded, and a name that is not a date is a name: both keep their
      // place instead of conjuring a month (`folderTree.ts:236-247`).
      guard let node = child.node, let stamp = monthStamp(of: node.name) else {
        rest.append(child)
        continue
      }
      let key = "\(stamp.year)-\(stamp.month)"
      if members[key] == nil {
        keys.append(key)
        stamps[key] = stamp
      }
      members[key, default: []].append(child)
      counts[key, default: 0] += node.descendantImageCount
    }
    let months: [FolderTreeItem] = keys.sorted().compactMap { key in
      guard let stamp = stamps[key] else { return nil }
      let month = FolderTreeMonth(
        parentID: parent.id, year: stamp.year, month: stamp.month,
        label: monthLabel(year: stamp.year, month: stamp.month, parentName: parent.name),
        count: counts[key] ?? 0)
      return .month(month, members: members[key] ?? [])
    }
    return months + rest
  }

  /// The web's `YEAR_NAME` (`^\d{4}$`, `folderTree.ts:73`): four digits and nothing else.
  static func isYearName(_ name: String) -> Bool {
    name.count == 4 && name.allSatisfy { $0.isASCII && $0.isNumber }
  }

  /// The `YYYY-MM` a folder name STARTS with, or `nil` — the web's `DATE_NAME`
  /// (`^(\d{4})-(\d{2})-\d{2}`, `folderTree.ts:74`) plus its month-range guard (`:244`: "a
  /// `2025-13-01` folder is a name, not a month"), written as a prefix walk so the rule is
  /// legible without a regex engine. The live names carry a title after the date
  /// (`2026-09-14 — Wandern`), which the regex's unanchored tail ignores and so does this.
  static func monthStamp(of name: String) -> (year: String, month: String)? {
    let head = Array(name.prefix(10))
    guard head.count == 10, head[4] == "-", head[7] == "-" else { return nil }
    guard [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ head[$0].isASCII && head[$0].isNumber }) else {
      return nil
    }
    let month = String(head[5..<7])
    guard let value = Int(month), (1...12).contains(value) else { return nil }
    return (String(head[0..<4]), month)
  }

  /// The calendar DAY a folder name starts with (IMGMGR-549: "a folder is one day"), or `nil`.
  /// The same `YYYY-MM-DD` prefix `monthStamp(of:)` reads, but a day the calendar does not have
  /// (`2026-02-30`, `2026-13-01`, `2026-04-31`) is a name, not a day: the components are built
  /// into a date in a UTC Gregorian calendar and must come back unchanged. A `dated_split`
  /// continuation (`2026-09-14-wandern-2`) still starts with its date and parses to that day.
  static func dayStamp(of name: String) -> (year: Int, month: Int, day: Int)? {
    guard monthStamp(of: name) != nil else { return nil }
    let head = Array(name.prefix(10))
    guard let year = Int(String(head[0..<4])), let month = Int(String(head[5..<7])),
      let day = Int(String(head[8..<10]))
    else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let components = DateComponents(year: year, month: month, day: day)
    guard let date = calendar.date(from: components) else { return nil }
    let back = calendar.dateComponents([.year, .month, .day], from: date)
    guard back.year == year, back.month == month, back.day == day else { return nil }
    return (year, month, day)
  }

  /// The fold's own text, ported verbatim (`monthLabel`, `folderTree.ts:212-215`): the lowercase
  /// English month name, with the year appended only where it differs from the parent folder's
  /// own name. Deliberately the WEB's wording — the owner's decision is "the same folder view on
  /// the ios app as on web", and this is the one row in the tree whose text no server supplies.
  private static func monthLabel(year: String, month: String, parentName: String) -> String {
    let index = (Int(month) ?? 0) - 1
    guard monthNames.indices.contains(index) else { return "\(year)-\(month)" }
    return year == parentName ? monthNames[index] : "\(monthNames[index]) \(year)"
  }

  private static let monthNames = [
    "january", "february", "march", "april", "may", "june", "july", "august", "september",
    "october", "november", "december",
  ]

  /// The rows that are actually on screen, in order, each carrying its own depth — the tree
  /// rendered as a flat list rather than as nested `DisclosureGroup`s, and keyed by
  /// `FolderTreeItemID` so a fold opens and closes without ever being confusable with a folder.
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
    _ items: [FolderTreeItem], isExpanded: (FolderTreeItemID) -> Bool
  ) -> [FolderTreeItemRow] {
    var rows: [FolderTreeItemRow] = []
    func walk(_ items: [FolderTreeItem], depth: Int) {
      for item in items {
        rows.append(FolderTreeItemRow(item: item, depth: depth))
        if !item.children.isEmpty, isExpanded(item.id) {
          walk(item.children, depth: depth + 1)
        }
      }
    }
    walk(items, depth: 0)
    return rows
  }

  /// The rows that have to be OPEN for `folderID`'s own row to be on screen — every ancestor on
  /// the path to it, folders and month folds alike, and never the folder's own row (IMGMGR-405
  /// rule 6: revealing a selection must not also expand the thing being revealed, or a reader who
  /// just collapsed it would watch it spring back open).
  ///
  /// Pure, and separate from the reveal itself, because the reveal has to run in three unrelated
  /// places — a tree that finishes loading with a selection already made, a relaunch that restores
  /// one (`RootView.swift:294`), and a selection made in another column — and a rule written three
  /// times is three rules. Empty where the folder is top-level (nothing to open) and where it is
  /// absent from this tier's rows at all, which is the normal answer for two of the three tiers.
  static func ancestorRowIDs(
    ofFolder folderID: Int, in items: [FolderTreeItem]
  ) -> Set<FolderTreeItemID> {
    var ancestors: Set<FolderTreeItemID> = []
    func walk(_ items: [FolderTreeItem], trail: [FolderTreeItemID]) -> Bool {
      for item in items {
        if item.node?.id == folderID {
          ancestors = Set(trail)
          return true
        }
        if walk(item.children, trail: trail + [item.id]) { return true }
      }
      return false
    }
    _ = walk(items, trail: [])
    return ancestors
  }

  /// Whether this tier's rows hold `folderID` at all. Separate from `ancestorRowIDs` because that
  /// one answers the EMPTY set for two different facts — a top-level folder has no ancestors, and
  /// so has a folder that is not in this tier — and the reveal has to tell them apart: the first
  /// still needs its tier branch opened, the second must not touch that tier at all.
  static func containsFolder(_ folderID: Int, in items: [FolderTreeItem]) -> Bool {
    items.contains { $0.node?.id == folderID || containsFolder(folderID, in: $0.children) }
  }

  /// Everything that has to be OPEN for one folder's row to be reachable on the home — the TIER
  /// branch it lives under as well as the rows inside it (IMGMGR-405 rule 6, round-2 finding 2).
  ///
  /// The tier is the half a reveal built only out of ancestors forgets: `FolderTreeSection`
  /// renders each tier as a `DisclosureGroup` whose expansion is its own state, so a restored
  /// selection under a closed Incoming/Edits/Archive branch stayed invisible however many row
  /// ancestors were opened — and a TOP-LEVEL folder in a closed tier has no row ancestors at all,
  /// which is the case an ancestors-only rule cannot even express.
  ///
  /// One value over all three tiers rather than a loop in the view, so "which tiers open, which
  /// rows open" is a thing a test reads. A folder no tier holds produces an empty plan, and so
  /// does no selection: the reveal is then a no-op rather than a special case at the call site.
  static func revealPlan(
    folderID: Int?, itemsByTier: [FolderTreeTier: [FolderTreeItem]]
  ) -> FolderTreeRevealPlan {
    var plan = FolderTreeRevealPlan()
    guard let folderID else { return plan }
    for (tier, items) in itemsByTier where containsFolder(folderID, in: items) {
      plan.tiers.insert(tier)
      plan.rows.formUnion(ancestorRowIDs(ofFolder: folderID, in: items))
    }
    return plan
  }
}

/// What a reveal has to open: tier branches and rows, the two pieces of expansion state the home
/// keeps (`FolderTreeSection.expandedTiers` / `expandedBranches`). A value, so the rule is
/// testable without a view — and additive by construction at the call site, which is what keeps a
/// branch the reader closed by hand closed unless it stands between them and their own selection.
struct FolderTreeRevealPlan: Equatable {
  var tiers: Set<FolderTreeTier> = []
  var rows: Set<FolderTreeItemID> = []
}
