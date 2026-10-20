import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// Holds the queue store the erase hook has to reach, because the hook is built BEFORE the store
/// exists (the store reads the session's subject, the session's hook reaches the store) — the
/// same write-once knot `RootView.init` ties with its two boxes.
@MainActor
private final class StoreBox {
  var store: QueueStore?
}

/// Diff-gate delta, blocker 1: a real `AuthSession.signOut()` while a queue fetch is in flight.
/// The interesting instant is INSIDE the erase hook — after the credential is gone, before every
/// listener has fenced itself off — and these tests put the fetch's completion exactly there by
/// suspending the hook's own cache clear.
///
/// The hook here is deliberately wired the WRONG way round (file first, fence second) in the
/// first test: the guarantee under test is that `AuthSession` publishes `.signedOut` BEFORE
/// running the hook at all, so an answer arriving in that window is already recognisable as
/// another session's. A guarantee that only holds when the hook's internal statements are in the
/// right order is one refactor away from being gone.
@MainActor
@Suite("Queue cache vs. a session ending mid-fetch")
struct QueueCacheSessionEndTests {
  private func makeSummary(_ folderId: Int) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderId, kind: "dated",
      lastTouched: nil, nothingLeftUnmarked: false, path: "p/\(folderId)", picked: 0,
      previewOutstanding: 0, readiness: .init(rawValue: "ready_to_review")!, sourceTier: "local",
      sync: nil, total: 1, unmarked: 1, untouched: false, withMasters: 0)
  }

  private func makeWiring(fenceFirst: Bool) -> (
    AuthSession, QueueStore, GridStubTransport, FakeQueueSnapshotStore, FakeCredentialStore
  ) {
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")
    let credentials = FakeCredentialStore(loadResults: [.present(credential)])
    let cache = FakeQueueSnapshotStore()
    let queueTransport = GridStubTransport()
    let queueService = QueueService(
      client: ImgManagerAPIClient.make(transport: queueTransport))
    let box = StoreBox()
    let auth = AuthSession(
      credentialStore: credentials,
      client: ImgManagerAPIClient.make(transport: AuthOperationStubTransport()),
      onCredentialsErased: {
        if fenceFirst {
          box.store?.endSession()
          await cache.clear()
        } else {
          await cache.clear()
          box.store?.endSession()
        }
      })
    let store = QueueStore(
      service: queueService, snapshotStore: cache,
      subject: {
        guard case .signedIn(let subject) = auth.status else { return nil }
        return subject
      },
      baseURL: "https://img.example.invalid",
      now: { Date(timeIntervalSince1970: 1_800_000_000) })
    box.store = store
    return (auth, store, queueTransport, cache, credentials)
  }

  @Test("A fetch completing INSIDE the erase hook writes no snapshot, even hook-ordered wrongly")
  func fetchCompletingInsideTheEraseHookPersistsNothing() async {
    let (auth, store, transport, cache, _) = makeWiring(fenceFirst: false)
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")
    await auth.adopt(freshCredential: credential)
    #expect(auth.status == .signedIn(subject: "alice"))

    await transport.setFolderSummariesResult([makeSummary(1)])
    await transport.holdFolderSummariesRequests(true)
    let inFlight = Task { await store.loadIfNeeded() }
    await transport.waitUntilFolderSummariesStarted()

    // Suspend the hook's own clear, so the sign-out is halfway done: the credential is erased,
    // the file is not yet gone, and this wiring has not advanced the store's fence.
    await cache.holdClears(true)
    let signingOut = Task { await auth.signOut() }
    await cache.waitUntilClearStarted()

    // The fetch lands in exactly that window.
    await transport.holdFolderSummariesRequests(false)
    await transport.releaseFolderSummaries()
    await inFlight.value

    await cache.holdClears(false)
    await cache.releaseClear()
    await signingOut.value

    #expect(await cache.savedSnapshots.isEmpty)
    #expect(await cache.stored == nil)
    #expect(store.summaries.isEmpty)
    #expect(store.lastFetchedAt == nil)
    #expect(auth.status == .signedOut)
  }

  @Test("Production wiring (fence first) — same window, same outcome")
  func fenceFirstWiringPersistsNothing() async {
    let (auth, store, transport, cache, _) = makeWiring(fenceFirst: true)
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")
    await auth.adopt(freshCredential: credential)

    await transport.setFolderSummariesResult([makeSummary(1)])
    await transport.holdFolderSummariesRequests(true)
    let inFlight = Task { await store.loadIfNeeded() }
    await transport.waitUntilFolderSummariesStarted()

    await cache.holdClears(true)
    let signingOut = Task { await auth.signOut() }
    await cache.waitUntilClearStarted()
    await transport.holdFolderSummariesRequests(false)
    await transport.releaseFolderSummaries()
    await inFlight.value
    await cache.holdClears(false)
    await cache.releaseClear()
    await signingOut.value

    #expect(await cache.savedSnapshots.isEmpty)
    #expect(await cache.stored == nil)
    #expect(store.summaries.isEmpty)
  }

  @Test("Positive control: the same held fetch with NO sign-out publishes and persists")
  func heldFetchWithoutSignOutPersists() async {
    let (auth, store, transport, cache, _) = makeWiring(fenceFirst: true)
    let credential = Credential(token: "tok", expiresAt: Date(), subject: "alice")
    await auth.adopt(freshCredential: credential)

    await transport.setFolderSummariesResult([makeSummary(1)])
    await transport.holdFolderSummariesRequests(true)
    let inFlight = Task { await store.loadIfNeeded() }
    await transport.waitUntilFolderSummariesStarted()
    await transport.holdFolderSummariesRequests(false)
    await transport.releaseFolderSummaries()
    await inFlight.value

    // Without this, both tests above would pass just as well against a store that persists
    // nothing at all, or a transport that never answers.
    #expect(store.phase == .reachable)
    #expect(store.summaries.map(\.folderId) == [1])
    #expect(await cache.savedSnapshots.count == 1)
    #expect(await cache.stored?.subject == "alice")
  }
}
