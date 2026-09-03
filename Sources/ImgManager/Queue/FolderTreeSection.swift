import Foundation
import ImgManagerAPI
import SwiftUI

/// The "Folders" disclosure below the queue: the second way into the grid, on BOTH idioms since
/// P6 (IMGMGR-216). Built from the EXISTING `GET /api/folders` (`FolderNode`: parent_id + name),
/// NEVER from summaries (flat, no tree fields). Local and Archive tier branches; each row routes
/// through the ONE atomic `GridStore.selectShoot(folderID:sourceTier:)` entry point, so a tree
/// tap always sets the complete destination `(folderID, sourceTier)` in a single scope
/// transition — never a separate follow-up `applyFilterChange` call.
///
/// P6 (IMGMGR-216): this used to be iPad-only. `RootView.sidebar` passed `treeSection: nil` on
/// Compact, so the phone's only navigation was whichever shoots happened to be queue cards, and
/// every other shoot was unreachable there. No such branch exists anywhere now — one component,
/// both idioms — and `QueueView.treeSection` is non-optional so it cannot come back without a
/// type change. The ONLY thing that varies with the layout mode is the disclosure's INITIAL
/// expansion, decided once in `FolderTreePresentation` where a test can read it.
///
/// P7 (IMGMGR-217) turns the flat dated-leaf list into the server's actual hierarchy, with the
/// server's counts and a search field: `FolderTreeModel` does the thinking (forest from
/// `parent_id`, client-side name filter), this file only renders it. Three properties are worth
/// stating because they are easy to break:
///
/// - a row that is not a shoot EXPANDS but does not navigate (`FolderTreeNode.isSelectableShoot`,
///   still `ShootListFilter`'s single definition), so the tree can show containers without
///   inventing a second navigation entry point;
/// - the count on every row is `descendant_image_count` straight off the wire, which is exactly
///   the population a tap opens (`/api/images` resolves `folder_id` to the whole subtree), so the
///   badge and the grid can never disagree;
/// - the tree renders as a FLAT list of open rows with a depth inset (`FolderTreeModel
///   .visibleRows`), not as nested `DisclosureGroup`s, and expanding is its own chevron Button
///   separate from the name's tap target — on the 110 production folders that are both a shoot
///   and a parent, opening a subtree must not also navigate into the grid. Nothing here is
///   gesture-only: every row, every chevron and the search field are chrome.
struct FolderTreeSection: View {
  let gridService: GridService
  /// The SAME loader the queue cards use (WP16 P5) — one actor, one cache keyed by
  /// `(folderID, sourceTier)`, one 4-slot concurrency gate. Never a second image pipeline.
  ///
  /// What that cache does and does not buy, stated exactly (diff-gate r1, B2, correcting this
  /// phase's own first claim): once a cover has been fetched, every later reader of that key —
  /// queue card or tree row — is served from memory. It does NOT coalesce fetches already IN
  /// FLIGHT: `HeroThumbnailLoader.hero` checks the cache, then suspends on the concurrency gate
  /// (`HeroThumbnailLoader.swift:38-44`), so a shoot visible as a queue card AND as a tree row at
  /// the same time, before either finishes, fetches twice. Cheap and read-only, but real.
  let heroLoader: HeroThumbnailLoader
  let layoutMode: LayoutMode
  /// Bumped by a pull-to-refresh on the home (`QueueHomeRefresh`, `QueueView`), which is the one
  /// thing that re-runs the tree load — the load itself is view state, so the gesture reaches it
  /// as a value the `.task(id:)` below keys on rather than as a call.
  let reloadToken: Int
  /// The queue's answers, keyed by `folder_id` (IMGMGR-350 P3) — what the row badge reads. It is
  /// a VALUE the composition root hands over, not a store this view observes: the tree renders
  /// without it (checkpoint-2 finding B1), and an empty join is simply a tree with no badges.
  let summariesByFolderID: [Int: Components.Schemas.FolderSummary]
  /// P4: whatever tree `QueueStore` has remembered for this account and server, replayed when a
  /// live load reaches nothing at all. The view keeps no persistence of its own.
  let cachedTree: QueueStore.CachedTree?
  /// P4: hands a live answer back to the store, which owns when and whether it is written. F3/F4:
  /// the fence the fetch STARTED under travels with it, so a response that outlived its session
  /// is refused by the store rather than written under whatever is true when it lands.
  let rememberTree:
    ([FolderTreeTier: [Components.Schemas.FolderNode]], QueueStore.TreeFence) async -> Void
  /// The fence as it stands when a load is about to start.
  let treeFence: () -> QueueStore.TreeFence
  @Binding var selectedFolderID: Int?
  let onSelect: (Int, GridSourceTier) -> Void

  @State private var load = FolderTreeLoad.loading
  @State private var searchText = ""
  /// The rows the reader has opened — folders AND month folds, hence the widened identity
  /// (`FolderTreeItemID`): a fold opens and closes like a branch and is selectable like nothing.
  @State private var expandedBranches: Set<FolderTreeItemID> = []
  @State private var expandedTiers: Set<FolderTreeTier> = []
  /// F3: which tree load is the current one. Advanced by every start, checked by every finish.
  @State private var treeLoadGeneration = 0

  var body: some View {
    Group {
      if load.phase != .loading {
        // IMGMGR-174: a load that failed says so, above whatever rows did arrive. It sits FIRST
        // because a partial failure still renders a tree underneath it, and a note below rows the
        // reader has already started scanning is a note they will not read.
        failureNotice
        searchField
        ForEach(FolderTreeTier.allCases, id: \.self) { tier in
          tierBranch(tier)
        }
        if isSearching, everyTierIsEmpty {
          Text("No folders match")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("folderTreeNoMatches")
        } else if !isSearching,
          FolderTreeLoadPresentation.showsEmptyLibrary(
            for: load.phase, everyTierIsEmpty: everyTierIsEmpty)
        {
          // The queue's own empty state, moved with the home it belonged to (IMGMGR-350 P2):
          // "No shoots" used to key off `QueueSort.sections(from:)` being empty in `QueueView`,
          // which no longer renders anything. A genuinely empty library must still say so, and
          // the tree is now the only surface that knows it is empty.
          ContentUnavailableView("No shoots", systemImage: "photo.stack")
            .accessibilityIdentifier("folderTreeEmpty")
        }
      } else {
        // The three folder calls this waits on measured ~0.6 s (local) and ~2.5 s (archive)
        // server-side against production on 2026-08-30 — a home with no rows under it reads as
        // "this library has no folders" for those seconds. It says Loading instead.
        ProgressView()
      }
    }
    // IMGMGR-350 P2: the load re-runs whenever the reader pulls to refresh, which is what
    // `reloadToken` carries (`QueueHomeRefresh`). `.task(id:)` also runs it once on mount, so
    // there is exactly one fetch path here and it is still the one a retry drives.
    .task(id: reloadToken) {
      await runTreeLoad()
    }
  }

  /// The ONE fetch path (F3): both entries — the `.task(id:)` and Retry — run this, so there is
  /// no second place where a response could be published under different rules.
  ///
  /// The generation and the store's fence are captured BEFORE the request leaves and checked
  /// after it lands. A load that is no longer current, or that was cancelled, publishes nothing
  /// and writes nothing — it does not clear, and it does not report itself as a failure.
  private func runTreeLoad() async {
    treeLoadGeneration += 1
    let generation = treeLoadGeneration
    let fence = treeFence()
    let fresh = await FolderTreeLoad.perform(using: gridService)
    guard FolderTreeLoadGate.accepts(fresh, generation: generation, current: treeLoadGeneration)
    else { return }
    load = FolderTreeLoad.resolve(fresh: fresh, cached: cachedTree)
    // Only a clean answer is worth remembering: a partial one would persist a tier's absence as
    // if it were its content, and the next launch would replay that as the library.
    if fresh.phase == .loaded { await rememberTree(fresh.foldersByTier, fence) }
  }

  /// Whether the whole tree — every tier, after whatever the search field kept — is empty. Read
  /// twice above for two different states, which is why it is a property rather than a repeated
  /// expression: "nothing matched" and "there is nothing" are different sentences.
  private var everyTierIsEmpty: Bool {
    FolderTreeTier.allCases.allSatisfy { branches(for: $0).isEmpty }
  }

  /// The visible half of IMGMGR-174: what a failed (or half-failed) load says, and the one way
  /// back from it. Retry re-runs the SAME `FolderTreeLoad.perform` the `.task` ran — there is no
  /// second fetch path that could behave differently — and returns to `.loading` first so the
  /// spinner replaces the notice while it is in flight, rather than leaving a stale failure on
  /// screen. Chrome, not a gesture: the whole recovery is a labelled button.
  @ViewBuilder
  private var failureNotice: some View {
    if let message = FolderTreeLoadPresentation.message(for: load.phase) {
      VStack(alignment: .leading, spacing: 4) {
        Label(message, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("folderTreeLoadError")
        Button("Retry") {
          Task {
            load = .loading
            await runTreeLoad()
          }
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("folderTreeRetry")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var trimmedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isSearching: Bool { !trimmedSearch.isEmpty }

  /// The tier's rows: the server's forest, narrowed by whatever is in the search field, then
  /// hoisted and folded into the rows that render (`FolderTreeModel.tierItems`). Every step is
  /// pure and lives in `FolderTreeModel` — this view holds no derived state of its own, so there
  /// is nothing here that can go stale against the loaded response.
  ///
  /// The filter runs BEFORE the fold on purpose: a month row is built only out of members the
  /// search kept, so no synthetic row is ever left standing over nothing.
  private func branches(for tier: FolderTreeTier) -> [FolderTreeItem] {
    FolderTreeModel.tierItems(
      FolderTreeModel.filter(
        FolderTreePresentation.tree(for: layoutMode, folders: load.folders(tier)),
        matching: searchText),
      tier: tier)
  }

  /// Searching the 855 already-loaded folder NAMES, in memory. Never `GridImagesQuery.q` — that
  /// one is an image-level browse filter and answers a different question — and never a second
  /// call to the server for something the client is already holding.
  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField("Search folders", text: $searchText)
        .textFieldStyle(.plain)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .submitLabel(.search)
        .accessibilityIdentifier("folderTreeSearchField")
      if isSearching {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Clear the folder search")
        .accessibilityIdentifier("folderTreeSearchClear")
      }
    }
  }

  @ViewBuilder
  private func tierBranch(_ tier: FolderTreeTier) -> some View {
    let rows = FolderTreeModel.visibleRows(branches(for: tier)) { id in
      FolderTreePresentation.isExpanded(
        id, readerExpanded: expandedBranches, isSearching: isSearching)
    }
    if !load.answered(tier) {
      // B3: the tier is a top-level PLACE, so its absence is said where it belongs rather than
      // only in the summary notice at the top — and never by rendering it as an empty branch.
      Label(
        FolderTreeLoadPresentation.tierMessage(for: tier), systemImage: "exclamationmark.triangle"
      )
      .foregroundStyle(.secondary)
      // Combined into ONE element before the identifier is applied: a `Label` publishes its icon
      // and its text as separate children, and the first gate run found the identifier sitting on
      // the IMAGE — present, and never hittable, so a walk that looks for the row could not
      // reach it (`TreeHomeDegradedUITests`).
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("folderTreeTierFailed-\(tier.label)")
    } else if !rows.isEmpty {
      DisclosureGroup(isExpanded: tierBinding(tier)) {
        // One flat ForEach over the OPEN rows, keyed by each row's own identity — the server's
        // folder id, or a fold's synthetic key — never an index (IMGMGR-210), and never a second
        // nested container per level: the depth is a leading inset, so a branch three deep is
        // still one row in one list.
        ForEach(rows) { row in
          FolderTreeRowView(
            row: row, tier: tier, isSearching: isSearching, heroLoader: heroLoader,
            summariesByFolderID: summariesByFolderID,
            expandedBranches: $expandedBranches, selectedFolderID: $selectedFolderID,
            onSelect: onSelect)
        }
      } label: {
        Text(tier.label).accessibilityIdentifier("folderTreeTier-\(tier.label)")
      }
    }
  }

  /// A live search opens both tier branches for the same reason it opens the matched folders: a
  /// hit the reader cannot see is not a search result. The reader's own choice is what decides
  /// once the field is empty again.
  private func tierBinding(_ tier: FolderTreeTier) -> Binding<Bool> {
    Binding(
      get: {
        FolderTreePresentation.isExpanded(
          for: tier, in: expandedTiers, isSearching: isSearching)
      },
      set: { open in
        if open {
          expandedTiers.insert(tier)
        } else {
          expandedTiers.remove(tier)
        }
      })
  }
}

/// The Folders disclosure's two per-tier fetches and what they produced — lifted out of the
/// view's `.task` so a test can drive it (IMGMGR-174). A value, and one `async` function that
/// makes it, for the same reason `FolderTreePresentation`/`QueueSort` are pure: the decision is
/// then something a test reads directly rather than a `.task` body nothing can reach.
///
/// The extraction changed nothing about WHAT happens: both fetches are still swallowed with
/// `try?` and the section still ends up "loaded" whatever occurred — which is exactly the shipped
/// defect the tests beside it now name. `GridService` collapses a non-ok status and a decode
/// failure alike into one opaque `.unreachable`, so a silent failure and a genuinely empty
/// library render the identical empty disclosure (found while diagnosing IMGMGR-173, session
/// review /link/3237).
struct FolderTreeLoad: Equatable, Sendable {
  /// Four rendered states. `.loaded` with every tier empty IS the genuinely-empty library — a
  /// successful response carrying no rows — which is precisely the state a failure must never be
  /// confused with.
  enum Phase: Equatable, Sendable {
    case loading
    case loaded
    /// SOME tiers answered and others did not: the rows that arrived are real and worth showing,
    /// beside a note naming what is missing. It carries a LIST since IMGMGR-350 P1, because the
    /// browse tiers are three and any one or two of them can fail on their own.
    case partiallyFailed([FolderTreeTier])
    case failed
    /// IMGMGR-350 P4: nothing answered and there is a remembered answer to show instead, carrying
    /// the moment the server said it. The same trade IMGMGR-198 already makes for the summaries.
    case stale(Date)
    /// Checkpoint-3 finding F3: the load was CANCELLED — the view was replaced, or a newer load
    /// took its place. Not a failure and not an answer: a cancelled load publishes nothing and
    /// writes nothing, where before it arrived as three unreachable tiers and overwrote the tree
    /// with an empty one.
    case cancelled
  }

  var phase: Phase = .loading
  /// One entry per tier that answered. Keyed rather than three named arrays because the tiers
  /// are the `FolderTreeTier` cases and nothing else — adding `edits` must not mean adding a
  /// third property, a third fetch branch and a third failure case by hand.
  var foldersByTier: [FolderTreeTier: [Components.Schemas.FolderNode]] = [:]

  /// What one tier loaded. Empty where it failed AND where it is genuinely empty, which is why
  /// `answered(_:)` below exists: the two are different facts and only one of them is "there are
  /// no folders here".
  func folders(_ tier: FolderTreeTier) -> [Components.Schemas.FolderNode] {
    foldersByTier[tier] ?? []
  }

  /// Whether this tier ANSWERED at all (checkpoint-2 finding B3). An unknown tier is not an empty
  /// tier: a folder-load failure used to render as "No shoots" — the copy for a library with
  /// nothing in it — beside a notice saying the opposite.
  func answered(_ tier: FolderTreeTier) -> Bool {
    foldersByTier[tier] != nil
  }

  /// The pre-fetch value the view starts from, and the one a retry returns to.
  static let loading = FolderTreeLoad()

  /// What the tree RENDERS after one attempt, given whatever the store remembered (P4).
  ///
  /// A total failure with a cache replays it, labelled stale. A PARTIAL failure keeps the live
  /// result: some tiers answered, and mixing a live tier with a remembered one would put two
  /// different moments on one screen with nothing on it saying which is which.
  static func resolve(fresh: FolderTreeLoad, cached: QueueStore.CachedTree?) -> FolderTreeLoad {
    guard case .failed = fresh.phase, let cached, !cached.foldersByTier.isEmpty else {
      return fresh
    }
    return FolderTreeLoad(phase: .stale(cached.fetchedAt), foldersByTier: cached.foldersByTier)
  }

  /// Both tier fetches, and the one place their outcomes become a rendered state. A throw is
  /// RECORDED rather than swallowed (IMGMGR-174): `GridService.folders` throws only
  /// `.unreachable` — it collapses a non-ok status and a decode failure into that one case — so
  /// what a failure means cannot be reported, but THAT there was one always can, and that is the
  /// difference between an empty tree and a broken one.
  static func perform(using service: GridService) async -> FolderTreeLoad {
    var result = FolderTreeLoad()
    var failed: [FolderTreeTier] = []
    for tier in FolderTreeTier.allCases {
      do {
        result.foldersByTier[tier] = try await service.folders(tier: tier).items
      } catch {
        // A cancelled load is not a failed one: `GridService` collapses every error into one
        // opaque `.unreachable`, so cancellation would otherwise arrive here as a dead tier and
        // be written over a perfectly good tree.
        if Task.isCancelled { return FolderTreeLoad(phase: .cancelled) }
        failed.append(tier)
      }
      if Task.isCancelled { return FolderTreeLoad(phase: .cancelled) }
    }
    switch failed.count {
    case 0: result.phase = .loaded
    case FolderTreeTier.allCases.count: result.phase = .failed
    default: result.phase = .partiallyFailed(failed)
    }
    return result
  }
}

/// Checkpoint-3 finding F3: whether a load that has COME BACK may still be published.
///
/// A tree load is started by `.task(id:)` and by Retry, and the reader can advance the token
/// (pull-to-refresh, a resume) while one is still in flight. Both paths wrote whatever came back,
/// so an older response landing last overwrote a newer tree — and a cancelled load arrived as
/// three unreachable tiers and overwrote it with nothing. The generation is captured BEFORE the
/// fetch and compared after it: same generation and a real answer, or the result is dropped in
/// silence. Nothing here clears or writes; it only says whether the caller may.
enum FolderTreeLoadGate {
  static func accepts(_ load: FolderTreeLoad, generation: Int, current: Int) -> Bool {
    guard generation == current else { return false }
    if case .cancelled = load.phase { return false }
    return true
  }
}

/// What a load phase LOOKS like — the pure half of IMGMGR-174, so the wording and the
/// failure/not-failure split are values a test reads rather than strings buried in a view.
enum FolderTreeLoadPresentation {
  static func isFailure(_ phase: FolderTreeLoad.Phase) -> Bool {
    switch phase {
    case .failed, .partiallyFailed: return true
    // A replayed answer is not a failure: there are real rows on screen, older than now. It says
    // so in its own words (`message(for:)`) rather than through the failure vocabulary.
    case .loading, .loaded, .stale, .cancelled: return false
    }
  }

  /// One tier's own line, for the row that stands where its branch would have been (B3).
  static func tierMessage(for tier: FolderTreeTier) -> String {
    "\(tier.label) folders could not be loaded."
  }

  /// Whether the EMPTY-LIBRARY copy may render (B3). Only a load in which every tier answered can
  /// say "No shoots": with any tier unknown, an empty screen is a missing answer, not an empty
  /// library.
  static func showsEmptyLibrary(for phase: FolderTreeLoad.Phase, everyTierIsEmpty: Bool) -> Bool {
    phase == .loaded && everyTierIsEmpty
  }

  /// Deliberately says what could not be LOADED, never why — `GridService` collapses a non-ok
  /// status and a decode failure into one opaque `.unreachable` (its own doc comment), so a
  /// reason here would be invented rather than reported. `nil` where there is nothing to say.
  static func message(for phase: FolderTreeLoad.Phase) -> String? {
    switch phase {
    case .loading, .loaded, .cancelled: return nil
    case .failed: return "Folders could not be loaded."
    case .partiallyFailed(let tiers):
      // The tier's own label, so the note names the branch the reader can see is missing. Two
      // tiers read as one sentence rather than two notes; all three is `.failed` above, so the
      // join never has a third term to punctuate.
      let named = tiers.map(\.label).joined(separator: " and ")
      return "\(named) folders could not be loaded."
    case .stale(let fetchedAt):
      // P4: the SAME degraded vocabulary the queue's own replay uses (IMGMGR-198), from the one
      // place that owns it — a second wording for the same state is a second state to the reader.
      return "\(DegradedStateCopy.notConnected) "
        + DegradedStateCopy.showingCached(since: fetchedAt)
    }
  }
}

/// One line of the tree: an expand control (only where there is something to expand), the
/// folder's name at its depth, and the server's count — as a subline under the name on a SHOOT
/// row, which also leads with a cover thumbnail (WP16 P5, p3332 decision 2), and as the trailing
/// caption it has always been on a container row. `FolderTreeRowPresentation` owns that split;
/// this view only renders it.
///
/// The two affordances are deliberately SEPARATE controls rather than one `DisclosureGroup`
/// label. 110 production folders are both a shoot and a parent, and with a single combined label
/// a tap meant to open a subtree also navigated into the grid; worse, the composition could not
/// be driven through the real UI at all (gate run 1cfa3f4). Here the chevron toggles and nothing
/// else, the name navigates and nothing else, and each carries its own accessibility identifier.
/// Both are chrome — there is no gesture-only path anywhere in this tree.
private struct FolderTreeRowView: View {
  let row: FolderTreeItemRow
  let tier: FolderTreeTier
  let isSearching: Bool
  let heroLoader: HeroThumbnailLoader
  let summariesByFolderID: [Int: Components.Schemas.FolderSummary]
  @Binding var expandedBranches: Set<FolderTreeItemID>
  @Binding var selectedFolderID: Int?
  let onSelect: (Int, GridSourceTier) -> Void

  @State private var coverImage: PlatformImage?

  var body: some View {
    HStack(spacing: 6) {
      expandControl
      nameAndCount
    }
    .padding(.leading, CGFloat(row.depth) * 14)
  }

  @ViewBuilder
  private var expandControl: some View {
    if row.isExpandable {
      Button {
        if isOpen {
          expandedBranches.remove(row.id)
        } else {
          expandedBranches.insert(row.id)
        }
      } label: {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .rotationEffect(.degrees(isOpen ? 90 : 0))
          .frame(width: 20, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier(FolderTreeRowPresentation.discloseIdentifier(for: row.id))
      .accessibilityLabel(isOpen ? "Collapse \(rowName)" : "Expand \(rowName)")
    } else {
      Color.clear.frame(width: 20, height: 1)
    }
  }

  /// What the row is called — the folder's own name, or the fold's label. Both are read here so
  /// the expand control's accessibility label has one source.
  private var rowName: String {
    switch row.item {
    case .folder(let node, _): return node.name
    case .month(let month, _): return month.label
    }
  }

  @ViewBuilder
  private var nameAndCount: some View {
    if let node = row.item.node, node.isSelectableShoot {
      // Same row-navigation pattern as the pre-P7 sidebar (RootView's own doc comment on this
      // exact fix): `.simultaneousGesture` layered on TOP of the enclosing List's own selection
      // recognizer, never a bare `Button` and never `.onChange(of: selectedFolderID)` — a plain
      // Button never pushes NavigationSplitView's column on Compact, and onChange never fires on
      // a same-value re-tap.
      rowContent
        .contentShape(Rectangle())
        .tag(node.id)
        // The stable, id-derived identifier lives on the row's NAME text, not here: an
        // identifier on a container overrides its descendants' (GridView.swift:743-747), which
        // would make this row's cover and subline unaddressable. `FolderTreeRowPresentation
        // .rowIdentifier` decides the string; `rowContent` applies it.
        .simultaneousGesture(
          TapGesture().onEnded {
            selectedFolderID = node.id
            onSelect(node.id, tier.sourceTier)
          }
        )
    } else {
      // A container, or a month fold: it expands, and it does NOT navigate. A container's
      // identifier is deliberately a different prefix, so `folderRow-<id>` keeps meaning "a row
      // that enters the grid"; a fold's is `folderTreeMonth-…` and names no folder at all. Both
      // are applied on the name text with the shoot's, for the override reason above.
      rowContent
    }
  }

  @ViewBuilder
  private var rowContent: some View {
    switch row.item {
    case .folder(let node, _): folderContent(node)
    case .month(let month, _): monthContent(month)
    }
  }

  private func folderContent(_ node: FolderTreeNode) -> some View {
    HStack(spacing: 8) {
      if FolderTreeRowPresentation.showsThumbnail(node) {
        cover
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(node.name)
          .lineLimit(1)
          .truncationMode(.middle)
          .accessibilityIdentifier(
            FolderTreeRowPresentation.rowIdentifier(for: node, id: node.id))
        // A shoot's own roll-up, one line down: the server's number, never recomputed, and
        // stated ONCE — this is the same count the trailing caption below carries on the
        // container rows, moved rather than duplicated.
        if let subline = FolderTreeRowPresentation.subline(for: node) {
          Text(subline)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(FolderTreeRowPresentation.sublineIdentifier(for: node.id))
        }
        // P3: the shoot's readiness, in the server's own words. Its own line rather than a
        // trailing chip for the reason the queue card's badges were stacked (WP16 P5): a sidebar
        // column is narrow enough that side-by-side captions wrap character by character.
        if let readiness = FolderTreeRowPresentation.readinessBadge(
          for: node, summaries: summariesByFolderID)
        {
          Text(readiness)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityIdentifier(
              FolderTreeRowPresentation.readinessIdentifier(for: node.id))
        }
      }
      Spacer(minLength: 8)
      // The container row's trailing caption: same text, same modifiers, same number as at
      // 4753450 — a folder of folders is not a shoot, so decision 2 leaves it alone. Its
      // enclosing structure is not identical (the name now sits in a one-child VStack that a
      // shoot row fills with a second line), which changes nothing about what is rendered.
      if let trailing = FolderTreeRowPresentation.trailingCount(for: node) {
        Text(trailing)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// A month fold (IMGMGR-350 P1/P2). It carries NO cover and NO selection — it is not a folder,
  /// so there is nothing to open a grid with — and states the web's own count: the sum of its
  /// members' server counts (`folderTree.ts:44-45`), in the same trailing caption a container row
  /// uses, because a fold hides folders exactly as a closed container does.
  private func monthContent(_ month: FolderTreeMonth) -> some View {
    HStack(spacing: 8) {
      Text(month.label)
        .lineLimit(1)
        .accessibilityIdentifier(FolderTreeRowPresentation.monthIdentifier(for: month))
      Spacer(minLength: 8)
      Text(month.count.formatted())
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The shoot row's cover, fetched through the SAME `HeroThumbnailLoader` the queue cards use —
  /// its cache (keyed by folder and tier), its 4-slot concurrency gate and its cancellation —
  /// never a second image pipeline, and never `GridStore`, which the loader is deliberately
  /// independent of. Concurrent fetches of one key are not coalesced; see the loader property's
  /// own comment above for what the cache does and does not promise.
  ///
  /// It renders a PLACEHOLDER until an image arrives, so the row's anatomy is on screen before
  /// any network call finishes and a test can assert the anatomy without asserting the network.
  /// `List` instantiates rows lazily, so only the shoot rows actually on screen ever fetch —
  /// the same load profile the queue cards already impose.
  private var cover: some View {
    Group {
      if let coverImage {
        PlatformImageView(image: coverImage).aspectRatio(contentMode: .fill)
      } else {
        Rectangle().fill(.quaternary)
      }
    }
    .frame(width: 40, height: 40)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .accessibilityElement()
    .accessibilityLabel("Cover thumbnail")
    .accessibilityIdentifier(FolderTreeRowPresentation.thumbnailIdentifier(for: coverFolderID))
    .task(id: coverTaskID) {
      switch await heroLoader.hero(folderID: coverFolderID, sourceTier: tier.sourceTier) {
      case .image(let data):
        if let decoded = PlatformImage(data: data), !Task.isCancelled {
          coverImage = decoded
        }
      case .empty, .failure:
        break
      }
    }
  }

  /// Identity for the cover fetch, in the loader's own cache-key terms: a row that is re-used for
  /// a different folder (or the same folder on the other tier) starts a new fetch, and scrolling
  /// away cancels the one in flight.
  /// The folder a cover belongs to. Only a shoot ROW renders one, so this is never read on a
  /// fold; `-1` is a value the server never issues and would fetch nothing if it ever were.
  private var coverFolderID: Int { row.item.node?.id ?? -1 }

  private var coverTaskID: String { "\(coverFolderID)|\(tier.rawValue)" }

  private var isOpen: Bool {
    FolderTreePresentation.isExpanded(
      row.id, readerExpanded: expandedBranches, isSearching: isSearching)
  }
}

/// The presentation decisions the folder tree makes, all pure and all readable by a test. P6
/// (IMGMGR-216) exists because the equivalent decision used to be an inline ternary in
/// `RootView.sidebar` (`treeSection: layoutMode == .compact ? nil : …`), where nothing could
/// assert it and the phone silently had no browse surface at all. None of these functions reads
/// the device idiom — `LayoutMode` is resolved from measured width plus `horizontalSizeClass`
/// (`LayoutResolver`), and this is the one place the tree consults it.
enum FolderTreePresentation {
  /// The shoot rows the tree offers, flattened out of the tree that actually renders. `mode` is
  /// taken and DELIBERATELY not consulted: "the phone reaches every shoot the iPad reaches" is
  /// P6's acceptance criterion, so the mode is routed through the one function a test can pin
  /// (`FolderTreeSectionTests.compactRendersTheSameShootSetAsRegular`) instead of being absent
  /// from the type system entirely. Any future mode-dependent filtering has to be written here,
  /// and goes RED there. Deriving this from `tree(for:folders:)` rather than from the raw
  /// response is what keeps that pin honest under P7: if the hierarchy ever drops a shoot on one
  /// idiom, this is the projection that notices. Which leaves are shoots stays `ShootListFilter`'s
  /// single definition — the server's `kind` vocabulary, never a second client-side one.
  static func shootRows(
    for mode: LayoutMode, folders: [Components.Schemas.FolderNode]
  ) -> [Components.Schemas.FolderNode] {
    FolderTreeModel.selectableShoots(in: tree(for: mode, folders: folders))
  }

  /// The tree the section renders, from the one mode-routing seam `shootRows` already
  /// established. P7 (IMGMGR-217) makes it a forest instead of a flat leaf list; `mode` is taken
  /// and again DELIBERATELY not consulted, so "both idioms get the same hierarchy" stays a
  /// property a test can read rather than an absence nobody can assert.
  static func tree(
    for mode: LayoutMode, folders: [Components.Schemas.FolderNode]
  ) -> [FolderTreeNode] {
    FolderTreeModel.forest(folders)
  }

  /// Whether one branch of the tree is open. The reader's own disclosure choices are the answer
  /// normally; while a search term is live, every surviving branch opens so the matches the
  /// filter kept are actually on screen instead of hidden inside collapsed ancestors.
  static func isExpanded(
    _ id: FolderTreeItemID, readerExpanded: Set<FolderTreeItemID>, isSearching: Bool
  ) -> Bool {
    isSearching || readerExpanded.contains(id)
  }

  /// The same rule for a tier branch, whose identity is the tier rather than a row.
  static func isExpanded(
    for tier: FolderTreeTier, in readerExpanded: Set<FolderTreeTier>, isSearching: Bool
  ) -> Bool {
    isSearching || readerExpanded.contains(tier)
  }
}
