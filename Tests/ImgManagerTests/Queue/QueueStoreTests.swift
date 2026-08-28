import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

@MainActor
@Suite("QueueStore — phase machine (Q3), own generation fence, debounced post-mutation refresh")
struct QueueStoreTests {

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

  private func makeStore(debounceNanoseconds: UInt64 = 10_000_000) -> (
    QueueStore, GridStubTransport
  ) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let service = QueueService(client: client)
    return (QueueStore(service: service, debounceNanoseconds: debounceNanoseconds), transport)
  }

  @Test("First load: initialLoading -> reachable, summaries populated")
  func firstLoadReaches() async {
    let (store, transport) = makeStore()
    await transport.setFolderSummariesResult([makeSummary(1, "ready_to_review")])
    #expect(store.phase == .initialLoading)
    await store.loadIfNeeded()
    #expect(store.phase == .reachable)
    #expect(store.summaries.map(\.folderId) == [1])
  }

  @Test("loadIfNeeded is a no-op once the first attempt already ran (success)")
  func loadIfNeededOnlyOnce() async {
    let (store, transport) = makeStore()
    await transport.setFolderSummariesResult([makeSummary(1, "ready_to_review")])
    await store.loadIfNeeded()
    await store.loadIfNeeded()
    #expect(await transport.callCount(Operations.FolderSummariesApiFolderSummariesGet.id) == 1)
  }

  @Test("First load failing with no cache -> unreachableNoCache, summaries stays empty")
  func firstLoadFailsNoCache() async {
    let (store, transport) = makeStore()
    await transport.setFolderSummariesShouldFail(true)
    await store.loadIfNeeded()
    #expect(store.phase == .unreachableNoCache)
    #expect(store.summaries.isEmpty)
  }

  @Test("A later refresh failing AFTER a success -> unreachableStale, prior summaries RETAINED")
  func refreshFailsRetainsStaleData() async {
    let (store, transport) = makeStore()
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
    let (store, transport) = makeStore()
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
    let (store, transport) = makeStore()
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
    let (store, transport) = makeStore()
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
    let (store, transport) = makeStore(debounceNanoseconds: 20_000_000)
    await transport.setFolderSummariesResult([makeSummary(1, "ready_to_review")])
    await store.loadIfNeeded()
    #expect(await transport.callCount(Operations.FolderSummariesApiFolderSummariesGet.id) == 1)

    store.invalidateAfterMutation()
    try await Task.sleep(nanoseconds: 5_000_000)  // well inside the 20ms debounce window
    store.invalidateAfterMutation()  // cancels the first pending debounce, restarts it

    try await Task.sleep(nanoseconds: 60_000_000)  // past the (restarted) debounce window
    #expect(await transport.callCount(Operations.FolderSummariesApiFolderSummariesGet.id) == 2)
  }
}
