import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-382 fixtures: a loaded two-photograph shoot with the loupe open on the first, over the
/// test target's recording transport and a `UserDefaults` suite of its own.
@MainActor
enum LookFixtures {
  static let catalogue: [Components.Schemas.LookSummary] = [
    GridServiceContractProbeTests.look("warm-film", name: "Warm Film"),
    GridServiceContractProbeTests.look("cool-matte", name: "Cool Matte", category: "Creative"),
    GridServiceContractProbeTests.look("classic-mono", name: "Classic Mono", category: "Mono"),
  ]

  /// A valid 1x1 JPEG (the Debug stub's own fallback image), for the one test that runs the
  /// real decoder.
  static let tinyJPEGBase64 =
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAj/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCdABmX/9k="

  static let unlookedBytes = Data([0xFF, 0xD8, 0xFF, 0xD9, 0x01])
  static let lookedBytes = Data([0xFF, 0xD8, 0xFF, 0xD9, 0x02])

  static func loadedStore() async -> (GridStore, GridStubTransport, UserDefaults) {
    let transport = GridStubTransport()
    let defaults = makeEphemeralDefaults()
    let store = GridStore(
      service: GridService(client: ImgManagerAPIClient.make(transport: transport)),
      preferences: GridPreferences(defaults: defaults))
    let images = [LoupeZoomFixtures.image(id: 1), LoupeZoomFixtures.image(id: 2)]
    await transport.setListImagesPage(.init(items: images, limit: 100, nextCursor: nil))
    await transport.setLooksCatalogue(catalogue)
    await transport.setProxyOutcome(.ok(unlookedBytes))
    await transport.setLookedProxyOutcome(.ok(lookedBytes))
    await store.selectShoot(folderID: 1)
    store.openLoupe(on: 1)
    return (store, transport, defaults)
  }
}

@Suite("Look model (IMGMGR-382)")
@MainActor
struct LookModelTests {

  @Test("Default: no look, the control reads Off and is not offered before a catalogue")
  func defaultsToNone() async {
    let (store, _, _) = await LookFixtures.loadedStore()
    #expect(store.looks.draft == nil)
    #expect(store.looks.activeLook(for: 1) == nil)
    #expect(store.looks.isStripOpen(for: 1) == false)
    #expect(store.looks.canChoose == false)
    #expect(store.looks.catalogueState == .notLoaded)
    #expect(store.looks.accessibilityValue(focusedImageID: 1) == "Off")
  }

  @Test("Selection: a catalogued look, then None; an id outside the catalogue is refused")
  func selection() async {
    let (store, _, _) = await LookFixtures.loadedStore()
    store.looks.openStrip(imageID: 1)
    store.looks.select("warm-film")
    // Nothing to choose from before the catalogue: the strip does not open.
    #expect(store.looks.draft == nil)

    await store.looks.loadCatalogueIfNeeded()
    #expect(store.looks.catalogue.map(\.id) == ["warm-film", "cool-matte", "classic-mono"])
    #expect(store.looks.canChoose)
    store.looks.openStrip(imageID: 1)
    store.looks.select("cool-matte")
    #expect(store.looks.draft?.lookID == "cool-matte")
    #expect(store.looks.activeLook(for: 1) == .init(lookID: "cool-matte", strength: 100))
    #expect(store.looks.accessibilityValue(focusedImageID: 1) == "Cool Matte")

    store.looks.select("not-a-look")
    #expect(store.looks.draft?.lookID == "cool-matte")

    store.looks.select(nil)
    #expect(store.looks.draft?.lookID == nil)
    #expect(store.looks.isStripOpen(for: 1))  // None is a choice in the open strip
    #expect(store.looks.accessibilityValue(focusedImageID: 1) == "Off")
  }

  @Test("The catalogue is fetched once per session, however often the loupe opens")
  func catalogueLoadsOnce() async {
    let (store, transport, _) = await LookFixtures.loadedStore()
    await store.looks.loadCatalogueIfNeeded()
    await store.looks.loadCatalogueIfNeeded()
    store.closeLoupe()
    store.openLoupe(on: 2)
    await store.looks.loadCatalogueIfNeeded()
    #expect(await transport.callCount(Operations.ListLooksApiLooksGet.id) == 1)
    #expect(store.looks.catalogueState == .loaded)
  }

  @Test("Two opens racing the first fetch ask the server once")
  func concurrentLoadsAskOnce() async {
    let (store, transport, _) = await LookFixtures.loadedStore()
    async let first: Void = store.looks.loadCatalogueIfNeeded()
    async let second: Void = store.looks.loadCatalogueIfNeeded()
    _ = await (first, second)
    #expect(await transport.callCount(Operations.ListLooksApiLooksGet.id) == 1)
    #expect(store.looks.catalogue.count == 3)
  }

  @Test("A failed fetch leaves the catalogue empty and the control off; the next open retries")
  func failureIsEmptyThenRetries() async {
    let (store, transport, _) = await LookFixtures.loadedStore()
    await transport.setLooksShouldFail(true)
    await store.looks.loadCatalogueIfNeeded()
    #expect(store.looks.catalogue.isEmpty)
    #expect(store.looks.catalogueState == .failed)
    #expect(store.looks.canChoose == false)

    await store.looks.loadCatalogueIfNeeded()
    #expect(await transport.callCount(Operations.ListLooksApiLooksGet.id) == 2)
    #expect(store.looks.catalogue.count == 3)
    #expect(store.looks.catalogueState == .loaded)
  }

  @Test("IMGMGR-543: a look belongs to one photograph — moving on, closing or Compare cancels it")
  func aDraftEndsWithItsPhotograph() async {
    let (store, _, _) = await LookFixtures.loadedStore()
    await store.looks.loadCatalogueIfNeeded()
    store.looks.openStrip(imageID: 1)
    store.looks.select("warm-film")
    store.loupeFocus(on: 2)
    #expect(store.looks.draft == nil)
    #expect(store.looks.activeLook(for: 2) == nil)
    store.loupePrevious()
    #expect(store.focusedImageID == 1)
    #expect(store.looks.activeLook(for: 1) == nil)  // returning does not revive it

    store.looks.openStrip(imageID: 1)
    store.looks.select("warm-film")
    store.closeLoupe()
    #expect(store.looks.draft == nil)
    store.openLoupe(on: 1)
    #expect(store.looks.activeLook(for: 1) == nil)
  }

  @Test("Nothing about a CHOSEN look is written to UserDefaults — only favourite ids may be")
  func nothingPersisted() async {
    let (store, _, defaults) = await LookFixtures.loadedStore()
    let ownBefore = Set(defaults.dictionaryRepresentation().keys)
    let standardBefore = Set(UserDefaults.standard.dictionaryRepresentation().keys)

    await store.looks.loadCatalogueIfNeeded()
    store.looks.openStrip(imageID: 1)
    store.looks.select("classic-mono")
    store.looks.setStrength(140)
    _ = await store.loupePreviewBytes(imageID: 1, identityToken: nil)
    store.loupeFocus(on: 2)
    store.looks.select(nil)

    #expect(Set(defaults.dictionaryRepresentation().keys) == ownBefore)
    // Favourites are the one look-shaped key, and they hold ids only.
    store.looks.favourites.toggle("classic-mono")
    #expect(
      Set(defaults.dictionaryRepresentation().keys).subtracting(ownBefore)
        == [LookFavourites.key])
    #expect(defaults.stringArray(forKey: LookFavourites.key) == ["classic-mono"])
    let standardAfter = Set(UserDefaults.standard.dictionaryRepresentation().keys)
    let standardAdded = standardAfter.subtracting(standardBefore)
    #expect(standardAdded.filter { $0.lowercased().contains("look") }.isEmpty)
    #expect(GridPreferences.persistedKeys.allSatisfy { !$0.lowercased().contains("look") })
  }
}

extension GridStore {
  /// The loupe's loader with a pass-through decoder: the bytes themselves are the "image", so a
  /// test can say exactly which bytes the loupe would paint.
  func loupePreviewBytes(imageID: Int, identityToken: String?) async -> LoupePreview<Data> {
    await loupePreview(imageID: imageID, identityToken: identityToken, decode: { $0 })
  }
}

@Suite("Loupe looked loading (IMGMGR-382)")
@MainActor
struct LoupeLookedLoadingTests {

  private let proxyGet = Operations.GetProxyApiImagesImageIdProxyTierGet.id
  private let lookedGet = Operations.GetLookedProxyApiImagesImageIdProxyTierLookLookIdGet.id

  @Test("No look: the unlooked preview proxy alone, the looked operation never asked")
  func noLookTakesTheUnlookedPath() async {
    let (store, transport, _) = await LookFixtures.loadedStore()
    await store.looks.loadCatalogueIfNeeded()
    let preview = await store.loupePreviewBytes(imageID: 1, identityToken: "t1")
    #expect(preview.image == LookFixtures.unlookedBytes)
    #expect(preview.rendering == .unlooked)
    #expect(await transport.recordedProxyTiers == [ProxyTier.preview.rawValue])
    #expect(await transport.callCount(lookedGet) == 0)
  }

  @Test("A look: the looked proxy at the SAME preview tier, asked fresh every time (no-store)")
  func activeLookTakesTheLookedPath() async {
    let (store, transport, _) = await LookFixtures.loadedStore()
    await store.looks.loadCatalogueIfNeeded()
    store.looks.openStrip(imageID: 1)
    store.looks.select("warm-film")
    let preview = await store.loupePreviewBytes(imageID: 1, identityToken: "t1")
    #expect(preview.image == LookFixtures.lookedBytes)
    #expect(preview.rendering == .looked(lookID: "warm-film"))
    let paths = await transport.recordedLookedProxyRequests
    #expect(paths.count == 1)
    let path = paths.first.flatMap { URLComponents(string: $0)?.path } ?? ""
    #expect(path.hasSuffix("/api/images/1/proxy/preview/look/warm-film"))
    #expect(paths.first.map(LookStripTests.query) == [URLQueryItem(name: "strength", value: "100")])
    #expect(await transport.callCount(proxyGet) == 0)
    #expect(store.looks.accessibilityValue(focusedImageID: 1) == "Warm Film")

    // No looked cache: the same frame again is a second request on the wire.
    _ = await store.loupePreviewBytes(imageID: 1, identityToken: "t1")
    #expect(await transport.recordedLookedProxyRequests.count == 2)

    // Looked bytes never reach the unlooked cache: None shows the unlooked proxy.
    store.looks.select(nil)
    let unlooked = await store.loupePreviewBytes(imageID: 1, identityToken: "t1")
    #expect(unlooked.image == LookFixtures.unlookedBytes)
    #expect(unlooked.rendering == .unlooked)
  }

  @Test(
    "A failed looked render falls back to the unlooked proxy, keeps the look, and says so",
    arguments: [
      GridStubTransport.LookedProxyOutcome.notFound, .refused(code: "unknown_look"),
      .refused(code: "invalid_request"),
    ])
  func fallsBackToTheUnlookedProxy(outcome: GridStubTransport.LookedProxyOutcome) async {
    let (store, transport, _) = await LookFixtures.loadedStore()
    await store.looks.loadCatalogueIfNeeded()
    store.looks.openStrip(imageID: 1)
    store.looks.select("warm-film")
    await transport.setLookedProxyOutcome(outcome)

    let preview = await store.loupePreviewBytes(imageID: 1, identityToken: nil)
    #expect(preview.image == LookFixtures.unlookedBytes)  // never blank because of a look
    #expect(preview.rendering == .fallback(lookID: "warm-film"))
    // The unlooked request was made — it is the one that makes the server enqueue a proxy.
    #expect(await transport.recordedProxyTiers == [ProxyTier.preview.rawValue])
    #expect(store.looks.draft?.lookID == "warm-film")
    #expect(
      store.looks.accessibilityValue(focusedImageID: 1) == "Warm Film, unavailable for this photo")
    // Another photograph is not tarred with this one's failure.
    #expect(store.looks.accessibilityValue(focusedImageID: 2) == "Off")

    // A successful render of the same photograph clears it.
    await transport.setLookedProxyOutcome(.ok(LookFixtures.lookedBytes))
    let recovered = await store.loupePreviewBytes(imageID: 1, identityToken: nil)
    #expect(recovered.image == LookFixtures.lookedBytes)
    #expect(store.looks.accessibilityValue(focusedImageID: 1) == "Warm Film")
  }

  @Test("A transport failure on the looked render falls back the same way")
  func transportFailureFallsBack() async {
    let (store, transport, _) = await LookFixtures.loadedStore()
    await store.looks.loadCatalogueIfNeeded()
    // The draft belongs to the photograph rendered: photo 2, focused first.
    store.loupeFocus(on: 2)
    store.looks.openStrip(imageID: 2)
    store.looks.select("cool-matte")
    await transport.setLookedProxyShouldFail(true)
    let preview = await store.loupePreviewBytes(imageID: 2, identityToken: nil)
    #expect(preview.image == LookFixtures.unlookedBytes)
    #expect(preview.rendering == .fallback(lookID: "cool-matte"))
    #expect(
      store.looks.accessibilityValue(focusedImageID: 2) == "Cool Matte, unavailable for this photo")
  }

  @Test("A looked 200 whose bytes do not decode takes the same fallback, with the real decoder")
  func undecodableLookedBytesFallBack() async throws {
    let (store, transport, _) = await LookFixtures.loadedStore()
    let validJPEG = try #require(Data(base64Encoded: LookFixtures.tinyJPEGBase64))
    #expect(PlatformImage(data: validJPEG) != nil)  // positive control: the decoder works
    await transport.setProxyOutcome(.ok(validJPEG))
    await transport.setLookedProxyOutcome(.ok(Data("not an image".utf8)))
    await store.looks.loadCatalogueIfNeeded()
    store.looks.openStrip(imageID: 1)
    store.looks.select("warm-film")

    let preview = await store.loupePreview(
      imageID: 1, identityToken: nil, decode: { PlatformImage(data: $0) })
    #expect(preview.image != nil)  // the unlooked JPEG, never a blank loupe
    #expect(preview.rendering == .fallback(lookID: "warm-film"))
    #expect(await transport.callCount(lookedGet) == 1)
    #expect(await transport.callCount(proxyGet) == 1)
    #expect(
      store.looks.accessibilityValue(focusedImageID: 1) == "Warm Film, unavailable for this photo")
  }

  @Test("The fallback reaches the unlooked endpoint even when its bytes are already cached")
  func fallbackRequestsTheUnlookedProxyEvenWhenCached() async {
    let (store, transport, _) = await LookFixtures.loadedStore()
    await store.looks.loadCatalogueIfNeeded()
    // Unlooked bytes cached first, the way an earlier unlooked view of the frame leaves them.
    _ = await store.loupePreviewBytes(imageID: 1, identityToken: "t1")
    #expect(await transport.callCount(proxyGet) == 1)

    store.looks.openStrip(imageID: 1)
    store.looks.select("warm-film")
    await transport.setLookedProxyOutcome(.notFound)
    let preview = await store.loupePreviewBytes(imageID: 1, identityToken: "t1")
    // Shown at once from the cache...
    #expect(preview.image == LookFixtures.unlookedBytes)
    #expect(preview.rendering == .fallback(lookID: "warm-film"))
    // ...and the unlooked GET still goes out after the looked 404.
    await store.fallbackProxyRequest?.value
    let wire = await transport.recordedWire.map(\.operationID)
    let operations = wire.filter { $0 == proxyGet || $0 == lookedGet }
    #expect(operations == [proxyGet, lookedGet, proxyGet])
  }

  @Test("A render report for a look no longer active is dropped")
  func staleReportIsDropped() async {
    let (store, _, _) = await LookFixtures.loadedStore()
    await store.looks.loadCatalogueIfNeeded()
    store.looks.openStrip(imageID: 1)
    store.looks.select("warm-film")
    store.looks.recordRender(imageID: 1, lookID: "cool-matte", strength: 100, available: false)
    store.looks.recordRender(imageID: 1, lookID: "warm-film", strength: 120, available: false)
    #expect(store.looks.accessibilityValue(focusedImageID: 1) == "Warm Film")
  }

  @Test("The loupe image's label names what the painted bytes were rendered as")
  func imageLabelNamesTheRendering() async {
    let (store, _, _) = await LookFixtures.loadedStore()
    await store.looks.loadCatalogueIfNeeded()
    // Nothing painted reads differently from a painted unlooked photograph.
    #expect(store.looks.imageAccessibilityLabel(for: nil) == "Photograph not loaded")
    #expect(store.looks.imageAccessibilityLabel(for: .unlooked) == "Photograph")
    #expect(
      store.looks.imageAccessibilityLabel(for: .looked(lookID: "warm-film"))
        == "Photograph, look Warm Film")
    #expect(
      store.looks.imageAccessibilityLabel(for: .fallback(lookID: "cool-matte"))
        == "Photograph, without Cool Matte")
  }
}

/// IMGMGR-382, Codex round 2 B5: a finished load paints only if it was not cancelled AND it is
/// still for the frame and the look in front of the reader; round 3 B1: a load that produced
/// nothing keeps the same photograph on screen and clears only a different one.
@Suite("Loupe image publish decision (IMGMGR-382)")
struct LoupeImagePublishTests {

  private let asked = LoupeImageRequest(imageID: 1, lookID: "warm-film")

  @Test("The same frame and look, not cancelled: publish")
  func sameRequestPublishes() {
    #expect(LoupeImageRequest.mayPublish(requested: asked, current: asked, isCancelled: false))
  }

  @Test("The frame moved on: refused")
  func imageSwitchRefuses() {
    let current = LoupeImageRequest(imageID: 2, lookID: "warm-film")
    #expect(!LoupeImageRequest.mayPublish(requested: asked, current: current, isCancelled: false))
  }

  @Test("The look changed, None included: refused")
  func lookSwitchRefuses() {
    let other = LoupeImageRequest(imageID: 1, lookID: "cool-matte")
    let none = LoupeImageRequest(imageID: 1, lookID: nil)
    #expect(!LoupeImageRequest.mayPublish(requested: asked, current: other, isCancelled: false))
    #expect(!LoupeImageRequest.mayPublish(requested: asked, current: none, isCancelled: false))
  }

  @Test("Cancelled: refused even when the request still matches")
  func cancelledRefuses() {
    #expect(!LoupeImageRequest.mayPublish(requested: asked, current: asked, isCancelled: true))
  }

  @Test("New bytes paint, for the same photograph or a different one")
  func newBytesPaint() {
    #expect(LoupeImageRequest.paint(hasNewImage: true, imageID: 1, paintedImageID: 1) == .paint)
    #expect(LoupeImageRequest.paint(hasNewImage: true, imageID: 2, paintedImageID: 1) == .paint)
    #expect(LoupeImageRequest.paint(hasNewImage: true, imageID: 1, paintedImageID: nil) == .paint)
  }

  @Test("Nothing for the SAME photograph keeps what is on screen")
  func sameImageNilKeeps() {
    #expect(LoupeImageRequest.paint(hasNewImage: false, imageID: 1, paintedImageID: 1) == .keep)
  }

  @Test("Nothing for a DIFFERENT photograph, or with nothing painted yet, clears")
  func differentImageNilClears() {
    #expect(LoupeImageRequest.paint(hasNewImage: false, imageID: 2, paintedImageID: 1) == .clear)
    #expect(LoupeImageRequest.paint(hasNewImage: false, imageID: 1, paintedImageID: nil) == .clear)
  }
}

/// IMGMGR-382's leak test: a look is a display aid, so with one active every write this test
/// drives — a loupe Pick, a Dislike, its Undo and a tag edit — goes on the wire exactly as it
/// would without one, and no request but the two look operations carries a look id.
@Suite("Look leak (IMGMGR-382)")
@MainActor
struct LookLeakTests {

  private let markWrite = Operations.SetMarkStateApiMarksStatePost.id
  private let tagWrite = Operations.EditMarkTagsApiMarksTagsPost.id

  /// Pick in the loupe (with its advance), Dislike on the second photograph, Undo that Dislike,
  /// then tag the first photograph.
  ///
  /// IMGMGR-543: a look belongs to one photograph and the Pick's advance cancels it, so `look`
  /// re-opens a draft on the photograph each write targets, right before that write — every write
  /// of the looked session runs under an active look on its own photograph.
  private func writeSession(_ store: GridStore, look: (Int) -> Void = { _ in }) async {
    look(1)
    #expect(await store.applyLoupeMark(.pick))
    look(2)
    #expect(await store.applyMark(.dislike, to: [2]))
    _ = await store.undoLastMark()
    store.loupeFocus(on: 1)
    look(1)
    await store.addTag("keeper", to: [1])
  }

  private func bodies(
    _ wire: [GridStubTransport.RecordedWireRequest], of operationID: String
  ) -> [NSDictionary] {
    let writes = wire.filter { $0.operationID == operationID }
    return writes.compactMap { try? JSONSerialization.jsonObject(with: $0.body) as? NSDictionary }
  }

  @Test("Writes are identical with and without a look, and only look requests carry its id")
  func aLookNeverReachesAWrite() async {
    let (plain, plainTransport, _) = await LookFixtures.loadedStore()
    await plain.looks.loadCatalogueIfNeeded()
    _ = await plain.loupePreviewBytes(imageID: 1, identityToken: nil)
    await writeSession(plain)

    let (looked, lookedTransport, _) = await LookFixtures.loadedStore()
    await looked.looks.loadCatalogueIfNeeded()
    looked.looks.openStrip(imageID: 1)
    looked.looks.select("warm-film")
    _ = await looked.loupePreviewBytes(imageID: 1, identityToken: nil)
    await writeSession(looked) { imageID in
      looked.looks.openStrip(imageID: imageID)
      looked.looks.select("warm-film")
      #expect(looked.looks.activeLook(for: imageID)?.lookID == "warm-film")
    }
    #expect(looked.looks.activeLook(for: 1)?.lookID == "warm-film")

    let plainWire = await plainTransport.recordedWire
    let lookedWire = await lookedTransport.recordedWire
    // Positive control: Pick, Dislike and the Undo's restore are three mark writes, the tag one.
    #expect(bodies(plainWire, of: markWrite).count == 3)
    #expect(bodies(plainWire, of: tagWrite).count == 1)
    for operationID in [markWrite, tagWrite] {
      #expect(bodies(lookedWire, of: operationID) == bodies(plainWire, of: operationID))
      let rawPlain = plainWire.filter { $0.operationID == operationID }.map(\.body)
      let rawLooked = lookedWire.filter { $0.operationID == operationID }.map(\.body)
      #expect(rawLooked == rawPlain)
    }

    let lookedProxy = Operations.GetLookedProxyApiImagesImageIdProxyTierLookLookIdGet.id
    // IMGMGR-544: the saved-look PUT/DELETE join the look operations; nothing else may carry one.
    let lookOperations: Set<String> = [
      Operations.ListLooksApiLooksGet.id, lookedProxy,
      Operations.PutImageLookApiImagesImageIdLookPut.id,
      Operations.DeleteImageLookApiImagesImageIdLookDelete.id,
    ]
    // Positive control: the looked proxy request DID carry the id, so the scan below is not
    // vacuously empty.
    let lookedRenders = lookedWire.filter { $0.operationID == lookedProxy }
    #expect(lookedRenders.contains { $0.path.contains("warm-film") })
    for request in lookedWire where !lookOperations.contains(request.operationID) {
      let body = String(decoding: request.body, as: UTF8.self)
      #expect(!request.path.contains("warm-film"), "\(request.operationID) carries the look")
      #expect(!body.contains("warm-film"), "\(request.operationID)'s body carries the look")
      #expect(!request.path.lowercased().contains("look"), "\(request.operationID) names a look")
      #expect(!body.lowercased().contains("look"), "\(request.operationID)'s body names a look")
    }
  }
}

@Suite("Look draft and advance (IMGMGR-543)")
@MainActor
struct LookDraftAdvanceTests {
  @Test("A Pick's advance moves to the next photograph, which opens unlooked")
  func autoAdvanceCancelsTheDraft() async {
    let (store, _, _) = await LookFixtures.loadedStore()
    await store.looks.loadCatalogueIfNeeded()
    store.looks.openStrip(imageID: 1)
    store.looks.select("warm-film")
    #expect(await store.applyLoupeMark(.pick))
    #expect(store.focusedImageID == 2)
    #expect(store.looks.draft == nil)
    #expect(store.looks.activeLook(for: 2) == nil)
  }
}
