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
  @Binding var selectedFolderID: Int?
  let onSelect: (Int, GridSourceTier) -> Void

  @State private var expansion = FolderTreeExpansion()
  @State private var load = FolderTreeLoad.loading
  @State private var searchText = ""
  @State private var expandedBranches: Set<Int> = []
  @State private var expandedTiers: Set<GridSourceTier> = []

  private var localFolders: [Components.Schemas.FolderNode] { load.folders(.incoming) }
  private var archiveFolders: [Components.Schemas.FolderNode] { load.folders(.archive) }

  var body: some View {
    DisclosureGroup(isExpanded: expansionBinding) {
      if load.phase != .loading {
        // IMGMGR-174: a load that failed says so, above whatever rows did arrive. It sits FIRST
        // because a partial failure still renders a tree underneath it, and a note below rows the
        // reader has already started scanning is a note they will not read.
        failureNotice
        searchField
        tierBranch("Local", folders: localFolders, tier: .local)
        tierBranch("Archive", folders: archiveFolders, tier: .archive)
        if isSearching, branches(localFolders).isEmpty, branches(archiveFolders).isEmpty {
          Text("No folders match")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("folderTreeNoMatches")
        }
      } else {
        // Compact opens this disclosure by default (see `FolderTreePresentation`), and the two
        // folder calls it waits on measured ~0.6 s (local) and ~2.5 s (archive) server-side
        // against production on 2026-08-30 — an already-open disclosure with no rows under it
        // reads as "this library has no folders" for those seconds. It says Loading instead.
        // (Regular keeps its collapsed default; this also fixes the same silence there for
        // anyone who expands during the first load.)
        ProgressView()
      }
    } label: {
      Text("Folders").accessibilityIdentifier("foldersDisclosure")
    }
    .task {
      guard load.phase == .loading else { return }
      load = await FolderTreeLoad.perform(using: gridService)
    }
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
            load = await FolderTreeLoad.perform(using: gridService)
          }
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("folderTreeRetry")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// Derived on every read, never frozen at mount: `RootView.layoutMode` is still `.compact`
  /// when this section first mounts (`RootView.swift:28`; `applyWidth` only corrects it on the
  /// first `.onGeometryChange` pass), so a value captured at mount time makes an iPad launch
  /// inherit Compact's opened default and start with the secondary tree expanded, against D13.
  /// `FolderTreeExpansion` holds the reader's own choice instead, and defers to the CURRENT
  /// mode until there is one.
  private var expansionBinding: Binding<Bool> {
    Binding(
      get: { expansion.isExpanded(in: layoutMode) },
      set: { expansion.setExpanded($0) })
  }

  private var trimmedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isSearching: Bool { !trimmedSearch.isEmpty }

  /// The tier's rows: the server's forest, narrowed by whatever is in the search field. Both
  /// steps are pure and live in `FolderTreeModel` — this view holds no derived state of its own,
  /// so there is nothing here that can go stale against the loaded response.
  private func branches(_ folders: [Components.Schemas.FolderNode]) -> [FolderTreeNode] {
    FolderTreeModel.filter(
      FolderTreePresentation.tree(for: layoutMode, folders: folders), matching: searchText)
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
  private func tierBranch(
    _ title: String, folders: [Components.Schemas.FolderNode], tier: GridSourceTier
  ) -> some View {
    let rows = FolderTreeModel.visibleRows(branches(folders)) { id in
      FolderTreePresentation.isExpanded(
        id, readerExpanded: expandedBranches, isSearching: isSearching)
    }
    if !rows.isEmpty {
      DisclosureGroup(isExpanded: tierBinding(tier)) {
        // One flat ForEach over the OPEN rows, keyed by the server's folder id — never an index
        // (IMGMGR-210), and never a second nested container per level: the depth is a leading
        // inset, so a branch three deep is still one row in one list.
        ForEach(rows) { row in
          FolderTreeRowView(
            row: row, tier: tier, isSearching: isSearching, heroLoader: heroLoader,
            expandedBranches: $expandedBranches, selectedFolderID: $selectedFolderID,
            onSelect: onSelect)
        }
      } label: {
        Text(title).accessibilityIdentifier("folderTreeTier-\(title)")
      }
    }
  }

  /// A live search opens both tier branches for the same reason it opens the matched folders: a
  /// hit the reader cannot see is not a search result. The reader's own choice is what decides
  /// once the field is empty again.
  private func tierBinding(_ tier: GridSourceTier) -> Binding<Bool> {
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
  }

  var phase: Phase = .loading
  /// One entry per tier that answered. Keyed rather than three named arrays because the tiers
  /// are the `FolderTreeTier` cases and nothing else — adding `edits` must not mean adding a
  /// third property, a third fetch branch and a third failure case by hand.
  var foldersByTier: [FolderTreeTier: [Components.Schemas.FolderNode]] = [:]

  /// What one tier loaded; an empty list where it failed or was genuinely empty — a distinction
  /// `phase` carries, and this accessor deliberately does not repeat.
  func folders(_ tier: FolderTreeTier) -> [Components.Schemas.FolderNode] {
    foldersByTier[tier] ?? []
  }

  /// The pre-fetch value the view starts from, and the one a retry returns to.
  static let loading = FolderTreeLoad()

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
        failed.append(tier)
      }
    }
    switch failed.count {
    case 0: result.phase = .loaded
    case FolderTreeTier.allCases.count: result.phase = .failed
    default: result.phase = .partiallyFailed(failed)
    }
    return result
  }
}

/// What a load phase LOOKS like — the pure half of IMGMGR-174, so the wording and the
/// failure/not-failure split are values a test reads rather than strings buried in a view.
enum FolderTreeLoadPresentation {
  static func isFailure(_ phase: FolderTreeLoad.Phase) -> Bool {
    switch phase {
    case .failed, .partiallyFailed: return true
    case .loading, .loaded: return false
    }
  }

  /// Deliberately says what could not be LOADED, never why — `GridService` collapses a non-ok
  /// status and a decode failure into one opaque `.unreachable` (its own doc comment), so a
  /// reason here would be invented rather than reported. `nil` where there is nothing to say.
  static func message(for phase: FolderTreeLoad.Phase) -> String? {
    switch phase {
    case .loading, .loaded: return nil
    case .failed: return "Folders could not be loaded."
    case .partiallyFailed(let tiers):
      // The tier's own label, so the note names the branch the reader can see is missing. Two
      // tiers read as one sentence rather than two notes; all three is `.failed` above, so the
      // join never has a third term to punctuate.
      let named = tiers.map(\.label).joined(separator: " and ")
      return "\(named) folders could not be loaded."
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
  let row: FolderTreeOutlineRow
  let tier: GridSourceTier
  let isSearching: Bool
  let heroLoader: HeroThumbnailLoader
  @Binding var expandedBranches: Set<Int>
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
      .accessibilityIdentifier("folderDisclose-\(row.id)")
      .accessibilityLabel(isOpen ? "Collapse \(row.node.name)" : "Expand \(row.node.name)")
    } else {
      Color.clear.frame(width: 20, height: 1)
    }
  }

  @ViewBuilder
  private var nameAndCount: some View {
    if row.node.isSelectableShoot {
      // Same row-navigation pattern as the pre-P7 sidebar (RootView's own doc comment on this
      // exact fix): `.simultaneousGesture` layered on TOP of the enclosing List's own selection
      // recognizer, never a bare `Button` and never `.onChange(of: selectedFolderID)` — a plain
      // Button never pushes NavigationSplitView's column on Compact, and onChange never fires on
      // a same-value re-tap.
      rowContent
        .contentShape(Rectangle())
        .tag(row.id)
        // The stable, id-derived identifier lives on the row's NAME text, not here: an
        // identifier on a container overrides its descendants' (GridView.swift:743-747), which
        // would make this row's cover and subline unaddressable. `FolderTreeRowPresentation
        // .rowIdentifier` decides the string; `rowContent` applies it.
        .simultaneousGesture(
          TapGesture().onEnded {
            selectedFolderID = row.id
            onSelect(row.id, tier)
          }
        )
    } else {
      // A container: it expands, and it does NOT navigate. Its identifier is deliberately a
      // different prefix, so `folderRow-<id>` keeps meaning "a row that enters the grid" — and it
      // is applied on the name text with the shoot's, for the override reason above.
      rowContent
    }
  }

  private var rowContent: some View {
    HStack(spacing: 8) {
      if FolderTreeRowPresentation.showsThumbnail(row.node) {
        cover
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(row.node.name)
          .lineLimit(1)
          .truncationMode(.middle)
          .accessibilityIdentifier(
            FolderTreeRowPresentation.rowIdentifier(for: row.node, id: row.id))
        // A shoot's own roll-up, one line down: the server's number, never recomputed, and
        // stated ONCE — this is the same count the trailing caption below carries on the
        // container rows, moved rather than duplicated.
        if let subline = FolderTreeRowPresentation.subline(for: row.node) {
          Text(subline)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(FolderTreeRowPresentation.sublineIdentifier(for: row.id))
        }
      }
      Spacer(minLength: 8)
      // The container row's trailing caption: same text, same modifiers, same number as at
      // 4753450 — a folder of folders is not a shoot, so decision 2 leaves it alone. Its
      // enclosing structure is not identical (the name now sits in a one-child VStack that a
      // shoot row fills with a second line), which changes nothing about what is rendered.
      if let trailing = FolderTreeRowPresentation.trailingCount(for: row.node) {
        Text(trailing)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
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
    .accessibilityIdentifier(FolderTreeRowPresentation.thumbnailIdentifier(for: row.id))
    .task(id: coverTaskID) {
      switch await heroLoader.hero(folderID: row.id, sourceTier: tier) {
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
  private var coverTaskID: String { "\(row.id)|\(tier.rawValue)" }

  private var isOpen: Bool {
    FolderTreePresentation.isExpanded(
      row.id, readerExpanded: expandedBranches, isSearching: isSearching)
  }
}

/// Whether the "Folders" disclosure is open, as a value a test can drive. A reader's own choice
/// wins from the moment it is made; until then the answer is re-derived from the CURRENT layout
/// mode on every read. That distinction is the whole point (diff-gate round 1, blocker 1): the
/// first shipped version seeded `@State` at mount time, when `RootView.layoutMode` is still its
/// pre-geometry `.compact` default, so an iPad launch started with the secondary tree expanded
/// and D13's Regular-collapsed contract was broken by a value nobody could see.
struct FolderTreeExpansion {
  private var readerChoice: Bool?

  init(readerChoice: Bool? = nil) { self.readerChoice = readerChoice }

  func isExpanded(in mode: LayoutMode) -> Bool {
    readerChoice ?? FolderTreePresentation.startsExpanded(in: mode)
  }

  mutating func setExpanded(_ expanded: Bool) { readerChoice = expanded }
}

/// The presentation decisions the folder tree makes, all pure and all readable by a test. P6
/// (IMGMGR-216) exists because the equivalent decision used to be an inline ternary in
/// `RootView.sidebar` (`treeSection: layoutMode == .compact ? nil : …`), where nothing could
/// assert it and the phone silently had no browse surface at all. None of these functions reads
/// the device idiom — `LayoutMode` is resolved from measured width plus `horizontalSizeClass`
/// (`LayoutResolver`), and this is the one place the tree consults it.
enum FolderTreePresentation {
  /// The Folders disclosure opens itself on Compact, where it is the only way to reach a shoot
  /// that is not currently a queue card; on Regular it stays the collapsed SECONDARY surface
  /// below the queue (D13, unchanged since WP8 P7). Nothing else about the tree varies by mode.
  static func startsExpanded(in mode: LayoutMode) -> Bool { mode == .compact }

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
  static func isExpanded(_ id: Int, readerExpanded: Set<Int>, isSearching: Bool) -> Bool {
    isSearching || readerExpanded.contains(id)
  }

  /// The same rule for a tier branch, whose identity is the tier rather than a folder id.
  static func isExpanded(
    for tier: GridSourceTier, in readerExpanded: Set<GridSourceTier>, isSearching: Bool
  ) -> Bool {
    isSearching || readerExpanded.contains(tier)
  }
}
