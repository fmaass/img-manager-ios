import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-543 (P16a): a look belongs to ONE photograph, and the strip asks the server for it at
/// a strength.
@Suite("Looks strip (IMGMGR-543)")
@MainActor
struct LookStripTests {

  /// The query items of a recorded looked-route request.
  static func query(_ path: String) -> [URLQueryItem] {
    URLComponents(string: path)?.queryItems ?? []
  }

  /// A loaded store with the strip open on photograph 1 and `lookID` previewed.
  static func storeWithStrip(previewing lookID: String? = "warm-film") async -> (
    GridStore, GridStubTransport
  ) {
    let (store, transport, _) = await LookFixtures.loadedStore()
    await store.looks.loadCatalogueIfNeeded()
    store.looks.openStrip(imageID: 1)
    store.looks.select(lookID)
    return (store, transport)
  }

  @Test("AC1: the next photograph opens unlooked")
  func nextPhotoOpensUnlooked() async {
    let (store, transport) = await Self.storeWithStrip()
    let first = await store.loupePreviewBytes(imageID: 1, identityToken: nil)
    #expect(first.rendering == .looked(lookID: "warm-film"))

    store.loupeFocus(on: 2)
    let next = await store.loupePreviewBytes(imageID: 2, identityToken: nil)
    #expect(next.rendering == .unlooked)
    #expect(next.image == LookFixtures.unlookedBytes)
    let forTwo = await transport.recordedLookedProxyRequests.filter {
      $0.contains("/api/images/2/")
    }
    #expect(forTwo.isEmpty)
  }

  @Test("AC1: every way the focus moves cancels the draft", arguments: FocusPath.allCases)
  func everyFocusPathCancelsTheDraft(path: FocusPath) async {
    let (store, _) = await Self.storeWithStrip()
    switch path {
    case .loupeFocus: store.loupeFocus(on: 2)
    case .loupeNext: await store.loupeNext()
    case .directAssignment: store.focusedImageID = 2
    case .openLoupeElsewhere: store.openLoupe(on: 2)
    case .closeLoupe: store.closeLoupe()
    case .openCompare: store.openCompare()
    }
    #expect(store.looks.draft == nil, "\(path) left the draft open")
    #expect(store.looks.activeLook(for: 1) == nil)
    #expect(store.looks.activeLook(for: 2) == nil)
  }

  enum FocusPath: CaseIterable, Sendable {
    case loupeFocus, loupeNext, directAssignment, openLoupeElsewhere, closeLoupe,
      openCompare
  }

  @Test("AC2: ↑/↓ nudge strength by 10 and clamp at 0 and 200, through the real key actions")
  func arrowsNudgeStrengthAndClamp() async {
    let (store, _) = await Self.storeWithStrip()
    let keys = store.keyboardActions
    #expect(store.looks.draft?.strength == 100)
    keys.moveFocus(.up)
    #expect(store.looks.draft?.strength == 110)
    for _ in 0..<20 { keys.moveFocus(.up) }
    #expect(store.looks.draft?.strength == 200)
    keys.moveFocus(.down)
    #expect(store.looks.draft?.strength == 190)
    for _ in 0..<30 { keys.moveFocus(.down) }
    #expect(store.looks.draft?.strength == 0)
    // The arrows drove the strip, not the focus.
    #expect(store.focusedImageID == 1)
    #expect(store.looks.draft?.lookID == "warm-film")
  }

  @Test("AC2 (control): with the strip closed the same keys move the focus")
  func arrowsMoveTheFocusWithoutAStrip() async {
    let (store, _, _) = await LookFixtures.loadedStore()
    store.keyboardActions.moveFocus(.right)
    #expect(store.focusedImageID == 2)
  }

  @Test("←/→ walk None · Film · Mono · Other, stopping at either end")
  func leftRightWalkTheStripOrder() async {
    let (store, _) = await Self.storeWithStrip(previewing: nil)
    #expect(store.looks.stripOrder == [nil, "warm-film", "classic-mono", "cool-matte"])
    let keys = store.keyboardActions
    keys.moveFocus(.left)
    #expect(store.looks.draft?.lookID == nil)
    keys.moveFocus(.right)
    #expect(store.looks.draft?.lookID == "warm-film")
    for _ in 0..<5 { keys.moveFocus(.right) }
    #expect(store.looks.draft?.lookID == "cool-matte")
    #expect(store.focusedImageID == 1)
  }

  @Test("AC3: the preview asks the looked route for a strength")
  func previewRequestsStrength() async {
    let (store, transport) = await Self.storeWithStrip()
    _ = await store.loupePreviewBytes(imageID: 1, identityToken: nil)
    store.looks.nudgeStrength(by: 10)
    _ = await store.loupePreviewBytes(imageID: 1, identityToken: nil)
    store.looks.setStrength(0)
    _ = await store.loupePreviewBytes(imageID: 1, identityToken: nil)
    let paths = await transport.recordedLookedProxyRequests
    #expect(paths.count == 3)
    for path in paths {
      let route = URLComponents(string: path)?.path ?? ""
      #expect(route.hasSuffix("/api/images/1/proxy/preview/look/warm-film"))
    }
    #expect(
      paths.map(Self.query) == [
        [URLQueryItem(name: "strength", value: "100")],
        [URLQueryItem(name: "strength", value: "110")],
        [URLQueryItem(name: "strength", value: "0")],
      ])
  }

  @Test("AC3: tiles ask the grid tier at the look's authored strength; None stays unlooked")
  func tilesRequestTheGridTierAtOneHundred() async {
    let (store, transport) = await Self.storeWithStrip()
    store.looks.setStrength(170)
    let tile = await store.lookTile(imageID: 1, lookID: "classic-mono", identityToken: nil)
    #expect(tile == LookFixtures.lookedBytes)
    _ = await store.lookTile(imageID: 1, lookID: "classic-mono", identityToken: nil)
    let paths = await transport.recordedLookedProxyRequests
    #expect(paths.count == 1)  // the second ask was the strip session's cache
    let route = paths.first.flatMap { URLComponents(string: $0)?.path } ?? ""
    #expect(route.hasSuffix("/api/images/1/proxy/grid/look/classic-mono"))
    #expect(paths.first.map(Self.query) == [URLQueryItem(name: "strength", value: "100")])
    let none = await store.lookTile(imageID: 1, lookID: nil, identityToken: nil)
    #expect(none == LookFixtures.unlookedBytes)
    #expect(await transport.recordedLookedProxyRequests.count == 1)
  }

  @Test("A look id with query-like characters stays in the path; one strength item")
  func lookIDIsPathEncoded() async throws {
    let transport = GridStubTransport()
    await transport.setLookedProxyOutcome(.ok(LookFixtures.lookedBytes))
    let service = GridService(client: ImgManagerAPIClient.make(transport: transport))
    _ = try await service.lookedProxy(
      imageID: 1, tier: .preview, lookID: "a?strength=7&b", strength: 120)
    let path = try #require(await transport.recordedLookedProxyRequests.first)
    #expect(Self.query(path) == [URLQueryItem(name: "strength", value: "120")])
  }

  @Test("Return and Space (open) are inert while the strip is open")
  func openIsInertInTheStrip() async {
    let (store, transport) = await Self.storeWithStrip()
    let before = await transport.recordedWire.count
    let session = store.looks.stripSession
    store.keyboardActions.open()
    #expect(store.looks.draft?.lookID == "warm-film")
    #expect(store.looks.draft?.strength == 100)
    #expect(store.looks.stripSession == session)  // the loupe was not reopened
    #expect(store.isLoupeOpen)
    #expect(await transport.recordedWire.count == before)
  }

  @Test("Esc, through the real hidden declaration: cancels the strip, the loupe stays open")
  func escapeCancelsTheStrip() async {
    let (store, _) = await Self.storeWithStrip()
    let esc = AppCommands.closeBandKey
    let keys = store.keyboardActions
    #expect(esc.isEnabled(grid: keys, viewerZoom: nil))
    esc.perform(grid: keys, viewerZoom: nil)
    #expect(store.looks.draft == nil)
    #expect(store.isLoupeOpen)
    // Nothing left for Esc in the loupe: disabled.
    #expect(!esc.isEnabled(grid: store.keyboardActions, viewerZoom: nil))
  }

  @Test("A presentation over the strip owns the keys: nothing navigates, nothing cancels")
  func presentationOwnsInput() async {
    for presentation in ["tag", "share"] {
      let (store, transport) = await Self.storeWithStrip()
      store.looks.setStrength(130)
      if presentation == "tag" {
        store.isTagEntryPresented = true
      } else {
        store.noteLoupePresentation("share", isPresented: true)
      }
      #expect(store.looksKeyOwner == .presentation)
      let keys = store.keyboardActions
      for direction in [GridArrowDirection.left, .right, .up, .down] { keys.moveFocus(direction) }
      keys.open()
      let esc = AppCommands.closeBandKey
      #expect(!esc.isEnabled(grid: keys, viewerZoom: nil), "\(presentation): Esc is live")
      esc.perform(grid: keys, viewerZoom: nil)
      #expect(store.focusedImageID == 1, "\(presentation): the focus moved")
      #expect(store.looks.draft == .init(imageID: 1, lookID: "warm-film", strength: 130))
      #expect(store.isLoupeOpen)
      #expect(await transport.recordedLookedProxyRequests.isEmpty)

      // The presentation ends: the same keys drive the strip again.
      store.isTagEntryPresented = false
      store.noteLoupePresentation("share", isPresented: false)
      store.keyboardActions.moveFocus(.up)
      #expect(store.looks.draft?.strength == 140)
    }
  }

  @Test("Apply is inert: no request, no write, the draft unchanged")
  func applyWritesNothing() async {
    let (store, transport) = await Self.storeWithStrip()
    let before = await transport.recordedWire.count
    store.looks.apply()
    #expect(store.looks.draft?.lookID == "warm-film")
    #expect(await transport.recordedWire.count == before)
  }

  @Test("Tile renders are kept per strip session: Cancel and reopen asks the server again")
  func tileCacheIsPerStripSession() async {
    let (store, transport) = await Self.storeWithStrip()
    _ = await store.lookTile(imageID: 1, lookID: "warm-film", identityToken: nil)
    #expect(await transport.recordedLookedProxyRequests.count == 1)
    store.looks.cancel()
    // A strip that is gone serves nothing, and caches nothing.
    #expect(await store.lookTile(imageID: 1, lookID: "warm-film", identityToken: nil) == nil)
    store.looks.openStrip(imageID: 1)
    let fresh = await store.lookTile(imageID: 1, lookID: "warm-film", identityToken: nil)
    #expect(fresh == LookFixtures.lookedBytes)
    #expect(await transport.recordedLookedProxyRequests.count == 2)
  }

  @Test("A render report for an older strength is dropped")
  func staleStrengthReportIsDropped() async {
    let (store, _) = await Self.storeWithStrip()
    store.looks.setStrength(150)
    store.looks.recordRender(imageID: 1, lookID: "warm-film", strength: 100, available: false)
    #expect(store.looks.accessibilityValue(focusedImageID: 1) == "Warm Film")
    store.looks.recordRender(imageID: 1, lookID: "warm-film", strength: 150, available: false)
    #expect(
      store.looks.accessibilityValue(focusedImageID: 1) == "Warm Film, unavailable for this photo")
  }

  @Test("An empty catalogue: the strip cannot open")
  func emptyCatalogueCannotOpen() async {
    let (store, transport, _) = await LookFixtures.loadedStore()
    await transport.setLooksCatalogue([])
    await store.looks.loadCatalogueIfNeeded()
    store.toggleLooksStrip()
    #expect(store.looks.draft == nil)
    #expect(store.looksKeyOwner == .none)
  }
}

@Suite("Looks strip model (IMGMGR-543)")
@MainActor
struct LookStripModelTests {
  @Test("Strength snaps to the detents within their pull, else to a step of 10")
  func strengthSnaps() {
    #expect(LookStrength.snapped(94) == 100)
    #expect(LookStrength.snapped(107.9) == 100)
    #expect(LookStrength.snapped(113) == 110)
    #expect(LookStrength.snapped(5) == 0)
    #expect(LookStrength.snapped(196) == 200)
    #expect(LookStrength.snapped(250) == 200)
    #expect(LookStrength.snapped(-4) == 0)
    #expect(LookStrength.clamped(201) == 200)
    #expect(LookStrength.clamped(-1) == 0)
  }

  @Test("Sections: the server's categories group into Film, Camera, Mono; the rest is Other")
  func sectionsGroupFilmCameraMono() {
    typealias Probe = GridServiceContractProbeTests
    let catalogue = [
      Probe.look("portra", name: "Portra", category: "Film - colour negative"),
      Probe.look("velvia", name: "Velvia", category: "Film - colour slide"),
      Probe.look("trix", name: "Tri-X", category: "Film - black and white"),
      Probe.look("chrome", name: "Classic Chrome", category: "Digital camera profile"),
      Probe.look("m8", name: "M8", category: "Digital camera look"),
      Probe.look("m8bw", name: "M8 BW", category: "Digital camera look - black and white"),
      Probe.look("matte", name: "Matte", category: "Creative"),
    ]
    let sections = LookStripSections.sections(catalogue: catalogue, favourites: ["m8"])
    #expect(sections.map(\.group) == [.favourites, .film, .camera, .mono, .other])
    #expect(
      sections.map { $0.looks.map(\.id) } == [
        ["m8"], ["portra", "velvia"], ["chrome"], ["trix", "m8bw"], ["matte"],
      ])
    #expect(
      LookStripSections.order(catalogue: catalogue, favourites: ["m8"])
        == [nil, "m8", "portra", "velvia", "chrome", "trix", "m8bw", "matte"])
  }

  @Test("Favourites persist on the device, as look ids only")
  func favouritesPersistOnDevice() {
    let defaults = makeEphemeralDefaults()
    let first = LookFavourites(defaults: defaults)
    first.toggle("warm-film")
    first.toggle("classic-mono")
    first.toggle("warm-film")
    let reread = LookFavourites(defaults: defaults)
    #expect(reread.ids == ["classic-mono"])
    #expect(defaults.stringArray(forKey: LookFavourites.key) == ["classic-mono"])
    #expect(!GridPreferences.persistedKeys.contains(LookFavourites.key))
  }

  @Test("R3-9 subtitle: fidelity, then rating 1…5 and the colour label, from a sidecar only")
  func subtitleParts() {
    typealias Meta = Components.Schemas.LightroomMeta
    let full = LoupeSubtitle.parts(
      sourceKind: "master", lightroom: Meta(label: "Red", rating: 4, sidecarPresent: true))
    #expect(full == LoupeSubtitle(fidelity: "Master", rating: 4, label: "Red"))
    #expect(LoupeSubtitle.stars(4) == "★★★★☆")
    for rating in [0, -1, 6] {
      let parts = LoupeSubtitle.parts(
        sourceKind: "master", lightroom: Meta(label: nil, rating: rating, sidecarPresent: true))
      #expect(parts.rating == nil, "rating \(rating) shown")
    }
    let blank = LoupeSubtitle.parts(
      sourceKind: "master", lightroom: Meta(label: "  ", rating: 5, sidecarPresent: true))
    #expect(blank == LoupeSubtitle(fidelity: "Master", rating: 5, label: nil))
    let noSidecar = LoupeSubtitle.parts(
      sourceKind: "web_preview", lightroom: Meta(label: "Red", rating: 3, sidecarPresent: false))
    #expect(noSidecar == LoupeSubtitle(fidelity: "Web preview", rating: nil, label: nil))
    #expect(
      LoupeSubtitle.parts(sourceKind: nil, lightroom: nil)
        == LoupeSubtitle(fidelity: LoupeFidelityLabel.unavailable, rating: nil, label: nil))
  }
}
