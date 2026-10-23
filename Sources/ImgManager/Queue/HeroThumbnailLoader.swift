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
  /// One cached cover and the identity its bytes belong to (IMGMGR-622). The folder summary
  /// carries no hero image and no proxy token, so the only place the loader can learn that the
  /// server re-identified a cover (the v0.23.2 PROXY_RAW_ICC_GENERATION flip re-tokened every
  /// local RAW preview) is the limit-1 page it already reads — keyed by folder and tier alone, the
  /// old bytes outlived that change until a relaunch while the grid behind them reloaded.
  private struct Entry {
    let data: Data
    let imageID: Int
    let token: String?
    /// The folder-list fetch this entry was last checked against. A reader stamped with any
    /// OTHER fetch re-checks once; readers of the same fetch are served from memory, so the
    /// request volume between two list refreshes is what it always was.
    var checkedAgainst: Date?
  }
  private var cache: [String: Entry] = [:]
  /// One in-flight fetch per cache key (IMGMGR-332), carrying its OWN live readers.
  ///
  /// Two readers of one key are the shipped case, not a corner one: the Queue card and the
  /// Folders-tree shoot row show one shoot. `hero` used to check the cache and then suspend on
  /// the concurrency gate leaving nothing behind for the second reader to join, so both fetched
  /// the limit-1 page and the proxy.
  ///
  /// The readers live INSIDE the fetch rather than beside the key, and that is load-bearing
  /// (fix round 2). Keyed by key alone, a reader of a COMPLETED fetch that had not resumed yet
  /// still counted as live: its stale token kept the set non-empty, so the next fetch on that
  /// key could not be cancelled by its own reader leaving, and then the stale reader emptied the
  /// set without cancelling — the abandoned-fetch defect again, one generation removed. Scoped
  /// to the fetch, a departure can only ever speak for the generation it joined.
  private struct Fetch {
    let id: Int
    let task: Task<FetchResult, Never>
    /// A `Set` is what makes "this reader has left" idempotent: the cancellation handler and the
    /// normal return can both fire for one call, and only the first of them may count.
    var readers: Set<Int>
    /// The list fetch this fetch was started for. A reader of a DIFFERENT one still waits on it
    /// (one fetch per key at a time) but does not take its answer as its own — see `read`.
    let listFetchedAt: Date?
  }
  private var inFlight: [String: Fetch] = [:]
  private var nextFetchID = 0
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
  /// `listFetchedAt` is when the caller's folder list was last fetched (`QueueStore.
  /// lastFetchedAt`). A cached cover checked against a different list fetch is re-checked once:
  /// the limit-1 page is read again and the proxy is fetched only when the hero image or its
  /// identity token changed (IMGMGR-622). nil is a stamp like any other: a caller that only ever
  /// passes nil never re-checks, and nil after a non-nil stamp re-checks once and stores nil.
  ///
  /// A SwiftUI `.task(id:)` per visible card is what gives this "cancellation on scroll-away",
  /// and cancellation still means what it always did — `runFetch` re-checks it after the
  /// concurrency gate and again before the proxy step, so a fetch nobody is waiting for occupies
  /// no slot and never starts its second network call. What changed is only WHOSE cancellation
  /// decides: the fetch belongs to every reader of its key, so it is abandoned when its LAST
  /// reader leaves, never when one of several does. A reader leaving on its own returns
  /// `.failure` for itself and takes nothing away from the readers that remain.
  ///
  /// A fetch abandoned by its last reader leaves no in-flight entry behind, so the next reader of
  /// that key starts a clean one, and once the fetch OBSERVES the cancellation it releases its
  /// concurrency slot and skips every remaining network step. That is not an airtight fence:
  /// cancellation reaches the shared task through an actor hop, so a proxy response that resumes
  /// before the hop lands is still written to the cache. Harmless, and deliberately not raced
  /// after — those bytes are this key's own image, so the worst case is a cache entry nobody
  /// asked for rather than a wrong answer.
  func hero(folderID: Int, sourceTier: GridSourceTier?, listFetchedAt: Date? = nil) async
    -> FetchResult
  {
    await read(
      key: cacheKey(folderID: folderID, sourceTier: sourceTier), folderID: folderID,
      sourceTier: sourceTier, listFetchedAt: listFetchedAt, alreadyAwaited: nil)
  }

  /// `hero`'s body. `alreadyAwaited` is the generation this reader already waited on for a
  /// DIFFERENT list fetch: that fetch has completed, so it is never joined again — the reader
  /// starts its own re-check instead, even while the finished fetch's initiator has yet to clear
  /// its entry.
  private func read(
    key: String, folderID: Int, sourceTier: GridSourceTier?, listFetchedAt: Date?,
    alreadyAwaited: Int?
  ) async -> FetchResult {
    if let cached = cache[key], cached.checkedAgainst == listFetchedAt {
      return .image(cached.data)
    }
    guard !Task.isCancelled else { return .failure }

    nextReaderToken &+= 1
    let token = nextReaderToken
    let generation: Int
    let task: Task<FetchResult, Never>
    let isInitiator: Bool
    let fetchStamp: Date?
    if var existing = inFlight[key], existing.id != alreadyAwaited {
      existing.readers.insert(token)
      inFlight[key] = existing
      generation = existing.id
      task = existing.task
      isInitiator = false
      fetchStamp = existing.listFetchedAt
    } else {
      nextFetchID &+= 1
      generation = nextFetchID
      // `Task {}` inherits this actor's isolation, but NOT the caller's cancellation — a reader
      // that goes away must not cancel a fetch its neighbour is still waiting on. Who DOES
      // cancel it is `readerLeft`, once this generation has nobody left.
      task = Task {
        await self.runFetch(
          key: key, folderID: folderID, sourceTier: sourceTier, listFetchedAt: listFetchedAt)
      }
      inFlight[key] = Fetch(
        id: generation, task: task, readers: [token], listFetchedAt: listFetchedAt)
      isInitiator = true
      fetchStamp = listFetchedAt
    }

    // `await task.value` does NOT return when the CALLER is cancelled — the shared task is not
    // this task — so the departure has to be observed through the handler rather than after it.
    let result = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      // Nonisolated by contract, so the bookkeeping hops back onto the actor.
      Task { await self.readerLeft(key, generation: generation, token: token, cancelled: true) }
    }

    readerLeft(key, generation: generation, token: token, cancelled: false)
    // Cleared by the INITIATOR, on every outcome — bytes, `.empty` or `.failure` — and only while
    // the entry is still THIS generation: a cancelled key can already have been cleared and
    // re-started by a later reader, and clearing that one would hand it a duplicate fetch.
    if isInitiator, inFlight[key]?.id == generation { inFlight[key] = nil }
    if Task.isCancelled { return .failure }
    // A fetch started for a DIFFERENT list fetch (in practice an older one) may have read the
    // identity before the server changed it: its answer is not this reader's, so it looks again
    // and finds a cache entry checked against THIS stamp, or makes its own re-check.
    guard fetchStamp == listFetchedAt else {
      return await read(
        key: key, folderID: folderID, sourceTier: sourceTier, listFetchedAt: listFetchedAt,
        alreadyAwaited: generation)
    }
    return result
  }

  /// One reader stops waiting on the generation it joined. A departure that names a generation
  /// which has since completed or been replaced is a no-op — it speaks for nobody.
  private func readerLeft(_ key: String, generation: Int, token: Int, cancelled: Bool) {
    guard var current = inFlight[key], current.id == generation else { return }
    guard current.readers.remove(token) != nil else { return }
    guard current.readers.isEmpty else {
      inFlight[key] = current
      return
    }
    guard cancelled else {
      inFlight[key] = current
      return
    }
    // The LAST reader of THIS fetch left through cancellation: there is nobody to hand bytes to,
    // so it must stop taking a concurrency slot and must not run its network steps. Dropping the
    // entry with it is what lets the next reader of the key start a fresh fetch — the cancelled
    // one caches nothing.
    current.task.cancel()
    inFlight[key] = nil
  }

  /// The two-step fetch itself, run by exactly one task per key. It holds the concurrency slot
  /// for its whole duration, as the inline version did, and re-checks cancellation at the same
  /// two boundaries the inline version did — here that means "every reader has gone".
  private func runFetch(
    key: String, folderID: Int, sourceTier: GridSourceTier?, listFetchedAt: Date?
  ) async -> FetchResult {
    await acquire()
    defer { release() }
    guard !Task.isCancelled else { return .failure }
    do {
      var query = GridImagesQuery(folderID: folderID)
      query.sourceTier = sourceTier
      let page = try await service.images(query, cursor: nil, limit: 1)
      guard let first = page.items.first else {
        // The same fence as the `.ok` write: an abandoned fetch must not clear what a newer one
        // stored.
        guard !Task.isCancelled else { return .failure }
        cache[key] = nil
        return .empty
      }
      guard !Task.isCancelled else { return .failure }
      let token = ProxyIdentity.token(
        from: first.proxies.additionalProperties[ProxyTier.grid.rawValue]?.url)
      // The same image under the same token is the same bytes: the re-check costs the limit-1
      // page and nothing more (IMGMGR-622 AC3).
      if var cached = cache[key], cached.imageID == first.id, cached.token == token {
        cached.checkedAgainst = listFetchedAt
        cache[key] = cached
        return .image(cached.data)
      }
      switch try await service.proxy(imageID: first.id, tier: .grid, v: token) {
      case .ok(let data):
        // The third boundary. It NARROWS the window rather than closing it: the last reader can
        // leave during the proxy await, and this is the cheapest place to notice — but the
        // cancellation arrives through an actor hop, so a response that resumes before the hop
        // lands is cached anyway. Harmless (see `hero`), and not worth racing.
        guard !Task.isCancelled else { return .failure }
        cache[key] = Entry(
          data: data, imageID: first.id, token: token, checkedAgainst: listFetchedAt)
        return .image(data)
      case .notModified:
        return cache[key].map { .image($0.data) } ?? .empty
      case .notFound:
        guard !Task.isCancelled else { return .failure }
        cache[key] = nil
        return .empty
      }
    } catch {
      // A re-check that cannot reach the server keeps the cover it has rather than blanking a
      // row that was showing one, and leaves the entry unchecked so the next reader tries again.
      return cache[key].map { .image($0.data) } ?? .failure
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

#if DEBUG
  /// Test-only observability, never compiled into a Release build — the same posture
  /// `DebugStubTransport` has.
  ///
  /// WHY it exists: a "cancelled while queued at the gate" test has to cancel AFTER the reader
  /// has really registered and its fetch is really parked in `acquire()`. A fixed sleep there is
  /// what lets the cancellation land before `hero`'s own preflight guard instead, where even an
  /// unfixed loader returns `.failure` with no network — a RED that proves nothing. These two
  /// reads are what the tests wait on instead of a delay.
  extension HeroThumbnailLoader {
    func debugIsFetching(folderID: Int, sourceTier: GridSourceTier?) -> Bool {
      inFlight[cacheKey(folderID: folderID, sourceTier: sourceTier)] != nil
    }

    /// How many fetches are parked in `acquire()` waiting for a slot.
    func debugGateWaiterCount() -> Int { waiters.count }

    /// How many live readers the key's CURRENT fetch has, and 0 when there is no fetch. What a
    /// test waits on to know a second reader has really joined the same fetch — the entry's mere
    /// existence was already true before that reader arrived.
    func debugReaderCount(folderID: Int, sourceTier: GridSourceTier?) -> Int {
      inFlight[cacheKey(folderID: folderID, sourceTier: sourceTier)]?.readers.count ?? 0
    }
  }
#endif
