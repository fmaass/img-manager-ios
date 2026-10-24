import Foundation
import ImgManagerAPI
import Testing
import UIKit

@testable import ImgManager

/// IMGMGR-544 AC1: the look glyph follows the tile's PAINTED rendering, never shows together with
/// the edit pencil whatever the overlays, and the two-badge cap is applied by one function.
@Suite("Tile look glyph (IMGMGR-544)")
@MainActor
struct TileLookGlyphTests {
  private static let allOn = TileOverlaySet(
    marks: true, edited: true, lightroomRating: true, sourceKind: true, filename: true)
  private static let allOff = TileOverlaySet(
    marks: false, edited: false, lightroomRating: false, sourceKind: false, filename: false)

  @Test(
    "AC1: the eligible list never holds both the pencil and the look glyph",
    arguments: [true, false, nil] as [Bool?], [true, false])
  func glyphNeverWithThePencil(hasEdit: Bool?, rendersLook: Bool) {
    for overlays in [Self.allOn, Self.allOff] {
      for pick in [true, false] {
        for selected in [true, false] {
          let items = TileBadgeItem.items(
            changedElsewhere: false, selected: selected, mark: pick ? .pick : nil,
            hasEdit: hasEdit, rendersLook: rendersLook, rating: 3, sourceKind: "raw_embedded",
            overlays: overlays)
          #expect(!(items.contains(.edited) && items.contains(.look)))
          // Eligible iff the tile painted a look and the photograph has no edit — no overlay
          // gates it.
          #expect(items.contains(.look) == (rendersLook && hasEdit != true))
          #expect(TileBadgeItem.drawn(items).count <= TileBadgeItem.cap)
        }
      }
    }
  }

  @Test("Eligible versus drawn: the cap keeps the first two in priority order")
  func eligibleVersusDrawn() {
    let selectedPickLook = TileBadgeItem.items(
      changedElsewhere: false, selected: true, mark: .pick, hasEdit: false, rendersLook: true,
      rating: nil, sourceKind: nil, overlays: Self.allOn)
    #expect(selectedPickLook == [.selected, .pick, .look])
    #expect(TileBadgeItem.drawn(selectedPickLook) == [.selected, .pick])
    let pickLook = TileBadgeItem.items(
      changedElsewhere: false, selected: false, mark: .pick, hasEdit: false, rendersLook: true,
      rating: 4, sourceKind: "raw_embedded", overlays: Self.allOn)
    #expect(pickLook == [.pick, .look, .lightroomRating, .sourceKind])
    #expect(TileBadgeItem.drawn(pickLook) == [.pick, .look])
    #expect(TileBadgeItem.drawn([]) == [])
    #expect(TileBadgeItem.drawn([.look]) == [.look])
  }

  @Test("An edited photograph's tile never renders a look, saved or drafted")
  func editedPhotoNeverRendersALook() async throws {
    let saved = LookPersistenceTests.savedLook("warm-film", 120)
    let (store, transport) = await LookPersistenceTests.store(saved: saved, hasEdit: true)
    #expect(LookPersistence.savedRender(look: saved, hasEdit: true) == nil)
    // A draft on the edited photograph previews in the loupe only.
    store.toggleLooksStrip()
    store.looks.select("cool-matte")
    let image = try #require(store.actionableImages.first { $0.id == 1 })
    let key = store.tileRenderKey(image: image, tier: .grid)
    #expect(key.lookID == nil && key.strength == nil && key.lookEpoch == nil)
    let render = await store.tileImage(key) { $0 }
    #expect(render.rendering == .unlooked)
    #expect(await transport.recordedLookedProxyRequests.isEmpty)
  }

  @Test("A saved look on an unedited photograph keys the tile with its look and epoch")
  func savedLookKeysTheTile() async throws {
    let saved = LookPersistenceTests.savedLook("warm-film", 120)
    let (store, _) = await LookPersistenceTests.store(saved: saved)
    let image = try #require(store.actionableImages.first { $0.id == 1 })
    let key = store.tileRenderKey(image: image, tier: .grid)
    #expect(key.lookID == "warm-film")
    #expect(key.strength == 120)
    #expect(key.lookEpoch == store.lookEpoch)
    let plain = try #require(store.actionableImages.first { $0.id == 2 })
    #expect(store.tileRenderKey(image: plain, tier: .grid).lookID == nil)
  }

  @Test("A looked render shows the glyph")
  func lookedRenderShowsGlyph() async {
    let (store, _) = await LookPersistenceTests.store()
    let render = await store.tileImage(LookedCacheTests.tileKey(store)) { $0 }
    #expect(render.rendering == .looked(lookID: "warm-film"))
    #expect(render.image == LookFixtures.lookedBytes)
    #expect(TileBadgeItem.isLooked(render.rendering))
  }

  @Test(
    "A refused, missing or unreachable looked render falls back unlooked and shows no glyph",
    arguments: [0, 1, 2])
  func refusedLookedRenderShowsNoGlyph(failure: Int) async {
    let (store, transport) = await LookPersistenceTests.store()
    switch failure {
    case 0: await transport.setLookedProxyOutcome(.refused(code: "unknown_look"))
    case 1: await transport.setLookedProxyOutcome(.notFound)
    default: await transport.setLookedProxyShouldFail(true)
    }
    let render = await store.tileImage(LookedCacheTests.tileKey(store)) { $0 }
    #expect(render.rendering == .fallback(lookID: "warm-film"))
    #expect(render.image == LookFixtures.unlookedBytes)
    #expect(!TileBadgeItem.isLooked(render.rendering))
    #expect(store.lookedCache.versions.isEmpty)
  }

  @Test("A corrupt looked 200 falls back through the real decoder and is not cached")
  func corruptLooked200ShowsNoGlyph() async throws {
    let (store, transport) = await LookPersistenceTests.store()
    let validJPEG = try #require(Data(base64Encoded: LookFixtures.tinyJPEGBase64))
    await transport.setProxyOutcome(.ok(validJPEG))
    await transport.setLookedProxyOutcome(.ok(Data("not a jpeg".utf8)))
    await transport.setLookedProxyVersion(LookedCacheTests.versionA)
    let render = await store.tileImage(LookedCacheTests.tileKey(store)) { UIImage(data: $0) }
    #expect(render.rendering == .fallback(lookID: "warm-film"))
    #expect(render.image != nil)
    #expect(store.lookedCache.versions.isEmpty)
  }
}
