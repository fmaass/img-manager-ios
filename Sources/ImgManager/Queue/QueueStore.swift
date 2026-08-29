import Foundation
import ImgManagerAPI
import Observation

/// P7's own orchestrator for the work-queue home (WP8, IMGMGR-116) — owns the loaded
/// `FolderSummary` list and the screen's connectivity/loading state machine (Q3). Deliberately
/// independent of `GridStore`: its own generation counter, its own debounce, no shared state in
/// either direction (P6 coexistence, binding adjudication 7: "queue reads stay read-only and
/// separate").
///
/// IMGMGR-198 adds ONE thing: the last server answer survives the app's death, so a launch with
/// no route to the server replays it LABELLED as stale instead of showing an empty surface. It
/// is not offline mode — nothing here is editable, nothing is queued, and no write path consults
/// the cache (spec p3231 §Q10 stands). The 4-state machine is untouched: a replayed cache is
/// published into the EXISTING `.unreachableStale` phase, which is what the stale banner already
/// renders.
@Observable
@MainActor
final class QueueStore {
  /// Q3's four rendered states. `.reachable` with an empty `summaries` array IS the "No shoots"
  /// empty state (a view-level check on `summaries.isEmpty`, not a fifth phase) — a decoded
  /// `items: []` is a successful, reachable response.
  enum Phase: Equatable {
    case initialLoading
    case reachable
    case unreachableNoCache
    case unreachableStale
  }

  private(set) var phase: Phase = .initialLoading
  private(set) var summaries: [Components.Schemas.FolderSummary] = []
  /// Q3 "refresh over data": true only while a refresh is in flight AND there is already
  /// something on screen to refresh OVER — a prior success, or a replayed cache — so the view
  /// shows a small activity indicator, never the centered first-load spinner, and never touches
  /// `summaries`/scroll/expansion/selection.
  private(set) var isRefreshing = false
  /// When the currently displayed `summaries` were fetched FROM THE SERVER — the timestamp the
  /// stale banner labels a replayed cache with. Never a "cache was read" time.
  private(set) var lastFetchedAt: Date?

  private let service: QueueService
  private let snapshotStore: any QueueSnapshotPersisting
  /// The signed-in subject, read LIVE rather than passed once at construction: `RootView` keeps
  /// one `QueueStore` for the app's whole lifetime, so the store has to notice the account under
  /// it changing. Reading `AuthSession.status` through a closure keeps that a value the store
  /// can check at its own entry points, instead of view glue whose ordering against
  /// `QueueView`'s `.task` nobody can pin.
  private let subject: @MainActor () -> String?
  private let baseURL: String
  private let now: @MainActor () -> Date
  private let debounceNanoseconds: UInt64
  private var hasLoadedSuccessfullyOnce = false
  private var hasAttemptedHydration = false
  private var activeSubject: String?
  private var loadGeneration = 0
  private var debounceTask: Task<Void, Never>?

  /// `debounceNanoseconds` is test-injectable (default 400ms) so a coalescing test proves the
  /// real behaviour in milliseconds, never by waiting out the production interval. `now` is
  /// injectable for the same reason: a persisted timestamp has to be assertable exactly.
  init(
    service: QueueService,
    snapshotStore: any QueueSnapshotPersisting = QueueSnapshotStore(),
    subject: @escaping @MainActor () -> String? = { nil },
    baseURL: String = ImgManagerAPIClient.baseURL.absoluteString,
    now: @escaping @MainActor () -> Date = { Date() },
    debounceNanoseconds: UInt64 = 400_000_000
  ) {
    self.service = service
    self.snapshotStore = snapshotStore
    self.subject = subject
    self.baseURL = baseURL
    self.now = now
    self.debounceNanoseconds = debounceNanoseconds
  }

  /// The screen's own first-appearance entry point — a no-op once the first attempt (success OR
  /// failure) has already run, so re-appearing never re-flashes the centered spinner over
  /// already-rendered content. With a cache present, the launch presentation is the cached list
  /// under the stale banner rather than "Loading shoots…" (the queue's OPEN loading/empty
  /// presentation question, p3231 :264-267, settled that way here).
  func loadIfNeeded() async {
    resetIfSubjectChanged()
    guard phase == .initialLoading, !hasLoadedSuccessfullyOnce else { return }
    await hydrateFromSnapshot()
    // Reading the snapshot is a real suspension point, and a foreground refresh or a "Try
    // Again" tap can land inside it: if a live answer was published while this call was
    // suspended, there is nothing left for it to do.
    guard !hasLoadedSuccessfullyOnce else { return }
    await performLoad()
  }

  /// Foreground hook, pull-to-refresh, and "Try Again" all route through this — a fresh attempt
  /// regardless of the CURRENT phase (retry must work from either unreachable state, not only
  /// after a prior success).
  func refresh() async {
    resetIfSubjectChanged()
    await performLoad()
  }

  /// Post-mutation freshness (P6 coexistence item 7c): coalesces rapid repeat calls into ONE
  /// eventual re-read via cancel-and-replace debouncing — never an optimistic local patch of
  /// readiness/counts/nothingLeftUnmarked (Q4 drift hazard: "summing counts to infer
  /// completion" and friends are explicitly named violations).
  func invalidateAfterMutation() {
    debounceTask?.cancel()
    debounceTask = Task { [weak self, debounceNanoseconds] in
      try? await Task.sleep(nanoseconds: debounceNanoseconds)
      guard let self, !Task.isCancelled else { return }
      await self.refresh()
    }
  }

  /// The cross-account guard. A retained store must carry NOTHING from the account before it:
  /// after A signs out and B signs in, A's `.reachable` phase and A's cards are still sitting in
  /// this object unless they are dropped here, and `loadIfNeeded`'s own "already loaded" guard
  /// would otherwise keep B looking at them forever. Bumping the generation fences an in-flight
  /// network load AND a suspended snapshot read, so neither can publish A's answer afterwards.
  private func resetIfSubjectChanged() {
    let current = subject()
    guard current != activeSubject else { return }
    activeSubject = current
    loadGeneration += 1
    debounceTask?.cancel()
    debounceTask = nil
    summaries = []
    lastFetchedAt = nil
    phase = .initialLoading
    isRefreshing = false
    hasLoadedSuccessfullyOnce = false
    hasAttemptedHydration = false
  }

  /// Replays the persisted answer once per session/subject, and only if it is genuinely THIS
  /// session's answer: same subject, same server. Everything about it is provisional — the live
  /// fetch that follows overwrites it, and the fence above discards it outright if a newer
  /// answer landed while the read was suspended.
  private func hydrateFromSnapshot() async {
    guard !hasAttemptedHydration, let activeSubject else { return }
    hasAttemptedHydration = true
    let generation = loadGeneration
    guard let snapshot = await snapshotStore.load() else { return }
    guard generation == loadGeneration, !hasLoadedSuccessfullyOnce else { return }
    guard snapshot.subject == activeSubject, snapshot.baseURL == baseURL,
      !snapshot.summaries.isEmpty
    else { return }
    summaries = snapshot.summaries
    lastFetchedAt = snapshot.fetchedAt
    phase = .unreachableStale
  }

  private func performLoad() async {
    loadGeneration += 1
    let generation = loadGeneration
    // Anything already on screen — a prior success OR a replayed cache — makes this a refresh
    // over data; only a genuinely blank queue takes the centered first-load spinner.
    if hasLoadedSuccessfullyOnce || !summaries.isEmpty {
      isRefreshing = true
    } else {
      phase = .initialLoading
    }
    defer { if generation == loadGeneration { isRefreshing = false } }
    do {
      let result = try await service.summaries()
      guard generation == loadGeneration else { return }
      let fetchedAt = now()
      summaries = result
      lastFetchedAt = fetchedAt
      phase = .reachable
      hasLoadedSuccessfullyOnce = true
      // Persisted under the subject it was fetched for, and only then: a store with no
      // signed-in subject has nothing legitimate to key a cache by, so it writes nothing.
      if let activeSubject {
        await snapshotStore.save(
          QueueSnapshot(
            summaries: result, fetchedAt: fetchedAt, baseURL: baseURL, subject: activeSubject))
      }
    } catch {
      guard generation == loadGeneration else { return }
      // "No cache" vs "stale data" (Q3) is read off whether there is anything to retain, not
      // off `hasLoadedSuccessfullyOnce` alone — a successful-but-empty prior fetch has no cards
      // to keep either, so it takes the same full-surface path as never having loaded at all.
      // A replayed snapshot counts as something to retain, which is the whole point of it.
      phase = summaries.isEmpty ? .unreachableNoCache : .unreachableStale
    }
  }
}
