import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// R3-15 (IMGMGR-539), store-level regression through the real `GridStore` + `GridService` over
/// the recording transport: the in-memory proxy cache is keyed by the LOCAL identity, so a
/// dimension change fetches fresh bytes even when the token is unchanged or nil. Against the
/// shipped token-only key, step 3 returned the warm 400-px bytes with no second request.
@Suite("Proxy cache identity — dimensions are part of the local key (R3-15)")
@MainActor
struct ProxyCacheIdentityTests {

  static let bytesA = Data([0xFF, 0xD8, 0xFF, 0xD9, 0x0A])
  static let bytesB = Data([0xFF, 0xD8, 0xFF, 0xD9, 0x0B])
  static let proxyGet = Operations.GetProxyApiImagesImageIdProxyTierGet.id

  @Test(
    "A dimension change under the same token, or under no token, refetches; a repeat does not",
    arguments: ["t", nil] as [String?])
  func dimensionChangeFetchesFresh(token: String?) async {
    let (store, transport) = LoupeZoomFixtures.makeStore()
    let small = ProxyLocalIdentity(imageID: 1, tier: .grid, token: token, width: 400, height: 267)
    let large = ProxyLocalIdentity(imageID: 1, tier: .grid, token: token, width: 800, height: 533)

    // 1. Warm.
    await transport.setProxyOutcome(.ok(Self.bytesA))
    #expect(await store.proxyData(identity: small) == Self.bytesA)
    #expect(await transport.callCount(Self.proxyGet) == 1)

    // 2. The same identity is served from the cache.
    #expect(await store.proxyData(identity: small) == Self.bytesA)
    #expect(await transport.callCount(Self.proxyGet) == 1)

    // 3. New dimensions, same token: fresh bytes from the server.
    await transport.setProxyOutcome(.ok(Self.bytesB))
    #expect(await store.proxyData(identity: large) == Self.bytesB)
    #expect(await transport.callCount(Self.proxyGet) == 2)
  }

  @Test("The token-only callers (no dimensions) keep reusing their own entry, as before")
  func legacyCallersReuseTheirEntry() async {
    let (store, transport) = LoupeZoomFixtures.makeStore()
    await transport.setProxyOutcome(.ok(Self.bytesA))
    #expect(await store.proxyData(imageID: 1, tier: .grid, identityToken: "t") == Self.bytesA)
    await transport.setProxyOutcome(.ok(Self.bytesB))
    #expect(await store.proxyData(imageID: 1, tier: .grid, identityToken: "t") == Self.bytesA)
    #expect(await transport.callCount(Self.proxyGet) == 1)
    // The legacy entry IS the dimensionless identity — one cache, one key shape.
    let legacy = ProxyLocalIdentity(imageID: 1, tier: .grid, token: "t")
    #expect(await store.proxyData(identity: legacy) == Self.bytesA)
    #expect(await transport.callCount(Self.proxyGet) == 1)
  }
}
