import Foundation

@testable import ImgManager

/// A scriptable double for `QueueSnapshotPersisting` — the seam that lets `QueueStore` tests
/// prove hydration, the save-on-success write, the hydrate-vs-live fence and the subject guard
/// without touching the file system (the REAL actor is exercised unmocked in
/// `QueueSnapshotStoreTests.swift`, same division of labour as `FakeCredentialStore` vs
/// `CredentialStoreTests`).
///
/// `holdLoads`/`waitUntilLoadStarted`/`releaseLoad` mirror `GridStubTransport`'s own hold
/// pattern, including its ordering discipline: the answer is resolved BEFORE the suspend, so a
/// held read truthfully returns what was on "disk" at READ time. Without that, a save landing
/// while the read sits suspended would silently make the stale and fresh answers identical and
/// the fence test would prove nothing.
actor FakeQueueSnapshotStore: QueueSnapshotPersisting {
  private(set) var stored: QueueSnapshot?
  private(set) var savedSnapshots: [QueueSnapshot] = []
  private(set) var clearCount = 0
  private(set) var loadCount = 0

  private var holdEnabled = false
  private var hasStarted = false
  private var startedContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  init(stored: QueueSnapshot? = nil) {
    self.stored = stored
  }

  func holdLoads(_ hold: Bool) { holdEnabled = hold }

  /// Suspends until a held `load()` has genuinely entered — deterministic, never a sleep.
  func waitUntilLoadStarted() async {
    if hasStarted { return }
    await withCheckedContinuation { continuation in
      self.startedContinuation = continuation
    }
  }

  func releaseLoad() {
    releaseContinuation?.resume()
    releaseContinuation = nil
    hasStarted = false
  }

  func load() async -> QueueSnapshot? {
    loadCount += 1
    let resolved = stored
    if holdEnabled {
      hasStarted = true
      startedContinuation?.resume()
      startedContinuation = nil
      await withCheckedContinuation { continuation in
        self.releaseContinuation = continuation
      }
    }
    return resolved
  }

  func save(_ snapshot: QueueSnapshot) async {
    stored = snapshot
    savedSnapshots.append(snapshot)
  }

  func clear() async {
    stored = nil
    clearCount += 1
  }
}
