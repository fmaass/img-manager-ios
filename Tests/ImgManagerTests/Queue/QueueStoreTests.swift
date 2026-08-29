import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// Which signed-in subject the store's provider reports, mutable mid-test so the cross-account
/// sequence (A signs out, B signs in against the SAME retained store — `RootView` keeps one
/// `QueueStore` for the app's whole lifetime) can be driven exactly as it happens in production.
@MainActor
private final class SubjectBox {
  var value: String?
  init(_ value: String?) { self.value = value }
}

@MainActor
@Suite("QueueStore — phase machine (Q3), own generation fence, debounced post-mutation refresh")
struct QueueStoreTests {
  private static let baseURL = "https://img.example.invalid"
  private static let liveFetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
  private static let cachedFetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeSummary(_ folderId: Int, _ readiness: String)
    -> Components.Schemas
    .FolderSummary
  {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderId, kind: "dated",
      lastTouched: nil, nothingLeftUnmarked: false, path: "p/\(folderId)", picked: 0,
      previewOutstanding: 0, readiness: .init(rawValue: readiness)!, sourceTier: "local",
      sync: nil, total: 1, unmarked: 1, withMasters: 0)
  }

  private func makeSnapshot(
    _ folderIds: [Int], subject: String = "user-a", baseURL: String = QueueStoreTests.baseURL,
    fetchedAt: Date = QueueStoreTests.cachedFetchedAt
  ) -> QueueSnapshot {
    QueueSnapshot(
      summaries: folderIds.map { makeSummary($0, "ready_to_review") }, fetchedAt: fetchedAt,
      baseURL: baseURL, subject: subject)
  }

  private func makeStore(
    debounceNanoseconds: UInt64 = 10_000_000,
    snapshot: QueueSnapshot? = nil,
    subject: SubjectBox = SubjectBox("user-a")
  ) -> (QueueStore, GridStubTransport, FakeQueueSnapshotStore) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let service = QueueService(client: client)
    let snapshotStore = FakeQueueSnapshotStore(stored: snapshot)
    let store = QueueStore(
      service: service, snapshotStore: snapshotStore, subject: { subject.value },
      baseURL: QueueStoreTests.baseURL, now: { QueueStoreTests.liveFetchedAt },
      debounceNanoseconds: debounceNanoseconds)
    return (store, transport, snapshotStore)
  }

  @Test("First load: initialLoading -> reachable, summaries populated")
  func firstLoadReaches() async {
    let (store, transport, _) = makeStore()
    await transport.setFolderSummariesResult([makeSummary(1, "ready_to_review")])
    #expect(store.phase == .initialLoading)
    await store.loadIfNeeded()
    #expect(store.phase == .reachable)
    #expect(store.summaries.map(\.folderId) == [1])
  }

  @Test("loadIfNeeded is a no-op once the first attempt already ran (success)")
  func loadIfNeededOnlyOnce() async {
    let (store, transport, _) = makeStore()
    await transport.setFolderSummariesResult([makeSummary(1, "ready_to_review")])
    await store.loadIfNeeded()
    await store.loadIfNeeded()
    #expect(await transport.callCount(Operations.FolderSummariesApiFolderSummariesGet.id) == 1)
  }

  @Test("First load failing with no cache -> unreachableNoCache, summaries stays empty")
  func firstLoadFailsNoCache() async {
    let (store, transport, _) = makeStore()
    await transport.setFolderSummariesShouldFail(true)
    await store.loadIfNeeded()
    #expect(store.phase == .unreachableNoCache)
    #expect(store.summaries.isEmpty)
    #expect(store.lastFetchedAt == nil)
  }

  @Test("A later refresh failing AFTER a success -> unreachableStale, prior summaries RETAINED")
  func refreshFailsRetainsStaleData() async {
    let (store, transport, _) = makeStore()
    await transport.setFolderSummariesResult([makeSummary(1, "ready_to_review")])
    await store.loadIfNeeded()
    #expect(store.phase == .reachable)

    await transport.setFolderSummariesShouldFail(true)
    await store.refresh()
    #expect(store.phase == .unreachableStale)
    #expect(store.summaries.map(\.folderId) == [1])  // retained, never cleared
  }

  @Test("Try Again (refresh from unreachableNoCache) recovers to reachable")
  func retryRecovers() async {
    let (store, transport, _) = makeStore()
    await transport.setFolderSummariesShouldFail(true)
    await store.loadIfNeeded()
    #expect(store.phase == .unreachableNoCache)

    await transport.setFolderSummariesResult([makeSummary(9, "needs_previews")])
    await store.refresh()
    #expect(store.phase == .reachable)
    #expect(store.summaries.map(\.folderId) == [9])
  }

  @Test("isRefreshing is true only while a POST-first-success refresh is in flight")
  func isRefreshingFlag() async throws {
    let (store, transport, _) = makeStore()
    await transport.setFolderSummariesResult([makeSummary(1, "ready_to_review")])
    await store.loadIfNeeded()
    #expect(store.isRefreshing == false)

    await transport.holdFolderSummariesRequests(true)
    let task = Task { await store.refresh() }
    await transport.waitUntilFolderSummariesStarted()
    #expect(store.isRefreshing == true)
    await transport.holdFolderSummariesRequests(false)
    await transport.releaseFolderSummaries()
    await task.value
    #expect(store.isRefreshing == false)
  }

  @Test(
    "Own generation fence: a stale, slower refresh response never clobbers a newer published one"
  )
  func staleRefreshDiscarded() async throws {
    let (store, transport, _) = makeStore()
    await transport.setFolderSummariesResult([makeSummary(1, "ready_to_review")])
    await store.loadIfNeeded()

    await transport.holdFolderSummariesRequests(true)
    let staleTask = Task { await store.refresh() }
    await transport.waitUntilFolderSummariesStarted()
    await transport.holdFolderSummariesRequests(false)

    // A second, faster refresh with DIFFERENT data lands while the first sits suspended.
    await transport.setFolderSummariesResult([makeSummary(2, "ready_to_review")])
    await store.refresh()
    #expect(store.summaries.map(\.folderId) == [2])

    await transport.releaseFolderSummaries()
    await staleTask.value
    // The stale response (captured as folder_id 1 at ITS OWN request time) must not overwrite
    // the newer published state once it finally completes.
    #expect(store.summaries.map(\.folderId) == [2])
  }

  @Test("invalidateAfterMutation coalesces two rapid calls into exactly ONE eventual refresh")
  func invalidateCoalesces() async throws {
    let (store, transport, _) = makeStore(debounceNanoseconds: 20_000_000)
    await transport.setFolderSummariesResult([makeSummary(1, "ready_to_review")])
    await store.loadIfNeeded()
    #expect(await transport.callCount(Operations.FolderSummariesApiFolderSummariesGet.id) == 1)

    store.invalidateAfterMutation()
    try await Task.sleep(nanoseconds: 5_000_000)  // well inside the 20ms debounce window
    store.invalidateAfterMutation()  // cancels the first pending debounce, restarts it

    try await Task.sleep(nanoseconds: 60_000_000)  // past the (restarted) debounce window
    #expect(await transport.callCount(Operations.FolderSummariesApiFolderSummariesGet.id) == 2)
  }

  // MARK: - IMGMGR-198: the cached last server answer, labelled stale

  @Test("Cache + unreachable server: the cached answer is shown as stale, with ITS timestamp")
  func cachedAnswerIsShownWhenUnreachable() async {
    let (store, transport, _) = makeStore(snapshot: makeSnapshot([3, 4]))
    await transport.setFolderSummariesShouldFail(true)

    await store.loadIfNeeded()

    // The launch presentation with a cache is the cached list under the stale banner — never
    // "Loading shoots…" and never the full-surface no-cache state.
    #expect(store.phase == .unreachableStale)
    #expect(store.summaries.map(\.folderId) == [3, 4])
    #expect(store.lastFetchedAt == QueueStoreTests.cachedFetchedAt)
  }

  @Test("Cache + reachable server: the live answer wins and is written back to the cache")
  func liveAnswerWinsAndIsPersisted() async {
    let (store, transport, snapshotStore) = makeStore(snapshot: makeSnapshot([3, 4]))
    await transport.setFolderSummariesResult([makeSummary(5, "needs_previews")])

    await store.loadIfNeeded()

    #expect(store.phase == .reachable)
    #expect(store.summaries.map(\.folderId) == [5])
    #expect(store.lastFetchedAt == QueueStoreTests.liveFetchedAt)
    let saved = await snapshotStore.savedSnapshots
    #expect(saved.count == 1)
    #expect(saved.last?.summaries.map(\.folderId) == [5])
    #expect(saved.last?.fetchedAt == QueueStoreTests.liveFetchedAt)
    #expect(saved.last?.subject == "user-a")
    #expect(saved.last?.baseURL == QueueStoreTests.baseURL)
  }

  @Test("A snapshot read released AFTER a newer live answer never overwrites it (hydrate fence)")
  func heldHydrationNeverOverwritesNewerLiveAnswer() async {
    // CAUSAL, not incidental: the snapshot READ itself is held open while a newer live
    // generation lands and publishes, then released. The disk read is a real suspension point —
    // a foreground refresh or a "Try Again" tap can genuinely land inside it — so hydration
    // carries the same generation fence the network path does.
    let (store, transport, snapshotStore) = makeStore(snapshot: makeSnapshot([3, 4]))
    await snapshotStore.holdLoads(true)
    await transport.setFolderSummariesResult([makeSummary(5, "needs_previews")])

    let hydrating = Task { await store.loadIfNeeded() }
    await snapshotStore.waitUntilLoadStarted()

    await store.refresh()
    #expect(store.phase == .reachable)
    #expect(store.summaries.map(\.folderId) == [5])

    await snapshotStore.holdLoads(false)
    await snapshotStore.releaseLoad()
    await hydrating.value

    #expect(store.summaries.map(\.folderId) == [5])
    #expect(store.phase == .reachable)
    #expect(store.lastFetchedAt == QueueStoreTests.liveFetchedAt)
    // The hydrating call also abandons its OWN live load once a newer answer is already
    // published — one network call in total, not a redundant second one.
    #expect(await transport.callCount(Operations.FolderSummariesApiFolderSummariesGet.id) == 1)
  }

  @Test("A snapshot written under a DIFFERENT subject is ignored")
  func foreignSubjectSnapshotIsIgnored() async {
    let (store, transport, _) = makeStore(snapshot: makeSnapshot([3], subject: "someone-else"))
    await transport.setFolderSummariesShouldFail(true)

    await store.loadIfNeeded()

    #expect(store.phase == .unreachableNoCache)
    #expect(store.summaries.isEmpty)
    #expect(store.lastFetchedAt == nil)
  }

  @Test("A snapshot written against a DIFFERENT base URL is ignored")
  func foreignBaseURLSnapshotIsIgnored() async {
    let (store, transport, _) = makeStore(
      snapshot: makeSnapshot([3], baseURL: "https://other.example.invalid"))
    await transport.setFolderSummariesShouldFail(true)

    await store.loadIfNeeded()

    #expect(store.phase == .unreachableNoCache)
    #expect(store.summaries.isEmpty)
  }

  @Test("Account switch: the retained store keeps NOTHING from the previous subject")
  func subjectChangeResetsTheRetainedStore() async {
    // The exact production sequence: `RootView` retains ONE QueueStore for the app's lifetime,
    // so after A signs out and B signs in, A's `.reachable` phase and A's cards are still
    // sitting in memory unless the store resets on the subject change.
    let subject = SubjectBox("user-a")
    let (store, transport, _) = makeStore(subject: subject)
    await transport.setFolderSummariesResult([makeSummary(1, "ready_to_review")])
    await store.loadIfNeeded()
    #expect(store.phase == .reachable)
    #expect(store.summaries.map(\.folderId) == [1])

    subject.value = "user-b"
    await transport.setFolderSummariesResult([makeSummary(7, "needs_previews")])
    await transport.holdFolderSummariesRequests(true)
    let loading = Task { await store.loadIfNeeded() }
    await transport.waitUntilFolderSummariesStarted()

    // Observed WHILE B's own fetch is in flight: A's answer is already gone, so there is no
    // window in which B is shown A's shoots.
    #expect(store.phase == .initialLoading)
    #expect(store.summaries.isEmpty)
    #expect(store.lastFetchedAt == nil)

    await transport.holdFolderSummariesRequests(false)
    await transport.releaseFolderSummaries()
    await loading.value

    #expect(store.phase == .reachable)
    #expect(store.summaries.map(\.folderId) == [7])
  }

  @Test("Account switch: the new subject does NOT hydrate the previous subject's snapshot")
  func subjectChangeDoesNotHydrateThePreviousSnapshot() async {
    let subject = SubjectBox("user-a")
    let (store, transport, _) = makeStore(snapshot: makeSnapshot([3, 4]), subject: subject)
    await transport.setFolderSummariesShouldFail(true)
    await store.loadIfNeeded()
    #expect(store.summaries.map(\.folderId) == [3, 4])

    subject.value = "user-b"
    await transport.setFolderSummariesShouldFail(true)
    await store.loadIfNeeded()

    #expect(store.phase == .unreachableNoCache)
    #expect(store.summaries.isEmpty)
  }

  @Test("No cache and no subject yet: the launch presentation is unchanged (Loading shoots…)")
  func noSubjectStillLoadsLive() async {
    let (store, transport, snapshotStore) = makeStore(subject: SubjectBox(nil))
    await transport.setFolderSummariesResult([makeSummary(1, "ready_to_review")])

    await store.loadIfNeeded()

    #expect(store.phase == .reachable)
    #expect(store.summaries.map(\.folderId) == [1])
    // Nothing to key a snapshot by, so nothing is written — the cache is per signed-in subject.
    #expect(await snapshotStore.savedSnapshots.isEmpty)
  }
}
