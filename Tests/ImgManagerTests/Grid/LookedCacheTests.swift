import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-544: the looked cache — bytes keyed by `X-Look-Version`, reused only when a response in
/// the CURRENT epoch named them for that exact request, bounded, and never fed by a response that
/// spanned a reload.
@Suite("Looked cache (IMGMGR-544)")
@MainActor
struct LookedCacheTests {
  static let versionA = String(repeating: "a", count: 32)
  static let versionB = String(repeating: "b", count: 32)
  static let bytesA = Data([0xFF, 0xD8, 0xFF, 0xD9, 0x0A])
  static let bytesB = Data([0xFF, 0xD8, 0xFF, 0xD9, 0x0B])

  static func key(
    imageID: Int = 1, token: String? = "tok", lookID: String = "warm-film", strength: Int = 100
  ) -> LookedRequestKey {
    LookedRequestKey(
      proxy: ProxyLocalIdentity(imageID: imageID, tier: .grid, token: token),
      lookID: lookID, strength: strength)
  }

  static func tileKey(_ store: GridStore, token: String? = "tok") -> TileRenderKey {
    TileRenderKey(
      proxy: ProxyLocalIdentity(imageID: 1, tier: .grid, token: token), lookID: "warm-film",
      strength: 100, lookEpoch: store.lookEpoch)
  }

  // MARK: - The cache itself

  @Test("A version is exactly 32 lower-case hex digits")
  func versionShape() {
    #expect(LookedCache.isVersion(Self.versionA))
    #expect(!LookedCache.isVersion(nil))
    #expect(!LookedCache.isVersion(""))
    #expect(!LookedCache.isVersion(String(repeating: "a", count: 31)))
    #expect(!LookedCache.isVersion(String(repeating: "A", count: 32)))
    #expect(!LookedCache.isVersion(String(repeating: "g", count: 32)))
  }

  @Test("Bytes recorded in an epoch are reused in that epoch only")
  func reusedInItsEpochOnly() {
    var cache = LookedCache()
    cache.record(
      Self.key(), version: Self.versionA, data: Self.bytesA, issuingEpoch: 3, currentEpoch: 3)
    #expect(cache.fresh(Self.key(), epoch: 3) == Self.bytesA)
    #expect(cache.fresh(Self.key(), epoch: 4) == nil)
    #expect(cache.fresh(Self.key(strength: 120), epoch: 3) == nil)
    #expect(cache.fresh(Self.key(token: "other"), epoch: 3) == nil)
  }

  @Test("A missing or malformed X-Look-Version is not cached")
  func missingHeaderIsNotCached() {
    var cache = LookedCache()
    for version in [nil, "", "not-a-version", String(repeating: "F", count: 32)] {
      cache.record(
        Self.key(), version: version, data: Self.bytesA, issuingEpoch: 1, currentEpoch: 1)
    }
    #expect(cache.versions.isEmpty)
    #expect(cache.heldVersions.isEmpty)
    #expect(cache.totalBytes == 0)
  }

  @Test("A1: a response whose issuing epoch is not the current one writes nothing")
  func staleIssuingEpochWritesNothing() {
    var cache = LookedCache()
    cache.record(
      Self.key(), version: Self.versionA, data: Self.bytesA, issuingEpoch: 1, currentEpoch: 2)
    #expect(cache.versions.isEmpty)
    #expect(cache.fresh(Self.key(), epoch: 2) == nil)
  }

  @Test("A3: versions of an older epoch are pruned on insert")
  func olderEpochVersionsArePruned() {
    var cache = LookedCache()
    cache.record(
      Self.key(imageID: 1), version: Self.versionA, data: Self.bytesA, issuingEpoch: 1,
      currentEpoch: 1)
    cache.record(
      Self.key(imageID: 2), version: Self.versionB, data: Self.bytesB, issuingEpoch: 2,
      currentEpoch: 2)
    #expect(Set(cache.versions.keys) == [Self.key(imageID: 2)])
  }

  @Test("A new epoch naming the same version reuses that entry")
  func newEpochSameVersionReusesEntry() {
    var cache = LookedCache()
    cache.record(
      Self.key(), version: Self.versionA, data: Self.bytesA, issuingEpoch: 1, currentEpoch: 1)
    #expect(cache.fresh(Self.key(), epoch: 2) == nil)
    cache.record(
      Self.key(), version: Self.versionA, data: Self.bytesA, issuingEpoch: 2, currentEpoch: 2)
    #expect(cache.heldVersions == [Self.versionA])
    #expect(cache.totalBytes == Self.bytesA.count)
    #expect(cache.fresh(Self.key(), epoch: 2) == Self.bytesA)
  }

  @Test("Over budget the least recently used bytes go, and their versions with them")
  func evictsLeastRecentlyUsedOverBudget() {
    var cache = LookedCache(budget: 10)
    let versionC = String(repeating: "c", count: 32)
    cache.record(
      Self.key(imageID: 1), version: Self.versionA, data: Self.bytesA, issuingEpoch: 1,
      currentEpoch: 1)
    cache.record(
      Self.key(imageID: 2), version: Self.versionB, data: Self.bytesB, issuingEpoch: 1,
      currentEpoch: 1)
    // A is touched, so B is now the least recently used.
    #expect(cache.fresh(Self.key(imageID: 1), epoch: 1) == Self.bytesA)
    cache.record(
      Self.key(imageID: 3), version: versionC, data: Data([1, 2, 3, 4, 5]), issuingEpoch: 1,
      currentEpoch: 1)
    #expect(cache.heldVersions == [Self.versionA, versionC])
    #expect(cache.totalBytes == 10)
    #expect(cache.fresh(Self.key(imageID: 2), epoch: 1) == nil)
    #expect(cache.versions[Self.key(imageID: 2)] == nil)
  }

  // MARK: - Through the store

  @Test("A second load of the same tile in the same epoch makes no request")
  func sameEpochReusesBytes() async {
    let (store, transport) = await LookPersistenceTests.store()
    await transport.setLookedProxyVersion(Self.versionA)
    let first = await store.tileImage(Self.tileKey(store)) { $0 }
    let second = await store.tileImage(Self.tileKey(store)) { $0 }
    #expect(first.rendering == .looked(lookID: "warm-film"))
    #expect(second.rendering == .looked(lookID: "warm-film"))
    #expect(second.image == LookFixtures.lookedBytes)
    #expect(await transport.recordedLookedProxyRequests.count == 1)
  }

  @Test("Same proxy identity, a reload, a new server version: the new bytes are painted")
  func newEpochSameProxyNewVersion() async {
    let (store, transport) = await LookPersistenceTests.store()
    await transport.setLookedProxyVersion(Self.versionA)
    await transport.setLookedProxyOutcome(.ok(Self.bytesA))
    _ = await store.tileImage(Self.tileKey(store)) { $0 }
    let epoch = store.lookEpoch
    _ = await store.authoritativeRefresh()
    #expect(store.lookEpoch != epoch)
    // The render profile switched server-side: same proxy, new looked bytes.
    await transport.setLookedProxyVersion(Self.versionB)
    await transport.setLookedProxyOutcome(.ok(Self.bytesB))
    let after = await store.tileImage(Self.tileKey(store)) { $0 }
    #expect(after.image == Self.bytesB)
    #expect(await transport.recordedLookedProxyRequests.count == 2)
    let again = await store.tileImage(Self.tileKey(store)) { $0 }
    #expect(again.image == Self.bytesB)
    #expect(await transport.recordedLookedProxyRequests.count == 2)
  }

  @Test("A1: a looked response suspended across a reload is painted but not cached")
  func responseSpanningAReloadIsNotCached() async {
    let (store, transport) = await LookPersistenceTests.store()
    await transport.setLookedProxyVersion(Self.versionA)
    await transport.holdLookedProxyRequests(true)
    let key = Self.tileKey(store)
    let pending = Task { await store.tileImage(key) { $0 }.rendering }
    await transport.waitUntilLookedProxyStarted()
    await transport.holdLookedProxyRequests(false)
    _ = await store.authoritativeRefresh()
    await transport.releaseLookedProxy()
    let rendering = await pending.value
    #expect(rendering == .looked(lookID: "warm-film"))
    #expect(store.lookedCache.versions.isEmpty)
    _ = await store.tileImage(Self.tileKey(store)) { $0 }
    #expect(await transport.recordedLookedProxyRequests.count == 2)
  }

  @Test("No X-Look-Version: every load asks again")
  func missingHeaderAsksAgain() async {
    let (store, transport) = await LookPersistenceTests.store()
    await transport.setLookedProxyVersion(nil)
    _ = await store.tileImage(Self.tileKey(store)) { $0 }
    _ = await store.tileImage(Self.tileKey(store)) { $0 }
    #expect(await transport.recordedLookedProxyRequests.count == 2)
    #expect(store.lookedCache.versions.isEmpty)
  }

  @Test("The unlooked proxy token is never sent as a looked v")
  func proxyTokenIsNeverSentAsV() async {
    let (store, transport) = await LookPersistenceTests.store()
    await transport.setLookedProxyVersion(Self.versionA)
    _ = await store.tileImage(Self.tileKey(store, token: "proxytoken123")) { $0 }
    let paths = await transport.recordedLookedProxyRequests
    #expect(paths.count == 1)
    #expect(paths.allSatisfy { !$0.contains("v=") && !$0.contains("proxytoken123") })
  }

  @Test("Draft renders (the strip open) bypass the cache")
  func draftRendersBypassTheCache() async {
    let (store, transport) = await LookPersistenceTests.store()
    await transport.setLookedProxyVersion(Self.versionA)
    store.toggleLooksStrip()
    store.looks.select("warm-film")
    _ = await store.loupePreview(imageID: 1, identityToken: nil) { $0 }
    _ = await store.loupePreview(imageID: 1, identityToken: nil) { $0 }
    #expect(await transport.recordedLookedProxyRequests.count == 2)
    #expect(store.lookedCache.versions.isEmpty)
  }
}
