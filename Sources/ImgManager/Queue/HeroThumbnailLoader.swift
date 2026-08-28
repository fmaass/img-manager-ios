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
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(service: GridService, maxConcurrent: Int = 4) {
    self.service = service
    self.maxConcurrent = maxConcurrent
  }

  /// One card's hero fetch, cached per (folderID, sourceTier) for the loader's lifetime. A
  /// SwiftUI `.task(id:)` per visible card is what gives this "cancellation on scroll-away" —
  /// this method additionally checks `Task.isCancelled` at both await boundaries so a scrolled-
  /// away card's fetch never starts its SECOND network step (the proxy fetch) once the caller's
  /// task has already been cancelled, and never occupies a concurrency slot pointlessly.
  func hero(folderID: Int, sourceTier: GridSourceTier?) async -> FetchResult {
    let key = cacheKey(folderID: folderID, sourceTier: sourceTier)
    if let cached = cache[key] { return .image(cached) }
    guard !Task.isCancelled else { return .failure }
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
