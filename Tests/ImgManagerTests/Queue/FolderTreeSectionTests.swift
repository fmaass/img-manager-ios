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

  @Test("the Folders disclosure opens itself on Compact and stays collapsed on Regular")
  func foldersDisclosureOpensOnCompactOnly() {
    #expect(FolderTreePresentation.startsExpanded(in: .compact))
    #expect(!FolderTreePresentation.startsExpanded(in: .regular2))
    #expect(!FolderTreePresentation.startsExpanded(in: .regular3))
  }

  /// Diff-gate round 1, blocker 1. `RootView.layoutMode` is `.compact` until the first
  /// `.onGeometryChange` pass resolves it (`RootView.swift:28`), and this section mounts before
  /// that — so an expansion frozen at mount time makes an iPad launch open the secondary tree,
  /// against D13. The state model must answer from the CURRENT mode until the reader has chosen.
  @Test("a Regular launch never inherits the transient Compact default")
  func regularLaunchStaysCollapsedThroughTheUnresolvedCompactDefault() {
    var expansion = FolderTreeExpansion()
    #expect(expansion.isExpanded(in: .compact))
    #expect(!expansion.isExpanded(in: .regular2))
    #expect(!expansion.isExpanded(in: .regular3))

    // And once the reader has chosen, the choice wins in every mode — a resize must not stomp it.
    expansion.setExpanded(true)
    #expect(expansion.isExpanded(in: .regular2))
    #expect(expansion.isExpanded(in: .regular3))
    expansion.setExpanded(false)
    #expect(!expansion.isExpanded(in: .compact))
  }

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
    #expect(!FolderTreePresentation.isExpanded(7, readerExpanded: [], isSearching: false))
    #expect(FolderTreePresentation.isExpanded(7, readerExpanded: [7], isSearching: false))
    #expect(FolderTreePresentation.isExpanded(7, readerExpanded: [], isSearching: true))
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

  @Test("Both tiers unreachable is a FAILED disclosure, never a silent empty list")
  func bothTiersFailingIsAVisibleFailure() async {
    let transport = GridStubTransport()
    await transport.setFoldersShouldFail(true, tier: .local)
    await transport.setFoldersShouldFail(true, tier: .archive)

    let load = await FolderTreeLoad.perform(using: makeService(transport))

    #expect(load.phase == .failed)
    #expect(load.localFolders.isEmpty)
    #expect(load.archiveFolders.isEmpty)
  }

  /// Stated positively first, so the assertion above cannot pass by a load that calls everything
  /// a failure: a server that answers with nothing is a LOADED, empty library.
  @Test("A genuinely empty library is loaded, not failed")
  func anEmptyLibraryIsLoadedNotFailed() async {
    let transport = GridStubTransport()

    let load = await FolderTreeLoad.perform(using: makeService(transport))

    #expect(load.phase == .loaded)
    #expect(load.localFolders.isEmpty)
  }

  @Test("One tier unreachable still shows the other's rows, flagged as partial")
  func oneTierFailingIsPartialNotTotal() async {
    let transport = GridStubTransport()
    await transport.setFolderTree([node(1), node(2)], tier: .local)
    await transport.setFoldersShouldFail(true, tier: .archive)

    let load = await FolderTreeLoad.perform(using: makeService(transport))

    #expect(load.phase == .partiallyFailed(.archive))
    #expect(load.localFolders.map(\.id) == [1, 2])
    #expect(load.archiveFolders.isEmpty)
  }

  @Test("Retry after a failure re-fetches and recovers")
  func retryAfterAFailureRecovers() async {
    let transport = GridStubTransport()
    await transport.setFoldersShouldFail(true, tier: .local)
    await transport.setFoldersShouldFail(true, tier: .archive)
    let service = makeService(transport)
    let failed = await FolderTreeLoad.perform(using: service)
    #expect(failed.phase == .failed)

    // The server comes back; the reader taps Retry, which is this same call again.
    await transport.setFoldersShouldFail(false, tier: .local)
    await transport.setFoldersShouldFail(false, tier: .archive)
    await transport.setFolderTree([node(9)], tier: .local)
    let recovered = await FolderTreeLoad.perform(using: service)

    #expect(recovered.phase == .loaded)
    #expect(recovered.localFolders.map(\.id) == [9])
    // Four calls: two that failed, two that recovered — the retry really re-fetched.
    #expect(await transport.callCount(Operations.FolderTreeApiFoldersGet.id) == 4)
  }

  /// The failure surface is not a state the loader keeps to itself: the section renders an error
  /// with a retry path, so both halves are named where a test can read them.
  @Test("A failed phase is what the section renders its error state from")
  func aFailedPhaseIsRenderable() {
    #expect(FolderTreeLoadPresentation.isFailure(.failed))
    #expect(FolderTreeLoadPresentation.isFailure(.partiallyFailed(.local)))
    #expect(!FolderTreeLoadPresentation.isFailure(.loaded))
    #expect(!FolderTreeLoadPresentation.isFailure(.loading))
    #expect(
      FolderTreeLoadPresentation.message(for: .failed)
        == "Folders could not be loaded.")
    #expect(
      FolderTreeLoadPresentation.message(for: .partiallyFailed(.archive))
        == "Archive folders could not be loaded.")
    #expect(FolderTreeLoadPresentation.message(for: .loaded) == nil)
  }
}
