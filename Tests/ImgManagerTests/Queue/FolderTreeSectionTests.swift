import ImgManagerAPI
import Testing

@testable import ImgManager

/// P6 (IMGMGR-216): `RootView.sidebar` passed `treeSection: nil` on Compact, so the iPhone had
/// zero browse surface beyond its queue cards — a shoot that was not currently a queue card was
/// unreachable on the phone. The phase's acceptance property is "a Compact-idiom folder
/// navigation reaching every shoot the iPad reaches"; these pins are that property.
///
/// The fixture's `kind` values are the LIVE vocabulary, never an invented one: probed 2026-08-30
/// against the deployed backend (`GET /api/folders`, both tiers, read-only through the running
/// `img-manager` container) — {other, dated, template, import, dated_split, project} over 855
/// rows (local 166, archive 689), of which 465 are shoot rows (local 110, archive 355). That is
/// the IMGMGR-173 discipline: a server vocabulary is pinned against the real API, never against
/// a fixture the same suite wrote.
@Suite("Folder tree presentation — one component, both idioms")
struct FolderTreeSectionTests {

  private func node(id: Int, kind: String) -> Components.Schemas.FolderNode {
    .init(id: id, kind: kind, name: "n\(id)", path: "p\(id)")
  }

  /// One tier's worth of rows in the live vocabulary, in wire order: two shoot leaves among four
  /// non-shoot containers.
  private var folders: [Components.Schemas.FolderNode] {
    [
      node(id: 2, kind: "other"),
      node(id: 60, kind: "dated"),
      node(id: 61, kind: "template"),
      node(id: 62, kind: "import"),
      node(id: 63, kind: "dated_split"),
      node(id: 64, kind: "project"),
    ]
  }

  @Test("Compact renders the same shoot set as Regular")
  func compactRendersTheSameShootSetAsRegular() {
    let compact = FolderTreePresentation.shootRows(for: .compact, folders: folders)
    let regular2 = FolderTreePresentation.shootRows(for: .regular2, folders: folders)
    let regular3 = FolderTreePresentation.shootRows(for: .regular3, folders: folders)
    // Stated positively first: a mode that renders NOTHING would satisfy set equality with
    // another empty mode, so the reachable set is pinned by value before it is compared.
    #expect(compact.map(\.id) == [60, 63])
    #expect(compact.map(\.id) == regular2.map(\.id))
    #expect(compact.map(\.id) == regular3.map(\.id))
  }

  // IMGMGR-350 removed two pins with the thing they pinned: `FolderTreePresentation
  // .startsExpanded` and `FolderTreeExpansion` decided whether the "Folders" WRAPPER disclosure
  // opened (D13: opened on Compact, collapsed on Regular). The wrapper is gone — the tree is the
  // home on both idioms, so its tier rows are always on screen and there is no mode-dependent
  // default left to inherit. `TierHomeUITests` is what asserts they are.

  /// P7 (IMGMGR-217): the tree now carries the WHOLE folder hierarchy, so the rows that navigate
  /// have to be distinguishable from the rows that merely expand. `ShootListFilter` stays the one
  /// definition of a browsable shoot (IMGMGR-173); everything else is a container.
  @Test("only shoot-kind folders navigate — every other folder just expands")
  func onlyShootKindLeavesAreSelectable() {
    let tree = FolderTreePresentation.tree(for: .regular3, folders: folders)

    // The whole tree is present, not only its shoots — that is the P7 change.
    #expect(tree.map(\.id) == [2, 60, 61, 62, 63, 64])
    #expect(tree.filter(\.isSelectableShoot).map(\.id) == [60, 63])
    #expect(
      tree.filter { !$0.isSelectableShoot }.map(\.kind)
        == ["other", "template", "import", "project"])
  }

  /// A live search term opens what it matched; with no term, the reader's own disclosure state is
  /// the only thing that opens a branch.
  @Test("a live search opens the branches it kept, and the reader rules otherwise")
  func searchOpensTheBranchesItKept() {
    #expect(
      !FolderTreePresentation.isExpanded(.folder(7), readerExpanded: [], isSearching: false))
    #expect(
      FolderTreePresentation.isExpanded(
        .folder(7), readerExpanded: [.folder(7)], isSearching: false))
    #expect(FolderTreePresentation.isExpanded(.folder(7), readerExpanded: [], isSearching: true))
    // A month fold opens on the same rule and by the same reader choice — it is a branch, and
    // the only thing it is not is selectable.
    #expect(
      FolderTreePresentation.isExpanded(
        .month("2:2026-09"), readerExpanded: [.month("2:2026-09")], isSearching: false))
    #expect(
      !FolderTreePresentation.isExpanded(
        .month("2:2026-09"), readerExpanded: [.folder(2)], isSearching: false))
  }
}

/// IMGMGR-174. The sidebar swallowed every `folders()` throw with `try?`, and `GridService`
/// collapses a non-ok status and a decode failure alike into one opaque `.unreachable` — so
/// loading, genuinely-empty and silently-failed were the same picture on screen: nothing. These
/// pins are the distinction, driven through the REAL `GridService` and the real generated client
/// over a stub transport, never a re-implementation of the fetch.
@MainActor
@Suite("Folder tree loading — a failure is visible, and retryable (IMGMGR-174)")
struct FolderTreeLoadTests {

  private func makeService(_ transport: GridStubTransport) -> GridService {
    GridService(client: ImgManagerAPIClient.make(transport: transport))
  }

  private func node(_ id: Int) -> Components.Schemas.FolderNode {
    .init(id: id, kind: "dated", name: "n\(id)", path: "p\(id)")
  }

  @Test("Every tier unreachable is a FAILED disclosure, never a silent empty list")
  func bothTiersFailingIsAVisibleFailure() async {
    let transport = GridStubTransport()
    await transport.setFoldersShouldFail(true, tier: GridSourceTier.local.rawValue)
    await transport.setFoldersShouldFail(true, tier: GridSourceTier.archive.rawValue)

    let load = await FolderTreeLoad.perform(using: makeService(transport))

    #expect(load.phase == .failed)
    #expect(load.folders(.incoming).isEmpty)
    #expect(load.folders(.edits).isEmpty)
    #expect(load.folders(.archive).isEmpty)
  }

  /// IMGMGR-350 P1's third branch, pinned on the WIRE rather than on a call count: `edits` and
  /// `incoming` are the same store, so only the `tree` prefix tells the two requests apart
  /// (img-manager `app/api/folders.py:38`, `:54`). A load that fetched the local tree twice under
  /// the same query — or that dropped `tree` back to nil, as this method did before 350 — cannot
  /// pass.
  @Test("the tree is loaded once per browse tier, each naming its own (source_tier, tree)")
  func eachBrowseTierIsItsOwnScopedRequest() async {
    let transport = GridStubTransport()

    _ = await FolderTreeLoad.perform(using: makeService(transport))

    let queries = await transport.recordedFolderQueries
    #expect(queries.count == 3)
    #expect(queries.map { $0["source_tier"] } == ["local", "local", "archive"])
    #expect(queries.map { $0["tree"] } == ["photo_incoming", "photo_edits", nil])
  }

  /// Stated positively first, so the assertion above cannot pass by a load that calls everything
  /// a failure: a server that answers with nothing is a LOADED, empty library.
  @Test("A genuinely empty library is loaded, not failed")
  func anEmptyLibraryIsLoadedNotFailed() async {
    let transport = GridStubTransport()

    let load = await FolderTreeLoad.perform(using: makeService(transport))

    #expect(load.phase == .loaded)
    #expect(load.folders(.incoming).isEmpty)
    #expect(load.folders(.edits).isEmpty)
    #expect(load.folders(.archive).isEmpty)
  }

  @Test("One tier unreachable still shows the other's rows, flagged as partial")
  func oneTierFailingIsPartialNotTotal() async {
    let transport = GridStubTransport()
    await transport.setFolderTree([node(1), node(2)], tier: GridSourceTier.local.rawValue)
    await transport.setFoldersShouldFail(true, tier: GridSourceTier.archive.rawValue)

    let load = await FolderTreeLoad.perform(using: makeService(transport))

    #expect(load.phase == .partiallyFailed([.archive]))
    // The stub answers per `source_tier`, so both local-store tiers see the rows it was given —
    // what this pins is that a tier that ANSWERED keeps its rows while the one that failed is
    // named, not that the fixture tells incoming and edits apart.
    #expect(load.folders(.incoming).map(\.id) == [1, 2])
    #expect(load.folders(.edits).map(\.id) == [1, 2])
    #expect(load.folders(.archive).isEmpty)
  }

  @Test("Retry after a failure re-fetches and recovers")
  func retryAfterAFailureRecovers() async {
    let transport = GridStubTransport()
    await transport.setFoldersShouldFail(true, tier: GridSourceTier.local.rawValue)
    await transport.setFoldersShouldFail(true, tier: GridSourceTier.archive.rawValue)
    let service = makeService(transport)
    let failed = await FolderTreeLoad.perform(using: service)
    #expect(failed.phase == .failed)

    // The server comes back; the reader taps Retry, which is this same call again.
    await transport.setFoldersShouldFail(false, tier: GridSourceTier.local.rawValue)
    await transport.setFoldersShouldFail(false, tier: GridSourceTier.archive.rawValue)
    await transport.setFolderTree([node(9)], tier: GridSourceTier.local.rawValue)
    let recovered = await FolderTreeLoad.perform(using: service)

    #expect(recovered.phase == .loaded)
    #expect(recovered.folders(.incoming).map(\.id) == [9])
    // Six calls: three that failed, three that recovered — the retry really re-fetched, once per
    // browse tier (IMGMGR-350 P1 made them three).
    #expect(await transport.callCount(Operations.FolderTreeApiFoldersGet.id) == 6)
  }

  /// Checkpoint-3 finding F3, the ordering it is about, driven for real: two loads overlap and
  /// the OLDER one resolves LAST. Both used to be written in the order they landed, so the older
  /// answer won; the gate drops it because its generation is no longer current.
  @Test("an older tree load resolving last is dropped, and the newer answer stands")
  func anOlderTreeLoadResolvingLastIsDropped() async {
    let transport = GridStubTransport()
    let service = makeService(transport)
    await transport.setFolderTree([node(1)], tier: GridSourceTier.local.rawValue)
    await transport.holdFolderRequests(true)

    let older = Task { await FolderTreeLoad.perform(using: service) }
    await transport.waitUntilFolderRequestStarted()
    // The server's answer changes, and a NEWER load takes it while the older one is still held.
    await transport.setFolderTree([node(2)], tier: GridSourceTier.local.rawValue)
    await transport.holdFolderRequests(false)
    let newer = await FolderTreeLoad.perform(using: service)
    await transport.releaseFolderRequests()
    let stale = await older.value

    // Both really carry what they fetched — the older one is not merely late, it is WRONG now.
    #expect(stale.folders(.incoming).map(\.id) == [1])
    #expect(newer.folders(.incoming).map(\.id) == [2])
    #expect(!FolderTreeLoadGate.accepts(stale, generation: 1, current: 2))
    #expect(FolderTreeLoadGate.accepts(newer, generation: 2, current: 2))
  }

  /// The other half of F3: a CANCELLED load is neither an answer nor a failure. It used to come
  /// back as three unreachable tiers — which the view then wrote over a good tree.
  @Test("a cancelled tree load reports cancellation, not three failed tiers")
  func aCancelledTreeLoadIsNotAFailure() async {
    let transport = GridStubTransport()
    let service = makeService(transport)
    await transport.setFolderTree([node(1)], tier: GridSourceTier.local.rawValue)
    await transport.holdFolderRequests(true)

    let load = Task { await FolderTreeLoad.perform(using: service) }
    await transport.waitUntilFolderRequestStarted()
    load.cancel()
    await transport.holdFolderRequests(false)
    await transport.releaseFolderRequests()
    let result = await load.value

    #expect(result.phase == .cancelled)
    #expect(!FolderTreeLoadPresentation.isFailure(result.phase))
    #expect(FolderTreeLoadPresentation.message(for: result.phase) == nil)
    // And nothing may be published from it, whatever the generation says.
    #expect(!FolderTreeLoadGate.accepts(result, generation: 1, current: 1))
  }

  /// The gate itself, stated as values: same generation and a real answer, or nothing.
  @Test("only a current, uncancelled load may publish")
  func onlyACurrentUncancelledLoadMayPublish() {
    let loaded = FolderTreeLoad(phase: .loaded, foldersByTier: [.incoming: [node(1)]])
    #expect(FolderTreeLoadGate.accepts(loaded, generation: 3, current: 3))
    #expect(!FolderTreeLoadGate.accepts(loaded, generation: 2, current: 3))
    // A partial failure is a real answer about the tiers that did respond, so it publishes.
    #expect(
      FolderTreeLoadGate.accepts(
        FolderTreeLoad(phase: .partiallyFailed([.archive])), generation: 1, current: 1))
    #expect(
      !FolderTreeLoadGate.accepts(FolderTreeLoad(phase: .cancelled), generation: 1, current: 1))
  }

  /// Checkpoint-2 finding B3. A tier that did not answer had no way to say so: `folders(_:)`
  /// mapped a missing tier to an empty array, so a folder-load failure rendered as an empty
  /// branch — and, with every tier empty, as "No shoots", the copy for a library with nothing in
  /// it, beside a notice saying the opposite.
  @Test("a tier that did not answer is not an empty tier")
  func aTierThatDidNotAnswerIsNotAnEmptyTier() async {
    let transport = GridStubTransport()
    await transport.setFolderTree([node(1)], tier: GridSourceTier.local.rawValue)
    await transport.setFoldersShouldFail(true, tier: GridSourceTier.archive.rawValue)

    let load = await FolderTreeLoad.perform(using: makeService(transport))

    #expect(load.phase == .partiallyFailed([.archive]))
    #expect(load.answered(.incoming))
    #expect(load.answered(.edits))
    #expect(!load.answered(.archive))
    // The rows are still empty — that is exactly why emptiness cannot be the question asked.
    #expect(load.folders(.archive).isEmpty)
  }

  /// The other half of B3: the empty-library copy may only appear once every tier has answered.
  @Test("the empty-library copy waits for every tier to have answered")
  func theEmptyLibraryCopyWaitsForEveryTierToAnswer() {
    #expect(FolderTreeLoadPresentation.showsEmptyLibrary(for: .loaded, everyTierIsEmpty: true))
    #expect(!FolderTreeLoadPresentation.showsEmptyLibrary(for: .loaded, everyTierIsEmpty: false))
    #expect(
      !FolderTreeLoadPresentation.showsEmptyLibrary(
        for: .partiallyFailed([.archive]), everyTierIsEmpty: true))
    #expect(!FolderTreeLoadPresentation.showsEmptyLibrary(for: .failed, everyTierIsEmpty: true))
    #expect(
      FolderTreeLoadPresentation.tierMessage(for: .archive)
        == "Archive folders could not be loaded.")
    #expect(
      FolderTreeLoadPresentation.tierMessage(for: .edits) == "Edits folders could not be loaded.")
  }

  /// The failure surface is not a state the loader keeps to itself: the section renders an error
  /// with a retry path, so both halves are named where a test can read them.
  @Test("A failed phase is what the section renders its error state from")
  func aFailedPhaseIsRenderable() {
    #expect(FolderTreeLoadPresentation.isFailure(.failed))
    #expect(FolderTreeLoadPresentation.isFailure(.partiallyFailed([.incoming])))
    #expect(!FolderTreeLoadPresentation.isFailure(.loaded))
    #expect(!FolderTreeLoadPresentation.isFailure(.loading))
    #expect(
      FolderTreeLoadPresentation.message(for: .failed)
        == "Folders could not be loaded.")
    #expect(
      FolderTreeLoadPresentation.message(for: .partiallyFailed([.archive]))
        == "Archive folders could not be loaded.")
    // The third branch, and two of three failing — one sentence naming both, never a note that
    // says "Folders" and leaves the reader to guess which branch is missing.
    #expect(
      FolderTreeLoadPresentation.message(for: .partiallyFailed([.incoming]))
        == "Incoming folders could not be loaded.")
    #expect(
      FolderTreeLoadPresentation.message(for: .partiallyFailed([.edits, .archive]))
        == "Edits and Archive folders could not be loaded.")
    #expect(FolderTreeLoadPresentation.message(for: .loaded) == nil)
  }
}

/// IMGMGR-400: what a tap on a row's NAME does, as a value — the decision the two device-pass
/// defects were made of, pinned before any view renders it.
///
/// The owner's report on TestFlight 0.12.0 (15) was two halves of one rule: "the folders only
/// open when tapping on the chevron to expand the tree" and "the actual image folders dont open
/// at all to show pictures". The shipped row wired a tap ONLY on `isSelectableShoot`
/// (`ShootListFilter.shootKinds` = {dated, dated_split}), and expansion ONLY on the chevron
/// Button — so a container's name did nothing and a template/import/project/other folder full of
/// photographs did nothing at all.
///
/// The web is the design decision (BookStack p3396, "the same folder view on the ios app as on
/// web"): `FolderTreeBranch.vue:63` selects ANY folder on its name, and `:95`/`:103` toggle a
/// month fold on its label. That is exactly the three-way answer below.
///
/// `kind` values here are the LIVE server vocabulary (IMGMGR-173) — {other, dated, dated_split,
/// import, project, template} — never an invented one.
@Suite("Folder tree row tap — every folder navigates, a fold toggles (IMGMGR-400)")
struct FolderTreeRowTapActionTests {

  private func node(id: Int, kind: String, children: [FolderTreeNode] = []) -> FolderTreeNode {
    FolderTreeNode(
      folder: .init(
        descendantImageCount: 3, id: id, imageCount: 3, kind: kind, name: "n\(id)",
        path: "p\(id)"),
      children: children)
  }

  private func row(_ item: FolderTreeItem) -> FolderTreeItemRow {
    FolderTreeItemRow(item: item, depth: 0)
  }

  private func fold(_ members: [FolderTreeItem]) -> FolderTreeItem {
    .month(
      FolderTreeMonth(parentID: 2, year: "2026", month: "09", label: "september", count: 9),
      members: members)
  }

  /// The first defect's half: a folder row that is NOT a dated shoot opens its own folder. Every
  /// kind the API emits is here, so a rule that re-narrowed to a subset fails on the member it
  /// left out rather than on a single representative.
  @Test("a folder row of every live kind opens its own folder")
  func aFolderRowOfEveryLiveKindOpensItsOwnFolder() {
    for (id, kind) in [
      (1, "dated"), (2, "dated_split"), (3, "template"), (4, "import"), (5, "project"),
      (6, "other"),
    ] {
      let item = FolderTreeItem.folder(node(id: id, kind: kind), children: [])
      #expect(
        row(item).tapAction(isOpen: false, isSelected: false) == .openFolder(id, expanding: false))
    }
  }

  /// A folder that ALSO has children still opens on a tap — and since IMGMGR-405 the same tap
  /// opens the branch, which is what every desktop tree this one is modelled on does. The chevron
  /// keeps its own separate job (it toggles and never navigates).
  @Test("a collapsed folder with children opens AND expands on one tap")
  func aCollapsedFolderWithChildrenOpensAndExpandsOnOneTap() {
    let parent = node(id: 3, kind: "dated", children: [node(id: 4, kind: "template")])
    let item = FolderTreeItem.folder(
      parent, children: [.folder(node(id: 4, kind: "template"), children: [])])

    #expect(row(item).isExpandable)
    #expect(
      row(item).tapAction(isOpen: false, isSelected: false) == .openFolder(3, expanding: true))
  }

  /// The second defect's half: a month fold is no folder, so a tap on it toggles — the one row
  /// whose tap is the chevron's action, in both directions.
  @Test("a month fold with members toggles rather than navigating")
  func aMonthFoldWithMembersTogglesRatherThanNavigating() {
    let item = fold([.folder(node(id: 3, kind: "dated"), children: [])])

    #expect(row(item).isExpandable)
    #expect(row(item).tapAction(isOpen: false, isSelected: false) == .expand)
    #expect(row(item).tapAction(isOpen: true, isSelected: false) == .collapse)
  }

  /// Nothing to expand and no folder to open: the row stays inert rather than falling back to
  /// either affordance. The control for the leg above — the fold's answer is its MEMBERS, not its
  /// case.
  @Test("a fold with no members is inert")
  func aFoldWithNoMembersIsInert() {
    let item = fold([])

    #expect(!row(item).isExpandable)
    #expect(row(item).tapAction(isOpen: false, isSelected: false) == .inert)
  }

  /// The fix widened the TAP and nothing else: `ShootListFilter` is still the one definition of a
  /// browsable shoot, and it is still {dated, dated_split} — which is what keeps the cover
  /// thumbnail, the count subline and the readiness badge on shoot rows only
  /// (`FolderTreeRowPresentation.showsThumbnail`), and the `folderRow-`/`folderContainer-`
  /// identifier split intact.
  @Test("the shoot-list vocabulary is untouched by the tap widening")
  func theShootListVocabularyIsUntouchedByTheTapWidening() {
    #expect(ShootListFilter.shootKinds == ["dated", "dated_split"])
    #expect(node(id: 3, kind: "template").isSelectableShoot == false)
    #expect(FolderTreeRowPresentation.showsThumbnail(node(id: 3, kind: "template")) == false)
    #expect(
      FolderTreeRowPresentation.rowIdentifier(for: node(id: 3, kind: "template"), id: 3)
        == "folderContainer-3")
  }
}

/// IMGMGR-405 (owner device pass, TestFlight 0.12.1 (16)): "click on the whole row to expand …
/// visualize which folder is selected … industry proven common practices".
///
/// Two rules, both pinned here as values before any pixel renders them. (1) A tap on a row means
/// something different depending on where the reader already is — the convention every desktop
/// tree keeps (Google Drive, the VS Code explorer, SwiftUI's own `DisclosureGroup`, and this
/// app's own web UI): one tap opens a closed branch and enters it, a second tap on the branch you
/// are standing in closes it again. (2) The selected folder is exactly one row, a fold never
/// among them.
///
/// The table below is the whole input space of `tapAction(isOpen:isSelected:)` — leaf, parent
/// closed, parent open and selected, parent open and unselected, fold closed, fold open, empty
/// fold — because a routing rule with a case missing is a rule that regresses in silence.
@Suite("Folder tree row tap and selection (IMGMGR-405)")
struct FolderTreeRowInteractionTests {

  private func wire(
    id: Int, parent: Int? = nil, kind: String = "dated", name: String? = nil, path: String? = nil
  ) -> Components.Schemas.FolderNode {
    .init(
      descendantImageCount: 3, id: id, imageCount: 3, kind: kind, name: name ?? "folder-\(id)",
      parentId: parent, path: path ?? "p\(id)")
  }

  /// The fixture tree the shipped UI tests walk, in wire form: one hoisted tier root over a
  /// root-level shoot and a YEAR container, whose two dated children fold into one month row and
  /// whose first child carries a `template` leaf of its own.
  private var incomingItems: [FolderTreeItem] {
    let nodes = [
      wire(id: 9, kind: "other", name: "photo_incoming", path: "photo_incoming"),
      wire(id: 1, parent: 9, name: "2026-08-27 — Stub Shoot"),
      wire(id: 2, parent: 9, kind: "other", name: "2026"),
      wire(id: 3, parent: 2, name: "2026-09-14 — Wandern"),
      wire(id: 4, parent: 3, kind: "template", name: "template"),
      wire(id: 5, parent: 2, name: "2026-09-27 — Ufer"),
    ]
    return FolderTreeModel.tierItems(FolderTreeModel.forest(nodes), tier: .incoming)
  }

  /// A second tier, so the reveal has something it must NOT open: one year container over one
  /// dated shoot, ids disjoint from the incoming fixture's exactly as the live tiers are.
  private var archiveItems: [FolderTreeItem] {
    let nodes = [
      wire(id: 20, kind: "other", name: "2025", path: "2025"),
      wire(id: 21, parent: 20, name: "2025-12-24 — Archive Shoot", path: "2025/archive-shoot"),
    ]
    return FolderTreeModel.tierItems(FolderTreeModel.forest(nodes), tier: .archive)
  }

  private var itemsByTier: [FolderTreeTier: [FolderTreeItem]] {
    [.incoming: incomingItems, .edits: [], .archive: archiveItems]
  }

  private func node(id: Int, kind: String = "dated", children: [FolderTreeNode] = [])
    -> FolderTreeNode
  {
    FolderTreeNode(folder: wire(id: id, kind: kind), children: children)
  }

  private func row(_ item: FolderTreeItem) -> FolderTreeItemRow {
    FolderTreeItemRow(item: item, depth: 0)
  }

  private var leaf: FolderTreeItem { .folder(node(id: 1), children: []) }

  private var parent: FolderTreeItem {
    .folder(node(id: 2, kind: "other", children: [node(id: 3)]), children: [leafThree])
  }

  private var leafThree: FolderTreeItem { .folder(node(id: 3), children: []) }

  private func fold(_ members: [FolderTreeItem]) -> FolderTreeItem {
    .month(
      FolderTreeMonth(parentID: 2, year: "2026", month: "09", label: "september", count: 9),
      members: members)
  }

  @Test("every row state maps to exactly one tap action")
  func everyRowStateMapsToExactlyOneTapAction() {
    let probes: [(String, FolderTreeItem, Bool, Bool, FolderTreeRowTapAction)] = [
      // A leaf has nothing to open, so its tap is the one it always was (rule 4).
      ("leaf folder", leaf, false, false, .openFolder(1, expanding: false)),
      // …including when it is the row the reader is standing in: there is no branch to close.
      ("leaf folder, selected", leaf, false, true, .openFolder(1, expanding: false)),
      // One tap does both (rule 2).
      ("folder with children, collapsed", parent, false, false, .openFolder(2, expanding: true)),
      // The second tap on the branch you are in closes it, and nothing navigates (rule 3).
      ("folder with children, open and selected", parent, true, true, .collapse),
      // Open while the LIST does not hold this row is not "the branch you are in" — the Compact
      // case after a pop-back, where the row is still painted but the selection is nil. Entering
      // it is what the reader means AND what the List is about to do anyway, so the two agree
      // instead of collapsing under a navigation (round-2 finding 1).
      (
        "folder with children, open and not selected", parent, true, false,
        .openFolder(2, expanding: false)
      ),
      // A fold is no folder, so it only ever toggles — in both directions.
      ("month fold, collapsed", fold([leafThree]), false, false, .expand),
      ("month fold, open", fold([leafThree]), true, false, .collapse),
      // The control for the two above: the fold's answer is its MEMBERS, not its case.
      ("month fold with no members", fold([]), false, false, .inert),
    ]

    for (what, item, isOpen, isSelected, expected) in probes {
      #expect(row(item).tapAction(isOpen: isOpen, isSelected: isSelected) == expected, "\(what)")
    }
  }

  /// Rule 6: a selection made before this tree was on screen has to be REVEALED, which means
  /// opening every row between the tier and it — the month fold included, since that is where a
  /// dated shoot actually lives.
  @Test("the ancestors of a folder are every row between the tier and it")
  func theAncestorsOfAFolderAreEveryRowBetweenTheTierAndIt() {
    let items = incomingItems

    #expect(
      FolderTreeModel.ancestorRowIDs(ofFolder: 4, in: items)
        == [.folder(2), .month("2:2026-09"), .folder(3)])
    #expect(
      FolderTreeModel.ancestorRowIDs(ofFolder: 3, in: items) == [.folder(2), .month("2:2026-09")])
    // A top-level row is already visible, and its own row is never among its ancestors — a reveal
    // that expanded the folder it reveals would re-open a branch the reader had just closed.
    #expect(FolderTreeModel.ancestorRowIDs(ofFolder: 1, in: items).isEmpty)
    // A folder this tier does not hold is the normal answer for two of the three tiers.
    #expect(FolderTreeModel.ancestorRowIDs(ofFolder: 999, in: items).isEmpty)
  }

  /// The decision table for ONE row across the three states its selection can be in — the
  /// per-row twin of the whole-space table above, kept because these three are the readings the
  /// view's own capture has to choose between (`FolderTreeSection.tapTarget`).
  ///
  /// It pins the DECISION only. That the view resolves it from the state the tap FOUND rather
  /// than from the state the tap causes is structural — a `let` at body evaluation — and cannot
  /// be witnessed here without hosting the view; the argument for it is the comment at that
  /// capture, and keeping the read out of the gesture closure is a review invariant.
  @Test("one row's action across selected, unselected-open and unselected-closed")
  func oneRowsActionAcrossSelectedUnselectedOpenAndUnselectedClosed() {
    let branch = row(parent)

    // Selected BEFORE the tap: the List already holds this id, so the tap is a same-value re-tap
    // it cannot act on — the only state in which closing the branch navigates nowhere.
    #expect(branch.tapAction(isOpen: true, isSelected: true) == .collapse)

    // Not selected before the tap, however the row is painted: the List is about to select it, so
    // the row's own action has to be the one that AGREES — enter the folder, leave the branch
    // open. A handler that re-read the selection after the List had written the tag would read
    // `true` here, answer `.collapse`, and skip `onSelect` while the List navigated anyway: the
    // stale-scope defect this pins.
    #expect(branch.tapAction(isOpen: true, isSelected: false) == .openFolder(2, expanding: false))
    #expect(branch.tapAction(isOpen: false, isSelected: false) == .openFolder(2, expanding: true))
  }

  /// Round-2 finding 2: the reveal has to open the TIER branch too. Each tier is a
  /// `DisclosureGroup` with its own expansion, so a restored selection under a closed Incoming /
  /// Edits / Archive stayed hidden however many row ancestors were opened.
  ///
  /// The case an ancestors-only rule cannot even express is the second leg here: a TOP-LEVEL
  /// folder inside a closed tier has no row ancestors at all, so the empty row set is the correct
  /// answer AND the tier must still open. Only the tier that holds the folder opens: the plan is
  /// applied additively to state the reader owns.
  @Test("the reveal opens the tier branch as well as the rows above the folder")
  func theRevealOpensTheTierBranchAsWellAsTheRowsAboveTheFolder() {
    let deep = FolderTreeModel.revealPlan(folderID: 4, itemsByTier: itemsByTier)
    #expect(deep.tiers == [.incoming])
    #expect(deep.rows == [.folder(2), .month("2:2026-09"), .folder(3)])

    let topLevel = FolderTreeModel.revealPlan(folderID: 1, itemsByTier: itemsByTier)
    #expect(topLevel.tiers == [.incoming])
    #expect(topLevel.rows.isEmpty)

    // The other tier, and the control that the plan is not simply "open everything".
    let archived = FolderTreeModel.revealPlan(folderID: 21, itemsByTier: itemsByTier)
    #expect(archived.tiers == [.archive])
    #expect(archived.rows == [.folder(20), .month("20:2025-12")])

    #expect(FolderTreeModel.revealPlan(folderID: 999, itemsByTier: itemsByTier) == .init())
    #expect(FolderTreeModel.revealPlan(folderID: nil, itemsByTier: itemsByTier) == .init())
  }

  /// The two facts `ancestorRowIDs` cannot tell apart on its own, which is why the plan asks this
  /// separately: "no ancestors" and "not here" are both the empty set.
  @Test("a tier is asked whether it holds the folder at all")
  func aTierIsAskedWhetherItHoldsTheFolderAtAll() {
    #expect(FolderTreeModel.containsFolder(1, in: incomingItems))
    #expect(FolderTreeModel.containsFolder(4, in: incomingItems))
    #expect(!FolderTreeModel.containsFolder(21, in: incomingItems))
    #expect(!FolderTreeModel.containsFolder(999, in: incomingItems))
  }

  /// The property the reveal actually has to have, read through the SAME `visibleRows` the view
  /// renders: with those ancestors open, the row is on screen — and with nothing open it is not,
  /// which is the control that the first half is the expansion's doing and not the tree's.
  @Test("expanding those ancestors is what puts the row on screen")
  func expandingThoseAncestorsIsWhatPutsTheRowOnScreen() {
    let items = incomingItems
    let plan = FolderTreeModel.revealPlan(folderID: 4, itemsByTier: itemsByTier)

    let revealed = FolderTreeModel.visibleRows(items) { plan.rows.contains($0) }
    #expect(revealed.map(\.id).contains(.folder(4)))

    let closed = FolderTreeModel.visibleRows(items) { _ in false }
    #expect(!closed.map(\.id).contains(.folder(4)))
  }

  /// Rule 5, the "exactly one row" half — counted over the whole open tree rather than asserted
  /// on the one row a test picked, so a highlight that matched by name, by depth or by count
  /// would fail here.
  @Test("exactly one row is the selected folder, and a fold is never it")
  func exactlyOneRowIsTheSelectedFolderAndAFoldIsNeverIt() {
    let rows = FolderTreeModel.visibleRows(incomingItems) { _ in true }
    let selected = rows.filter {
      FolderTreeRowPresentation.isSelected($0.item, highlightedFolderID: 3)
    }

    #expect(selected.map(\.id) == [.folder(3)])

    // The fold's own parent id is 2, and the fold is NOT that folder: a month row has no folder
    // id to compare (`FolderTreeItemID`), which is what keeps it unselectable by construction.
    let year = rows.filter { FolderTreeRowPresentation.isSelected($0.item, highlightedFolderID: 2) }
    #expect(year.map(\.id) == [.folder(2)])

    #expect(
      rows.allSatisfy {
        !FolderTreeRowPresentation.isSelected($0.item, highlightedFolderID: nil)
      })
  }

  /// Rule 5's other half, and the reason the highlight is not read straight off the enclosing
  /// `List`'s selection: a collapsed `NavigationSplitView` is a stack, so popping back out of the
  /// grid on the phone clears that binding. The tree must still say where the reader was — and
  /// the fallback is the STORE's own open folder (`GridStore.query.folderID`), never a `@State` of
  /// the tree, because the home is destroyed and rebuilt whenever `RootView` swaps its column
  /// count (round-2 finding 3).
  @Test("the highlight survives the selection being cleared, and any real selection wins")
  func theHighlightSurvivesTheSelectionBeingClearedAndAnyRealSelectionWins() {
    #expect(FolderTreeRowPresentation.highlight(selection: 3, opened: nil) == 3)
    #expect(FolderTreeRowPresentation.highlight(selection: nil, opened: 3) == 3)
    #expect(FolderTreeRowPresentation.highlight(selection: 5, opened: 3) == 5)
    #expect(FolderTreeRowPresentation.highlight(selection: nil, opened: nil) == nil)
  }
}
