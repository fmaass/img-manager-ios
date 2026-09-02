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
  /// The LIVE readers of each in-flight key, by token — what makes a shared fetch cancellable
  /// without taking it away from anybody (fix round). A reader that leaves through cancellation
  /// removes its token; when the last one goes the fetch has nobody left to serve and is
  /// cancelled. A `Set` is what makes "this reader has left" idempotent: the cancellation handler
  /// and the normal return can both fire for one call, and only the first of them may count.
  private var readers: [String: Set<Int>] = [:]
  private var nextReaderToken = 0
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
  /// and cancellation still means what it always did — `runFetch` re-checks it after the
  /// concurrency gate and again before the proxy step, so a fetch nobody is waiting for occupies
  /// no slot and never starts its second network call. What changed is only WHOSE cancellation
  /// decides: the fetch belongs to every reader of its key, so it is abandoned when its LAST
  /// reader leaves, never when one of several does. A reader leaving on its own returns
  /// `.failure` for itself and takes nothing away from the readers that remain.
  ///
  /// A cancelled fetch fills no cache and leaves no in-flight entry behind, so the next reader of
  /// that key starts a clean one.
  func hero(folderID: Int, sourceTier: GridSourceTier?) async -> FetchResult {
    let key = cacheKey(folderID: folderID, sourceTier: sourceTier)
    if let cached = cache[key] { return .image(cached) }
    guard !Task.isCancelled else { return .failure }

    // `Task {}` inherits this actor's isolation, but NOT the caller's cancellation — a reader
    // that goes away must not cancel a fetch its neighbour is still waiting on. Who DOES cancel
    // it is `readerLeft`, once nobody is left.
    let joined = inFlight[key]
    let fetch =
      joined ?? Task { await self.runFetch(key: key, folderID: folderID, sourceTier: sourceTier) }
    if joined == nil { inFlight[key] = fetch }
    let token = registerReader(of: key)

    // `await fetch.value` does NOT return when the CALLER is cancelled — the shared task is not
    // this task — so the departure has to be observed through the handler rather than after it.
    let result = await withTaskCancellationHandler {
      await fetch.value
    } onCancel: {
      // Nonisolated by contract, so the bookkeeping hops back onto the actor.
      Task { await self.readerLeft(key, token: token, cancelled: true) }
    }

    readerLeft(key, token: token, cancelled: false)
    // Cleared by the INITIATOR, on every outcome — bytes, `.empty` or `.failure` — and only while
    // the entry is still THIS fetch: a cancelled key can already have been cleared and re-started
    // by a later reader, and clearing that one would hand the next reader a duplicate fetch.
    if joined == nil, inFlight[key] == fetch { inFlight[key] = nil }
    return Task.isCancelled ? .failure : result
  }

  private func registerReader(of key: String) -> Int {
    nextReaderToken &+= 1
    let token = nextReaderToken
    readers[key, default: []].insert(token)
    return token
  }

  /// One reader stops waiting. Idempotent per reader by set membership, because the cancellation
  /// handler and the normal return can both fire for a single call.
  private func readerLeft(_ key: String, token: Int, cancelled: Bool) {
    guard var live = readers[key], live.remove(token) != nil else { return }
    guard live.isEmpty else {
      readers[key] = live
      return
    }
    readers[key] = nil
    guard cancelled else { return }
    // The LAST reader of this key left through cancellation: there is nobody to hand bytes to, so
    // the shared fetch must stop taking a concurrency slot and must not run its network steps.
    // Dropping the entry with it is what lets the next reader of the key start a fresh fetch —
    // the cancelled one caches nothing.
    inFlight[key]?.cancel()
    inFlight[key] = nil
  }

  /// The two-step fetch itself, run by exactly one task per key. It holds the concurrency slot
  /// for its whole duration, as the inline version did, and re-checks cancellation at the same
  /// two boundaries the inline version did — here that means "every reader has gone".
  private func runFetch(key: String, folderID: Int, sourceTier: GridSourceTier?) async
    -> FetchResult
  {
    await acquire()
    defer { release() }
    guard !Task.isCancelled else { return .failure }
    do {
      var query = GridImagesQuery(folderID: folderID)
      query.sourceTier = sourceTier
      let page = try await service.images(query, cursor: nil, limit: 1)
      guard let first = page.items.first else { return .empty }
      guard !Task.isCancelled else { return .failure }
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
