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

  private var saveHoldEnabled = false
  private var saveHasStarted = false
  private var saveStartedContinuation: CheckedContinuation<Void, Never>?
  private var saveReleaseContinuation: CheckedContinuation<Void, Never>?

  /// The write is a suspension point too, so a test needs to land a sign-out INSIDE it — the
  /// window in which a store can resurrect the file the erasure just removed.
  func holdSaves(_ hold: Bool) { saveHoldEnabled = hold }

  func waitUntilSaveStarted() async {
    if saveHasStarted { return }
    await withCheckedContinuation { continuation in
      self.saveStartedContinuation = continuation
    }
  }

  func releaseSave() {
    saveReleaseContinuation?.resume()
    saveReleaseContinuation = nil
    saveHasStarted = false
  }

  func save(_ snapshot: QueueSnapshot) async {
    if saveHoldEnabled {
      saveHasStarted = true
      saveStartedContinuation?.resume()
      saveStartedContinuation = nil
      await withCheckedContinuation { continuation in
        self.saveReleaseContinuation = continuation
      }
    }
    stored = snapshot
    savedSnapshots.append(snapshot)
  }

  private var clearHoldEnabled = false
  private var clearHasStarted = false
  private var clearStartedContinuation: CheckedContinuation<Void, Never>?
  private var clearReleaseContinuation: CheckedContinuation<Void, Never>?

  /// Lets a test suspend INSIDE the erase hook — the window between "the credential is gone" and
  /// "every listener has fenced itself off" — and land an in-flight fetch's completion there.
  func holdClears(_ hold: Bool) { clearHoldEnabled = hold }

  func waitUntilClearStarted() async {
    if clearHasStarted { return }
    await withCheckedContinuation { continuation in
      self.clearStartedContinuation = continuation
    }
  }

  func releaseClear() {
    clearReleaseContinuation?.resume()
    clearReleaseContinuation = nil
    clearHasStarted = false
  }

  func clear() async {
    if clearHoldEnabled {
      clearHasStarted = true
      clearStartedContinuation?.resume()
      clearStartedContinuation = nil
      await withCheckedContinuation { continuation in
        self.clearReleaseContinuation = continuation
      }
    }
    stored = nil
    clearCount += 1
  }
}
