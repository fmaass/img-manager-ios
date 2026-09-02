import Foundation
import ImgManagerAPI

/// P7's own lazy hero-thumbnail loader (Q6) — a card's SINGLE representative image, fetched via
/// the two-step sanctioned path: `GET /api/images?folder_id=…&limit=1` (`GridService.images`)
/// then the existing grid-proxy fetch (`ProxyIdentity` token extraction + `GridService.proxy`,
/// the exact pattern `GridView.swift`'s `TileView` already uses), `grid` tier. NEVER
/// `GridStore.selectShoot` — that would clobber the working grid (Q6's own NEVER).
///
/// Deliberately independent of `GridStore`: its own cache, its own bounded-concurrency gate, no
/// shared generation counter — P6-coexistence adjudication 7 pins "queue/hero reads get their
/// OWN generation/cancellation tokens — they must not touch `GridStore.loadGeneration`". Calling
/// `GridService`'s own already-sanctioned read-only methods is fine (that type carries no
/// mutable state of its own); only `GridStore`'s INSTANCE state is off-limits.
actor HeroThumbnailLoader {
  enum FetchResult: Equatable, Sendable {
    case image(Data)
    case empty
    case failure
  }

  private let service: GridService
  private let maxConcurrent: Int
  private var cache: [String: Data] = [:]
  /// One in-flight fetch per cache key (IMGMGR-332). Two readers of the SAME key are the shipped
  /// case, not a corner one: the Queue card and the Folders-tree shoot row show one shoot. `hero`
  /// used to check the cache and then suspend on the concurrency gate leaving nothing behind for
  /// the second reader to join, so both fetched the limit-1 page and the proxy.
  private var inFlight: [String: Task<FetchResult, Never>] = [:]
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(service: GridService, maxConcurrent: Int = 4) {
    self.service = service
    self.maxConcurrent = maxConcurrent
  }

  /// One card's hero fetch, cached per (folderID, sourceTier) for the loader's lifetime and
  /// SINGLE-FLIGHT per that same key: a second reader of a key already being fetched awaits the
  /// running fetch instead of starting its own (IMGMGR-332).
  ///
  /// A SwiftUI `.task(id:)` per visible card is what gives this "cancellation on scroll-away",
  /// and the CALLER's cancellation is still honoured at both of this method's own boundaries —
  /// before anything is started, and on the way out. What it no longer does is abandon the fetch
  /// MID-FLIGHT: the fetch is now shared, so cancelling it on one reader's behalf would cancel
  /// it for the other reader too, which is exactly what a coalesced fetch must never do. A fetch
  /// that has started therefore runs to completion and fills the cache; the reader that went
  /// away simply does not use the answer.
  func hero(folderID: Int, sourceTier: GridSourceTier?) async -> FetchResult {
    let key = cacheKey(folderID: folderID, sourceTier: sourceTier)
    if let cached = cache[key] { return .image(cached) }
    guard !Task.isCancelled else { return .failure }

    if let joined = inFlight[key] {
      let result = await joined.value
      return Task.isCancelled ? .failure : result
    }

    // `Task {}` inherits this actor's isolation, but NOT the caller's cancellation — which is
    // what makes a scrolled-away waiter unable to cancel the fetch its neighbour is waiting on.
    let fetch = Task { await self.runFetch(key: key, folderID: folderID, sourceTier: sourceTier) }
    inFlight[key] = fetch
    let result = await fetch.value
    // Cleared by the INITIATOR, on every outcome — bytes, `.empty` or `.failure`. `runFetch`
    // neither throws nor cancels, so this line is always reached: an entry that outlived its
    // fetch would wedge every later reader of the key behind a task that will never finish.
    inFlight[key] = nil
    return Task.isCancelled ? .failure : result
  }

  /// The two-step fetch itself, run by exactly one task per key. It holds the concurrency slot
  /// for its whole duration, as the inline version did.
  private func runFetch(key: String, folderID: Int, sourceTier: GridSourceTier?) async
    -> FetchResult
  {
    await acquire()
    defer { release() }
    do {
      var query = GridImagesQuery(folderID: folderID)
      query.sourceTier = sourceTier
      let page = try await service.images(query, cursor: nil, limit: 1)
      guard let first = page.items.first else { return .empty }
      let token = ProxyIdentity.token(
        from: first.proxies.additionalProperties[ProxyTier.grid.rawValue]?.url)
      switch try await service.proxy(imageID: first.id, tier: .grid, v: token) {
      case .ok(let data):
        cache[key] = data
        return .image(data)
      case .notModified:
        return cache[key].map { .image($0) } ?? .empty
      case .notFound:
        return .empty
      }
    } catch {
      return .failure
    }
  }

  private func cacheKey(folderID: Int, sourceTier: GridSourceTier?) -> String {
    "\(folderID)|\(sourceTier?.rawValue ?? "")"
  }

  /// FIFO bounded-concurrency gate — same idiom as `GridStore`'s own mutation-lane queueing
  /// (`acquireLaneQueueing`/`releaseLane`), deliberately NOT that lane itself (P6 coexistence:
  /// "no second mutation lane" cuts both ways — this is a read-only gate with its own state).
  private func acquire() async {
    guard active >= maxConcurrent else {
      active += 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
    active += 1
  }

  private func release() {
    active -= 1
    guard !waiters.isEmpty else { return }
    waiters.removeFirst().resume()
  }
}
