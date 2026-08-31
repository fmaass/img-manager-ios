import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP13 P11 (IMGMGR-220): the multi-window scene value, its ONE constructibility predicate, and
/// the routing equality that makes a restored window land in the same grid contract as a queue
/// tap.
@MainActor
@Suite("Multi-window — the scene value, its predicate, and its routing")
struct ShootSceneValueTests {

  private func makeImage(id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStore() async -> GridStore {
    let transport = GridStubTransport()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    let client = ImgManagerAPIClient.make(transport: transport)
    return GridStore(service: GridService(client: client))
  }

  /// The queue's own shape (`QueueCardDestination.route(for:)` returns `(folderId, nil)`), which
  /// is the app's launch surface and its most common navigation. An implementation that defaults
  /// the tier to `.local`, or that force-unwraps it, fails or traps here.
  @Test("A scope with no tier round-trips without inventing one")
  func aScopeWithNoTierRoundTripsWithoutInventingOne() async {
    let source = await makeStore()
    await source.selectShoot(folderID: 7)
    let original = source.query
    #expect(original.folderID == 7)
    #expect(original.sourceTier == nil, "the fixture scope is not the tier-less one it claims")

    let value = ShootSceneValue.from(query: original)
    #expect(value == ShootSceneValue(folderID: 7, sourceTier: nil))

    guard let value else {
      Issue.record("a folder-selected scope produced no scene value")
      return
    }
    let restored = await makeStore()
    await restored.selectShoot(folderID: value.folderID, sourceTier: value.sourceTier)
    #expect(restored.query.sourceTier == nil, "the round trip invented a tier")
    #expect(restored.query == original, "the restored scope is not the scope that was open")

    // Positive control in the same suite: a scope that DOES carry a tier keeps it.
    let archiveSource = await makeStore()
    await archiveSource.selectShoot(folderID: 9, sourceTier: .archive)
    let archiveValue = ShootSceneValue.from(query: archiveSource.query)
    #expect(archiveValue == ShootSceneValue(folderID: 9, sourceTier: .archive))
    let archiveRestored = await makeStore()
    await archiveRestored.selectShoot(
      folderID: 9, sourceTier: archiveValue?.sourceTier)
    #expect(archiveRestored.query.sourceTier == .archive)
    #expect(archiveRestored.query == archiveSource.query)
  }

  /// "The control is enabled" and "the scene value exists" are ONE predicate by construction.
  /// Asserted across both sides — a nil-folder scope and a folder-selected one — so an
  /// implementation that wrote its own `folderID != nil` check beside the function fails the
  /// moment the two can disagree.
  @Test("Constructibility and control enablement are the same predicate")
  func constructibilityAndControlEnablementAreTheSamePredicate() async {
    let empty = await makeStore()
    #expect(empty.query.folderID == nil)
    #expect(ShootSceneValue.from(query: empty.query) == nil)
    #expect(
      GridMoreMenu.openInNewWindow.isEnabled(empty)
        == (ShootSceneValue.from(query: empty.query) != nil))
    #expect(
      GridMoreMenu.openInNewWindow.isEnabled(empty) == false,
      "the control offers itself with no shoot in scope")

    let selected = await makeStore()
    await selected.selectShoot(folderID: 3)
    #expect(ShootSceneValue.from(query: selected.query) != nil)
    #expect(
      GridMoreMenu.openInNewWindow.isEnabled(selected)
        == (ShootSceneValue.from(query: selected.query) != nil))
    #expect(GridMoreMenu.openInNewWindow.isEnabled(selected))
  }

  /// The value is what SwiftUI persists across a scene restore, so it has to survive a real
  /// encode/decode with a `nil` tier still `nil` — not merely compile as `Codable`.
  @Test("The scene value survives the encode/decode SwiftUI puts it through, tier and all")
  func theSceneValueSurvivesACodableRoundTrip() throws {
    for probe in [
      ShootSceneValue(folderID: 4, sourceTier: nil),
      ShootSceneValue(folderID: 4, sourceTier: .local),
      ShootSceneValue(folderID: 4, sourceTier: .archive),
    ] {
      let data = try JSONEncoder().encode(probe)
      let back = try JSONDecoder().decode(ShootSceneValue.self, from: data)
      #expect(back == probe, "the scene value did not survive its own round trip: \(probe)")
      #expect(back.sourceTier == probe.sourceTier)
    }
  }
}

/// The routing half: a restored window and a queue tap must produce the SAME grid scope, because
/// they are the same call. Drives the production forwarding decisions on both sides —
/// `InitialShootApplication.apply` and `QueueCardDestination.route(for:)` — never a
/// re-implementation of either.
@MainActor
@Suite("Multi-window — a restored scene lands where a queue tap lands")
struct SceneValueRoutingTests {

  private func makeImage(id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStore() async -> GridStore {
    let transport = GridStubTransport()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    let client = ImgManagerAPIClient.make(transport: transport)
    return GridStore(service: GridService(client: client))
  }

  private func summary(folderID: Int) -> Components.Schemas.FolderSummary {
    Components.Schemas.FolderSummary(
      cameraPreviewOnly: 0, decided: 0, disliked: 0, edited: 0, folderId: folderID, kind: "dated",
      lastTouched: nil, nothingLeftUnmarked: false, path: "p/\(folderID)", picked: 0,
      previewOutstanding: 0, readiness: .init(rawValue: "ready_to_review")!, sourceTier: "archive",
      sync: nil, total: 1, unmarked: 1, withMasters: 0)
  }

  @Test("A restored ShootSceneValue lands in the same grid scope as a queue tap")
  func aRestoredShootSceneValueLandsInTheSameGridScopeAsAQueueTap() async {
    // The queue path, driven through its own production routing function.
    let queueStore = await makeStore()
    let route = QueueCardDestination.route(for: summary(folderID: 12))
    // The fixture summary's OWN tier is "archive" and the route still carries nil — routing's
    // atomic `(folderId, nil)` is exactly why the scene value's tier has to be optional.
    #expect(route.sourceTier == nil)
    await queueStore.selectShoot(folderID: route.folderID, sourceTier: route.sourceTier)

    // The restored-window path, driven through RootView's own production application.
    let windowStore = await makeStore()
    let applied = await InitialShootApplication.apply(
      ShootSceneValue(folderID: route.folderID, sourceTier: route.sourceTier), to: windowStore)

    #expect(applied == route.folderID, "the window path did not report the shoot it opened")
    #expect(windowStore.query == queueStore.query, "the two paths produced different scopes")

    // The archive case, which is where a dropped tier actually shows: a restored archive window
    // must not silently land on the local tier.
    let archiveWindow = await makeStore()
    await InitialShootApplication.apply(
      ShootSceneValue(folderID: 12, sourceTier: .archive), to: archiveWindow)
    #expect(archiveWindow.query.sourceTier == .archive, "the restored window dropped its tier")

    let archiveTap = await makeStore()
    await archiveTap.selectShoot(folderID: 12, sourceTier: .archive)
    #expect(archiveWindow.query == archiveTap.query)

    // Nothing to apply is not an error, and it selects nothing.
    let untouched = await makeStore()
    let none = await InitialShootApplication.apply(nil, to: untouched)
    #expect(none == nil)
    #expect(untouched.query.folderID == nil)
  }
}
