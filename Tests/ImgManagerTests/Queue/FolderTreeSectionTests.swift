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
