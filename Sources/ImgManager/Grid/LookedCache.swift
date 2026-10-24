import Foundation

/// One looked render a caller asks for (IMGMGR-544): the unlooked proxy it is rendered from (its
/// local identity: image, tier, token, reported dimensions), the look and the strength. Only the
/// look id and the strength are SENT; the proxy identity stays local, so a refreshed summary is a
/// different request even though the looked URL is the same.
struct LookedRequestKey: Hashable, Sendable {
  var proxy: ProxyLocalIdentity
  var lookID: String
  var strength: Int
}

/// The client's only cache of looked bytes (IMGMGR-544). The server answers every looked render
/// `no-store` (`v` is never sent), so URLSession never answers one; this cache does, and only
/// under two rules.
///
/// - Bytes are keyed by the response's `X-Look-Version` (`v`) ONLY. The unlooked proxy token is
///   never a looked version.
/// - FRESHNESS: bytes are reused for a request only when a response IN THE CURRENT EPOCH named
///   that `v` for that exact request. The epoch is `GridStore.loadGeneration`, which moves on
///   every first-page reload, the moment a render-profile switch would be re-read. A response
///   whose ISSUING epoch is not the current one writes nothing, and every `versions` entry of an
///   older epoch is pruned on insert, so the metadata is bounded too.
///
/// Bounded at `byteBudget` bytes, least recently used evicted first; a `versions` entry whose
/// bytes were evicted is dropped with them. Draft renders (the strip open) never come here.
struct LookedCache {
  struct Version: Equatable, Sendable {
    var v: String
    var epoch: Int
  }

  static let byteBudget = 48 * 1024 * 1024

  let budget: Int
  private(set) var versions: [LookedRequestKey: Version] = [:]
  private var bytes: [String: Data] = [:]
  /// Least recently used first.
  private var order: [String] = []
  private(set) var totalBytes = 0

  init(budget: Int = LookedCache.byteBudget) {
    self.budget = budget
  }

  /// The versions whose bytes are held, least recently used first.
  var heldVersions: [String] { order }

  /// A server looked version: exactly 32 lower-case hex digits. Anything else is not cached.
  static func isVersion(_ value: String?) -> Bool {
    guard let value, value.count == 32 else { return false }
    return value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }

  /// The bytes a response in `epoch` named for `key`, or nil (then the request is made). A hit
  /// becomes the most recently used entry.
  mutating func fresh(_ key: LookedRequestKey, epoch: Int) -> Data? {
    guard let version = versions[key], version.epoch == epoch,
      let data = bytes[version.v]
    else { return nil }
    touch(version.v)
    return data
  }

  /// Records one looked response. `issuingEpoch` is the epoch captured BEFORE the request was
  /// awaited; when it is no longer `currentEpoch` the response spanned a reload and writes
  /// nothing. A missing or malformed `version` is not cached either. A `version` already held
  /// reuses that entry.
  mutating func record(
    _ key: LookedRequestKey, version: String?, data: Data, issuingEpoch: Int, currentEpoch: Int
  ) {
    guard issuingEpoch == currentEpoch, let version, Self.isVersion(version) else { return }
    guard data.count <= budget else { return }
    versions = versions.filter { $0.value.epoch == currentEpoch }
    versions[key] = Version(v: version, epoch: currentEpoch)
    if let held = bytes[version] {
      totalBytes -= held.count
    }
    bytes[version] = data
    totalBytes += data.count
    touch(version)
    evict(keeping: version)
  }

  private mutating func touch(_ version: String) {
    order.removeAll { $0 == version }
    order.append(version)
  }

  private mutating func evict(keeping newest: String) {
    var evicted: Set<String> = []
    while totalBytes > budget, let oldest = order.first, oldest != newest {
      order.removeFirst()
      if let data = bytes.removeValue(forKey: oldest) { totalBytes -= data.count }
      evicted.insert(oldest)
    }
    guard !evicted.isEmpty else { return }
    versions = versions.filter { !evicted.contains($0.value.v) }
  }
}
