import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-544 (P16b): Apply saves the draft (PUT / DELETE `/api/images/{id}/look`), the saved look
/// lives on the summary, and the loupe/grid/share rules read it.
@Suite("Look persistence (IMGMGR-544)")
@MainActor
struct LookPersistenceTests {
  static func savedLook(_ id: String, _ strength: Int) -> Components.Schemas.ImageLookView {
    .init(lookId: id, strength: strength, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
  }

  /// A loaded store with the loupe open on photograph 1, whose saved look is `saved`.
  static func store(
    saved: Components.Schemas.ImageLookView? = nil, hasEdit: Bool = false
  ) async -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let store = GridStore(
      service: GridService(client: ImgManagerAPIClient.make(transport: transport)),
      preferences: GridPreferences(defaults: makeEphemeralDefaults()))
    var first = LoupeZoomFixtures.image(id: 1)
    first.look = saved
    first.hasEdit = hasEdit
    await transport.setListImagesPage(
      .init(items: [first, LoupeZoomFixtures.image(id: 2)], limit: 100, nextCursor: nil))
    await transport.setLooksCatalogue(LookFixtures.catalogue)
    await transport.setProxyOutcome(.ok(LookFixtures.unlookedBytes))
    await transport.setLookedProxyOutcome(.ok(LookFixtures.lookedBytes))
    await store.selectShoot(folderID: 1)
    store.openLoupe(on: 1)
    await store.looks.loadCatalogueIfNeeded()
    return (store, transport)
  }

  private func summary(_ store: GridStore, _ id: Int = 1) -> Components.Schemas.ImageSummary? {
    store.actionableImages.first { $0.id == id }
  }

  @Test("AC3: Apply PUTs exactly look_id and strength, writes the summary, closes the strip")
  func applyPutsLookIDAndStrength() async throws {
    let (store, transport) = await Self.store()
    store.toggleLooksStrip()
    store.looks.select("warm-film")
    store.looks.setStrength(120)
    await store.applyLook()
    let writes = await transport.recordedLookWrites
    #expect(writes.map(\.method) == ["PUT"])
    #expect(writes.first.flatMap { URLComponents(string: $0.path)?.path } == "/api/images/1/look")
    let body = try #require(writes.first?.body)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(json.keys) == ["look_id", "strength"])
    #expect(json["look_id"] as? String == "warm-film")
    #expect(json["strength"] as? Int == 120)
    #expect(summary(store)?.look?.lookId == "warm-film")
    #expect(summary(store)?.look?.strength == 120)
    #expect(store.looks.draft == nil)
    #expect(store.looks.saving.isEmpty)
    // Without a strip, the loupe renders the SAVED look.
    #expect(store.loupeLook(forImageID: 1) == LookModel.Active(lookID: "warm-film", strength: 120))
  }

  @Test("Boundary: strength 0 and 200 are PUTs, never a DELETE")
  func strengthBoundsReachTheWire() async throws {
    for strength in [0, 200] {
      let (store, transport) = await Self.store()
      store.toggleLooksStrip()
      store.looks.select("warm-film")
      store.looks.setStrength(strength)
      await store.applyLook()
      let writes = await transport.recordedLookWrites
      #expect(writes.map(\.method) == ["PUT"])
      let body = try #require(writes.first?.body)
      let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
      #expect(json["strength"] as? Int == strength)
    }
  }

  @Test("The strip opens seeded from the saved look; Apply unchanged sends nothing")
  func applyUnchangedSendsNothing() async {
    let (store, transport) = await Self.store(saved: Self.savedLook("cool-matte", 80))
    store.toggleLooksStrip()
    #expect(store.looks.draft?.lookID == "cool-matte")
    #expect(store.looks.draft?.strength == 80)
    await store.applyLook()
    #expect(await transport.recordedLookWrites.isEmpty)
    #expect(store.looks.draft == nil)
  }

  @Test("None over a saved look: the loupe is unlooked while previewing; Apply DELETEs")
  func noneDeletesTheSavedLook() async {
    let (store, transport) = await Self.store(saved: Self.savedLook("warm-film", 100))
    store.toggleLooksStrip()
    store.looks.select(nil)
    #expect(store.loupeLook(forImageID: 1) == nil)
    store.looks.cancel()
    #expect(store.loupeLook(forImageID: 1) == LookModel.Active(lookID: "warm-film", strength: 100))
    store.toggleLooksStrip()
    store.looks.select(nil)
    await store.applyLook()
    #expect(await transport.recordedLookWrites.map(\.method) == ["DELETE"])
    #expect(summary(store)?.look == nil)
    #expect(store.loupeLook(forImageID: 1) == nil)
  }

  @Test("A refused DELETE keeps the saved look, the strip open on None, and says so")
  func deleteRefusedKeepsTheSavedLook() async {
    let (store, transport) = await Self.store(saved: Self.savedLook("warm-film", 100))
    await transport.enqueueLookWriteOutcomes([.refused(code: "invalid_request")])
    store.toggleLooksStrip()
    store.looks.select(nil)
    await store.applyLook()
    #expect(summary(store)?.look?.lookId == "warm-film")
    #expect(store.looks.draft?.lookID == nil)
    #expect(store.looks.isStripOpen(for: 1))
    #expect(store.looks.visibleSaveFailure(for: 1) == .refused)
    #expect(store.looks.saving.isEmpty)
  }

  @Test(
    "`saving` is cleared on every completion path",
    arguments: [
      GridStubTransport.LookWriteOutcome.ok, .notFound, .refused(code: "unknown_look"),
      .transportFailure, .undecodable,
    ])
  func savingClearedOnEveryPath(outcome: GridStubTransport.LookWriteOutcome) async {
    let (store, transport) = await Self.store()
    await transport.enqueueLookWriteOutcomes([outcome])
    store.toggleLooksStrip()
    store.looks.select("warm-film")
    await store.applyLook()
    #expect(store.looks.saving.isEmpty)
  }

  @Test("Concurrency: the draft is frozen and a second Apply sends nothing while saving")
  func draftFrozenWhileSaving() async {
    let (store, transport) = await Self.store()
    await transport.holdLookWrites(true)
    store.toggleLooksStrip()
    store.looks.select("warm-film")
    let first = Task { await store.applyLook() }
    await transport.waitUntilLookWriteStarted()
    #expect(store.looks.isSaving(1))
    store.looks.select("cool-matte")
    store.looks.setStrength(150)
    store.looks.step(.next)
    #expect(store.looks.draft?.lookID == "warm-film")
    #expect(store.looks.draft?.strength == 100)
    await store.applyLook()
    #expect(await transport.recordedLookWrites.count == 1)
    await transport.releaseLookWrite()
    await first.value
    #expect(store.looks.saving.isEmpty)
    #expect(summary(store)?.look?.lookId == "warm-film")
  }

  @Test("Concurrency: Cancel and reopen during a save leaves the new draft open")
  func cancelReopenDuringSaveDoesNotCloseTheNewDraft() async {
    let (store, transport) = await Self.store()
    await transport.holdLookWrites(true)
    store.toggleLooksStrip()
    store.looks.select("warm-film")
    let first = Task { await store.applyLook() }
    await transport.waitUntilLookWriteStarted()
    store.looks.cancel()
    store.toggleLooksStrip()
    let reopened = store.looks.stripSession
    await transport.releaseLookWrite()
    await first.value
    #expect(store.looks.isStripOpen(for: 1))
    #expect(store.looks.stripSession == reopened)
    #expect(summary(store)?.look?.lookId == "warm-film")
  }

  @Test("Two successive saves on one photograph each reach the wire")
  func twoSuccessiveSavesOnOnePhoto() async {
    let (store, transport) = await Self.store()
    store.toggleLooksStrip()
    store.looks.select("warm-film")
    await store.applyLook()
    #expect(store.looks.saving.isEmpty)
    store.toggleLooksStrip()
    store.looks.select("classic-mono")
    store.looks.setStrength(80)
    await store.applyLook()
    #expect(await transport.recordedLookWrites.map(\.method) == ["PUT", "PUT"])
    #expect(summary(store)?.look?.lookId == "classic-mono")
    #expect(summary(store)?.look?.strength == 80)
    #expect(store.looks.saving.isEmpty)
  }

  @Test("No answer: the look field is reconciled from one detail read")
  func uncertainOutcomeReconcilesFromDetail() async {
    let (store, transport) = await Self.store()
    var detail = Components.Schemas.ImageDetail(
      ext: "jpg", fileSize: 4_096, filename: "1.jpg", folderId: 1, id: 1,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r1", state: .none, tags: []),
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
    detail.look = Self.savedLook("warm-film", 100)
    await transport.setDetailResult(detail)
    await transport.enqueueLookWriteOutcomes([.transportFailure])
    store.toggleLooksStrip()
    store.looks.select("warm-film")
    await store.applyLook()
    #expect(store.looks.visibleSaveFailure(for: 1) == .uncertain)
    #expect(summary(store)?.look?.lookId == "warm-film")
  }

  @Test("A failure is scoped to its strip session")
  func failureScopedToItsSession() async {
    let (store, transport) = await Self.store()
    await transport.enqueueLookWriteOutcomes([.notFound])
    store.toggleLooksStrip()
    store.looks.select("warm-film")
    await store.applyLook()
    #expect(store.looks.visibleSaveFailure(for: 1) == .gone)
    store.looks.cancel()
    store.toggleLooksStrip()
    #expect(store.looks.visibleSaveFailure(for: 1) == nil)
  }

  @Test("Saved rule: an edit supersedes the look; the chip says so")
  func editSupersedesTheSavedLook() async {
    let saved = Self.savedLook("warm-film", 120)
    #expect(LookPersistence.savedRender(look: saved, hasEdit: true) == nil)
    #expect(LookPersistence.savedRender(look: saved, hasEdit: nil) != nil)
    #expect(LookPersistence.savedRender(look: nil, hasEdit: false) == nil)
    #expect(
      LookPersistence.chipText(look: saved, hasEdit: false, lookName: "Warm Film")
        == "Warm Film · 120 %")
    #expect(
      LookPersistence.chipText(look: saved, hasEdit: true, lookName: "Warm Film")
        == "Warm Film · superseded by edit")
    #expect(LookPersistence.chipText(look: nil, hasEdit: true, lookName: "Warm Film") == nil)
    let (store, _) = await Self.store(saved: saved, hasEdit: true)
    #expect(store.loupeLook(forImageID: 1) == nil)
  }

  // MARK: - The loupe (IMGMGR-544 step 4)

  @Test("Saved look, then None in the strip previews unlooked, then Cancel renders it again")
  func savedLookThenNonePreviewThenCancel() async {
    let (store, transport) = await Self.store(saved: Self.savedLook("warm-film", 120))
    await transport.setLookedProxyVersion(LookedCacheTests.versionA)
    let saved = await store.loupePreview(imageID: 1, identityToken: nil) { $0 }
    #expect(saved.rendering == .looked(lookID: "warm-film"))
    #expect(await transport.recordedLookedProxyRequests.count == 1)
    store.toggleLooksStrip()
    store.looks.select(nil)
    #expect(store.loupeLook(forImageID: 1) == nil)
    let none = await store.loupePreview(imageID: 1, identityToken: nil) { $0 }
    #expect(none.rendering == .unlooked)
    #expect(await transport.recordedLookedProxyRequests.count == 1)
    store.looks.cancel()
    let again = await store.loupePreview(imageID: 1, identityToken: nil) { $0 }
    #expect(again.rendering == .looked(lookID: "warm-film"))
    // The saved render came from the looked cache: no second request in this epoch.
    #expect(await transport.recordedLookedProxyRequests.count == 1)
  }

  @Test("A saved look's loupe render carries its strength to the wire")
  func savedLoupeRenderSendsTheSavedStrength() async {
    let (store, transport) = await Self.store(saved: Self.savedLook("warm-film", 120))
    _ = await store.loupePreview(imageID: 1, identityToken: nil) { $0 }
    let paths = await transport.recordedLookedProxyRequests
    #expect(paths.count == 1)
    #expect(paths.first?.contains("/look/warm-film") == true)
    #expect(paths.first?.contains("strength=120") == true)
  }

  @Test("The loupe key moves with the proxy identity and the looked epoch")
  func loupeKeyMovesWithProxyAndEpoch() {
    let proxy = ProxyLocalIdentity(imageID: 1, tier: .preview, token: "a", width: 1600)
    let asked = LoupeImageRequest(
      imageID: 1, lookID: "warm-film", strength: 100, proxy: proxy, lookEpoch: 3)
    var refreshed = proxy
    refreshed.token = "b"
    let movedProxy = LoupeImageRequest(
      imageID: 1, lookID: "warm-film", strength: 100, proxy: refreshed, lookEpoch: 3)
    let movedEpoch = LoupeImageRequest(
      imageID: 1, lookID: "warm-film", strength: 100, proxy: proxy, lookEpoch: 4)
    #expect(LoupeImageRequest.mayPublish(requested: asked, current: asked, isCancelled: false))
    #expect(
      !LoupeImageRequest.mayPublish(requested: asked, current: movedProxy, isCancelled: false))
    #expect(
      !LoupeImageRequest.mayPublish(requested: asked, current: movedEpoch, isCancelled: false))
  }

  @Test("The loupe chip names the saved look from the catalogue, or says it is superseded")
  func loupeChipFollowsTheSavedRow() async throws {
    let (store, _) = await Self.store(saved: Self.savedLook("warm-film", 120))
    let first = try #require(summary(store))
    #expect(store.loupeLookChip(for: first) == "Warm Film · 120 %")
    let second = try #require(summary(store, 2))
    #expect(store.loupeLookChip(for: second) == nil)
    let (edited, _) = await Self.store(saved: Self.savedLook("warm-film", 120), hasEdit: true)
    let editedFirst = try #require(summary(edited))
    #expect(edited.loupeLookChip(for: editedFirst) == "Warm Film · superseded by edit")
  }
}
