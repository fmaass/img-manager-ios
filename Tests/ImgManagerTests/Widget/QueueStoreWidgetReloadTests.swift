import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP12 (IMGMGR-199). The reload seam lives on `QueueStore` because `QueueStore` is the only
/// type that knows whether a summary request actually succeeded — hanging the reload off
/// `ForegroundRefresh` instead would fire it just as eagerly after a failure and republish stale
/// counts to the widget as though they were fresh. These tests are that distinction.
///
/// A separate file from `QueueStoreTests` on purpose: this lane's only change to the queue is the
/// seam, and keeping its tests apart keeps the diff (and any merge) confined to it.
@MainActor
@Suite("QueueStore — widget reload is requested on success only")
struct QueueStoreWidgetReloadTests {

  /// Sendable by construction so it can be captured by the seam closure regardless of what
  /// isolation the closure ends up with.
  private final class ReloadSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
      lock.lock()
      value += 1
      lock.unlock()
    }

    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  private func makeSummary(_ folderId: Int) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderId, kind: "dated",
      lastTouched: nil, nothingLeftUnmarked: false, path: "p/\(folderId)", picked: 0,
      previewOutstanding: 0, readiness: .init(rawValue: "ready_to_review")!, sourceTier: "local",
      sync: nil, total: 1, unmarked: 1, withMasters: 0)
  }

  private func makeStore(_ spy: ReloadSpy) -> (QueueStore, GridStubTransport) {
    let transport = GridStubTransport()
    let service = QueueService(client: ImgManagerAPIClient.make(transport: transport))
    return (
      QueueStore(
        service: service, debounceNanoseconds: 10_000_000, reloadWidgets: { spy.bump() }),
      transport
    )
  }

  @Test("A successful first load asks the widget to reload, exactly once")
  func successfulLoadReloadsOnce() async {
    let spy = ReloadSpy()
    let (store, transport) = makeStore(spy)
    await transport.setFolderSummariesResult([makeSummary(1)])

    await store.loadIfNeeded()

    #expect(store.phase == .reachable)
    #expect(spy.count == 1)
  }

  @Test("A failed load asks for NO reload — the widget keeps whatever it last had")
  func failedLoadDoesNotReload() async {
    let spy = ReloadSpy()
    let (store, transport) = makeStore(spy)
    await transport.setFolderSummariesShouldFail(true)

    await store.loadIfNeeded()

    #expect(store.phase == .unreachableNoCache)
    #expect(spy.count == 0)
  }

  @Test("A refresh that fails after an earlier success does not reload again")
  func failedRefreshAfterSuccessDoesNotReloadAgain() async {
    let spy = ReloadSpy()
    let (store, transport) = makeStore(spy)
    await transport.setFolderSummariesResult([makeSummary(1)])
    await store.loadIfNeeded()
    #expect(spy.count == 1)

    await transport.setFolderSummariesShouldFail(true)
    await store.refresh()

    #expect(store.phase == .unreachableStale)
    #expect(spy.count == 1)
  }

  @Test("Recovering from an unreachable state reloads on the refresh that succeeds")
  func recoveryReloads() async {
    let spy = ReloadSpy()
    let (store, transport) = makeStore(spy)
    await transport.setFolderSummariesShouldFail(true)
    await store.loadIfNeeded()
    #expect(spy.count == 0)

    await transport.setFolderSummariesResult([makeSummary(9)])
    await store.refresh()

    #expect(store.phase == .reachable)
    #expect(spy.count == 1)
  }
}
