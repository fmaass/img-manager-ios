import Foundation
import ImgManagerAPI
import Observation

/// P7's own orchestrator for the work-queue home (WP8, IMGMGR-116) — owns the loaded
/// `FolderSummary` list and the screen's connectivity/loading state machine (Q3). Deliberately
/// independent of `GridStore`: its own generation counter, its own debounce, no shared state in
/// either direction (P6 coexistence, binding adjudication 7: "queue reads stay read-only and
/// separate").
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
  /// Q3 "refresh over data": true only while a refresh is in flight AND `phase` already reached
  /// `.reachable` at least once — the view shows a small activity indicator, never the centered
  /// first-load spinner, and never touches `summaries`/scroll/expansion/selection.
  private(set) var isRefreshing = false

  private let service: QueueService
  private let debounceNanoseconds: UInt64
  private var hasLoadedSuccessfullyOnce = false
  private var loadGeneration = 0
  private var debounceTask: Task<Void, Never>?

  /// `debounceNanoseconds` is test-injectable (default 400ms) so a coalescing test proves the
  /// real behaviour in milliseconds, never by waiting out the production interval.
  init(service: QueueService, debounceNanoseconds: UInt64 = 400_000_000) {
    self.service = service
    self.debounceNanoseconds = debounceNanoseconds
  }

  /// The screen's own first-appearance entry point — a no-op once the first attempt (success OR
  /// failure) has already run, so re-appearing never re-flashes the centered spinner over
  /// already-rendered content.
  func loadIfNeeded() async {
    guard phase == .initialLoading, !hasLoadedSuccessfullyOnce else { return }
    await performLoad()
  }

  /// Foreground hook, pull-to-refresh, and "Try Again" all route through this — a fresh attempt
  /// regardless of the CURRENT phase (retry must work from either unreachable state, not only
  /// after a prior success).
  func refresh() async {
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

  private func performLoad() async {
    loadGeneration += 1
    let generation = loadGeneration
    if hasLoadedSuccessfullyOnce {
      isRefreshing = true
    } else {
      phase = .initialLoading
    }
    defer { if generation == loadGeneration { isRefreshing = false } }
    do {
      let result = try await service.summaries()
      guard generation == loadGeneration else { return }
      summaries = result
      phase = .reachable
      hasLoadedSuccessfullyOnce = true
    } catch {
      guard generation == loadGeneration else { return }
      // "No cache" vs "stale data" (Q3) is read off whether there is anything to retain, not
      // off `hasLoadedSuccessfullyOnce` alone — a successful-but-empty prior fetch has no cards
      // to keep either, so it takes the same full-surface path as never having loaded at all.
      phase = summaries.isEmpty ? .unreachableNoCache : .unreachableStale
    }
  }
}
