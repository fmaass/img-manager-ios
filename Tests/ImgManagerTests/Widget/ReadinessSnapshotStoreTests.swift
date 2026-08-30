import Foundation
import Testing

@testable import ImgManager

/// WP12 (IMGMGR-199). The widget's private last-good file, on real disk in a throwaway
/// directory — the store's whole job is that a failed refresh never blanks the widget, so its
/// round trip is proven against the filesystem rather than a memory double.
@Suite("ReadinessSnapshotStore — the widget's last successful reading")
struct ReadinessSnapshotStoreTests {

  private let fetchedAt = Date(timeIntervalSince1970: 1_756_000_000)

  private func makeStore() -> ReadinessSnapshotStore {
    ReadinessSnapshotStore(
      directory: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("readiness-\(UUID().uuidString)", isDirectory: true))
  }

  @Test("Nothing stored yet reads as nil — the never-fetched state, not an error")
  func absentReadsNil() {
    #expect(makeStore().load() == nil)
  }

  @Test("A live entry survives a round trip with its counts and fetch time intact")
  func liveEntryRoundTrips() {
    let store = makeStore()
    let entry = ReadinessEntry(
      date: fetchedAt, state: .live, countsBySection: ["ready_to_review": 4, "sync_problem": 1],
      fetchedAt: fetchedAt)
    store.save(entry)

    #expect(store.load() == entry)
    #expect(store.load()?.count(for: .readyToReview) == 4)
    #expect(store.load()?.syncProblemCount == 1)
  }

  /// A snapshot IS the last successful fetch. Persisting anything else would let a fallback
  /// render, or a signed-out placeholder, become the thing a later fallback renders FROM.
  @Test("Only a live entry is ever persisted — every other state is refused")
  func onlyLiveEntriesArePersisted() {
    for state in [ReadinessEntryState.lastKnown, .signedOut, .noData] {
      let store = makeStore()
      store.save(
        ReadinessEntry(
          date: fetchedAt, state: state, countsBySection: ["ready_to_review": 4],
          fetchedAt: state == .lastKnown ? fetchedAt : nil))
      #expect(store.load() == nil)
    }
  }

  @Test("Clearing removes the snapshot, and clearing an empty store is not an error")
  func clearRemovesTheSnapshot() {
    let store = makeStore()
    store.clear()
    store.save(
      ReadinessEntry(
        date: fetchedAt, state: .live, countsBySection: ["needs_previews": 2],
        fetchedAt: fetchedAt))
    #expect(store.load() != nil)

    store.clear()
    #expect(store.load() == nil)
  }
}
