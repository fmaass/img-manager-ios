import ImgManagerAPI
import Testing

@testable import ImgManager

/// R3-15 (IMGMGR-539): a grid tile's load key is the proxy's LOCAL identity — image, tier, token
/// and reported dimensions. The shipped key was `"\(id)|\(tier)"`, equal for every case below
/// that must reload, so an adopted 400 -> 800 row kept its 400-px bytes.
@Suite("Tile load key — local proxy identity (R3-15)")
@MainActor
struct TileLoadKeyTests {

  static let tokenA = "/api/images/1/proxy/grid?v=aaa"
  static let tokenB = "/api/images/1/proxy/grid?v=bbb"

  /// Image 1 with one `ok` grid proxy entry.
  static func image(url: String?, width: Int?, height: Int?) -> Components.Schemas.ImageSummary {
    var image = LoupeZoomFixtures.image(id: 1)
    let state = Components.Schemas.ProxyState(height: height, url: url, verdict: .ok, width: width)
    image.proxies = .init(additionalProperties: ["grid": state])
    return image
  }

  @Test("A new token on the same image and tier is a different key")
  func tokenChangeIsNewKey() {
    let before = Self.image(url: Self.tokenA, width: 600, height: 400)
    let after = Self.image(url: Self.tokenB, width: 600, height: 400)
    let old = TileLoadKey.make(image: before, tier: .grid)
    let new = TileLoadKey.make(image: after, tier: .grid)
    #expect(old.token == "aaa")
    #expect(new.token == "bbb")
    #expect(old != new)
  }

  @Test(
    "New dimensions under the same token, or under no token, are a different key",
    arguments: ["/api/images/1/proxy/grid?v=aaa", nil] as [String?])
  func dimensionChangeIsNewKey(url: String?) {
    let before = Self.image(url: url, width: 600, height: 400)
    let after = Self.image(url: url, width: 1200, height: 800)
    let old = TileLoadKey.make(image: before, tier: .grid)
    let new = TileLoadKey.make(image: after, tier: .grid)
    #expect(old.token == new.token)
    #expect(old != new)
  }

  @Test("The same proxy state gives an equal key; the tier is part of it")
  func identicalIsEqual() {
    let image = Self.image(url: Self.tokenA, width: 600, height: 400)
    let grid = TileLoadKey.make(image: image, tier: .grid)
    #expect(grid == TileLoadKey.make(image: image, tier: .grid))
    let expected = ProxyLocalIdentity(
      imageID: 1, tier: .grid, token: "aaa", width: 600, height: 400)
    #expect(grid == expected)
    // No entry at a tier reads as no token and no dimensions — the legacy token-only key.
    let preview = TileLoadKey.make(image: image, tier: .preview)
    #expect(preview != grid)
    #expect(preview == ProxyLocalIdentity(imageID: 1, tier: .preview, token: nil))
  }
}
