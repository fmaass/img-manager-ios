import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// Which signed-in subject the store's provider reports. Mirrors `QueueStoreTests`' own box —
/// file-private there, file-private here, because a cross-account sequence has to be driven the
/// way production drives it: one retained store, a subject that changes underneath it.
@MainActor
private final class TreeCacheSubjectBox {
  var value: String?
  init(_ value: String?) { self.value = value }
}

/// IMGMGR-350 P4: the folder tree's offline parity, mirroring IMGMGR-198's own suite.
///
/// The tree section lives in `QueueSnapshot` under the SAME subject, server, generation fence and
/// erase path as the summaries — one file, one lifetime — so these pins are about the two
/// sections travelling together: what replays, what refuses to replay, what a sign-out destroys,
/// and that neither section's write drops the other.
@MainActor
@Suite("Queue snapshot — the tree section replays with the summaries (IMGMGR-350 P4)")
struct QueueTreeCacheTests {
  private static let baseURL = "https://img.example.invalid"
  private static let liveFetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
  private static let cachedFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

  private func node(_ id: Int) -> Components.Schemas.FolderNode {
    .init(
      descendantImageCount: 1, id: id, imageCount: 1, kind: "dated", name: "n\(id)",
      path: "p\(id)")
  }

  private func summary(_ folderId: Int) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderId, kind: "dated",
      lastTouched: nil, nothingLeftUnmarked: false, path: "p/\(folderId)", picked: 0,
      previewOutstanding: 0, readiness: .init(rawValue: "ready_to_review")!, sourceTier: "local",
      sync: nil, total: 1, unmarked: 1, withMasters: 0)
  }

  private func snapshot(
    subject: String = "user-a", baseURL: String = QueueTreeCacheTests.baseURL
  ) -> QueueSnapshot {
    QueueSnapshot(
      summaries: [summary(1)], fetchedAt: QueueTreeCacheTests.cachedFetchedAt, baseURL: baseURL,
      subject: subject,
      tree: QueueSnapshot.TreeSection(
        foldersByTier: ["incoming": [node(1)], "archive": [node(2)]],
        fetchedAt: QueueTreeCacheTests.cachedFetchedAt))
  }

  private func makeStore(
    snapshot: QueueSnapshot? = nil, subject: TreeCacheSubjectBox = TreeCacheSubjectBox("user-a")
  ) -> (QueueStore, GridStubTransport, FakeQueueSnapshotStore) {
    let transport = GridStubTransport()
    let service = QueueService(client: ImgManagerAPIClient.make(transport: transport))
    let snapshotStore = FakeQueueSnapshotStore(stored: snapshot)
    let store = QueueStore(
      service: service, snapshotStore: snapshotStore, subject: { subject.value },
      baseURL: QueueTreeCacheTests.baseURL, now: { QueueTreeCacheTests.liveFetchedAt },
      debounceNanoseconds: 10_000_000)
    return (store, transport, snapshotStore)
  }

  @Test("a saved tree replays as the stale phase, carrying the time the server said it")
  func aSavedTreeReplaysAsTheStalePhase() async {
    let (store, transport, _) = makeStore(snapshot: snapshot())
    await transport.setFolderSummariesShouldFail(true)

    await store.loadIfNeeded()

    guard let cached = store.cachedTree else {
      Issue.record("the snapshot's tree section did not replay at all")
      return
    }
    #expect(cached.fetchedAt == Self.cachedFetchedAt)
    #expect(cached.foldersByTier[.incoming]?.map(\.id) == [1])
    #expect(cached.foldersByTier[.archive]?.map(\.id) == [2])

    // What the view does with it: a load that reached NOTHING renders the remembered answer,
    // labelled with when it was fetched.
    let replayed = FolderTreeLoad.resolve(fresh: FolderTreeLoad(phase: .failed), cached: cached)
    #expect(replayed.phase == .stale(Self.cachedFetchedAt))
    #expect(replayed.folders(.incoming).map(\.id) == [1])
    let expectedNotice =
      "\(DegradedStateCopy.notConnected) "
      + DegradedStateCopy.showingCached(since: Self.cachedFetchedAt)
    #expect(FolderTreeLoadPresentation.message(for: replayed.phase) == expectedNotice)
    #expect(!FolderTreeLoadPresentation.isFailure(replayed.phase))

    // And what it does NOT do: a partial failure keeps the live answer rather than mixing a
    // remembered tier into it.
    let partial = FolderTreeLoad(
      phase: .partiallyFailed([.archive]), foldersByTier: [.incoming: [node(9)]])
    let kept = FolderTreeLoad.resolve(fresh: partial, cached: cached)
    #expect(kept.phase == .partiallyFailed([.archive]))
    #expect(kept.folders(.incoming).map(\.id) == [9])
  }

  @Test("a snapshot fetched for another account replays NEITHER section")
  func aSubjectMismatchReplaysNeitherSection() async {
    // Positive control first: the same store, the same file, the matching subject — both
    // sections replay. Without it the two absences below prove only that something went wrong.
    let (control, controlTransport, _) = makeStore(snapshot: snapshot(subject: "user-a"))
    await controlTransport.setFolderSummariesShouldFail(true)
    await control.loadIfNeeded()
    #expect(control.summaries.map(\.folderId) == [1])
    #expect(control.cachedTree != nil)

    let (store, transport, _) = makeStore(snapshot: snapshot(subject: "user-b"))
    await transport.setFolderSummariesShouldFail(true)

    await store.loadIfNeeded()

    #expect(store.summaries.isEmpty)
    #expect(store.cachedTree == nil)
  }

  @Test("a snapshot fetched against another server replays NEITHER section")
  func aBaseURLMismatchReplaysNeitherSection() async {
    let (control, controlTransport, _) = makeStore(snapshot: snapshot())
    await controlTransport.setFolderSummariesShouldFail(true)
    await control.loadIfNeeded()
    #expect(control.cachedTree != nil)

    let (store, transport, _) = makeStore(
      snapshot: snapshot(baseURL: "https://elsewhere.example.invalid"))
    await transport.setFolderSummariesShouldFail(true)

    await store.loadIfNeeded()

    #expect(store.summaries.isEmpty)
    #expect(store.cachedTree == nil)
  }

  @Test("ending the session clears BOTH sections, not only the summaries")
  func endingTheSessionClearsBothSections() async {
    let (store, transport, _) = makeStore(snapshot: snapshot())
    await transport.setFolderSummariesShouldFail(true)
    await store.loadIfNeeded()
    #expect(store.summaries.map(\.folderId) == [1])
    #expect(store.cachedTree != nil)

    store.endSession()

    #expect(store.summaries.isEmpty)
    #expect(store.cachedTree == nil)
  }

  @Test("neither of the home's two answers drops the other when it is written")
  func neitherSectionDropsTheOtherOnWrite() async {
    let (store, transport, snapshotStore) = makeStore()
    await transport.setFolderSummariesResult([summary(1)])
    await store.loadIfNeeded()

    await store.rememberTree([.incoming: [node(7)]])

    let afterTreeWrite = await snapshotStore.stored
    #expect(afterTreeWrite?.summaries.map(\.folderId) == [1])
    #expect(afterTreeWrite?.tree?.foldersByTier["incoming"]?.map(\.id) == [7])
    #expect(afterTreeWrite?.subject == "user-a")

    // The other direction: the summaries' own write carries the tree section forward.
    await transport.setFolderSummariesResult([summary(2)])
    await store.refresh()

    let afterSummariesWrite = await snapshotStore.stored
    #expect(afterSummariesWrite?.summaries.map(\.folderId) == [2])
    #expect(afterSummariesWrite?.tree?.foldersByTier["incoming"]?.map(\.id) == [7])
  }
}
