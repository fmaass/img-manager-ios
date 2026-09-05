import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-261 — the picks a COLLAPSED scene holds, shown inside the card.
///
/// The ticket's own disposition (owner doctrine: companion value through native capability, never
/// web parity) puts the switch in the surface the native app ALREADY has — the More menu's view
/// cluster, persisted through `GridPreferences` — rather than in a settings panel the web needs
/// only because it lacks one. So the first thing this suite pins is that the preference and the
/// menu row exist at all, in the one place each of them is allowed to live.
@MainActor
@Suite("Picks inside a collapsed scene — the toggle, its default, and the display-only read")
struct ScenePicksInGroupsTests {

  /// The KEY is spelled out rather than read from the type it names: this suite's job is to pin
  /// which persisted key the app owns, and a test that asks the constant to describe itself
  /// could not tell a rename from a rewrite.
  @Test("The toggle is a GridPreferences key, and it is OFF until the reader turns it on")
  func theToggleIsAPersistedPreferenceDefaultingOff() {
    #expect(GridPreferences.persistedKeys.contains("grid.picksInGroups"))
    // Exactly one key for it — a second owner of the same visual property is the failure mode
    // `persistedKeys` exists to catch (the Density precedent).
    #expect(GridPreferences.persistedKeys.filter { $0 == "grid.picksInGroups" }.count == 1)
    // Positive control for the membership check above: the inventory really was read.
    #expect(GridPreferences.persistedKeys.contains(GridPreferences.filenamePlatesKey))
  }

  @Test("The toggle joins the More menu's decided set — never a second settings surface")
  func theToggleLivesInTheExistingViewOptionsSurface() {
    let ids = GridMoreMenu.entries.map(\.id)
    #expect(ids.contains("more.picksInGroups"))
    #expect(ids.filter { $0 == "more.picksInGroups" }.count == 1)
    // Positive control: the decided set really was enumerated.
    #expect(ids.contains("more.filenamePlates"))
  }

  /// The pivot itself, stated as a TABLE rather than checked against whatever the app happens to
  /// compute. Every combination is written out here by hand: this is the one place that says
  /// where the inline picks ship, and a change to `SceneInlinePicksPolicy` has to come here to be
  /// blessed rather than quietly re-deriving its own expectation.
  @Test("Inline picks ship on Regular and nowhere else, and only while the switch is on")
  func thePivotIsRegularOnlyAndOffMeansOff() {
    #expect(SceneInlinePicksPolicy.isShown(layoutMode: .compact, isEnabled: true) == false)
    #expect(SceneInlinePicksPolicy.isShown(layoutMode: .regular2, isEnabled: true) == true)
    #expect(SceneInlinePicksPolicy.isShown(layoutMode: .regular3, isEnabled: true) == true)
    #expect(SceneInlinePicksPolicy.isShown(layoutMode: .compact, isEnabled: false) == false)
    #expect(SceneInlinePicksPolicy.isShown(layoutMode: .regular2, isEnabled: false) == false)
    #expect(SceneInlinePicksPolicy.isShown(layoutMode: .regular3, isEnabled: false) == false)
  }

  // MARK: - Fixtures for the data-policy half

  private func makeImage(
    id: Int, mark: Components.Schemas.MarkView.StatePayload = .none
  ) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "raf", filename: "DSCF\(id).raf", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: mark, tags: []), missing: false,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func stackRowItem(_ row: Components.Schemas.StackBrowseStackRow)
    -> Components.Schemas.StackBrowsePage.ItemsPayloadPayload
  {
    .init(value1: nil, value2: row)
  }

  private func imageRow(_ image: Components.Schemas.ImageSummary)
    -> Components.Schemas.StackBrowsePage.ItemsPayloadPayload
  {
    .init(value1: .init(image: image, kind: .image), value2: nil)
  }

  /// A Scene page with one loose photograph and one COLLAPSED scene holding three members, two of
  /// them picked. The store carries its OWN preferences suite — this test is about a persisted
  /// switch and must neither read nor leave state in the shared domain.
  private func loadedSceneStore() async -> (GridStore, GridStubTransport, GridPreferences) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let preferences = GridPreferences(defaults: makeEphemeralDefaults())
    let store = GridStore(service: GridService(client: client), preferences: preferences)
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    await transport.setBrowseStacksPage(
      .init(
        items: [
          imageRow(makeImage(id: 10)),
          stackRowItem(
            Components.Schemas.StackBrowseStackRow(
              anchorTakenAt: Date(timeIntervalSince1970: 1_700_000_000), editedCount: 0,
              hasPick: true,
              kind: .stack, matchedCount: 3, memberCount: 3, pickedCount: 2,
              representative: makeImage(id: 900, mark: .pick), stackId: 5)),
        ], limit: 100, nextCursor: nil))
    await transport.setStackMemberPage(
      .init(
        items: [
          makeImage(id: 501, mark: .pick), makeImage(id: 502), makeImage(id: 503, mark: .pick),
        ], limit: 100, nextCursor: "members-2", stackId: 5),
      forStack: 5)
    await store.setDisplayMode(.scene)
    return (store, transport, preferences)
  }

  // MARK: - The data policy: display-only, capped, and silent while the switch is off

  @Test("OFF reads nothing at all — the switch gates the request, not just the drawing")
  func offIssuesNoMembershipRequest() async {
    let (store, transport, preferences) = await loadedSceneStore()
    #expect(preferences.picksInGroups == false)

    await store.loadInlinePicksIfNeeded(stackID: 5)

    #expect(store.sceneInlinePicks.isEmpty)
    #expect(
      await transport.callCount(Operations.ListStackMembersApiStacksStackIdMembersGet.id) == 0)
    // Positive control for that zero: with the switch ON the very same call DOES read, so the
    // line above is about the preference and not about a fixture that never answers.
    preferences.picksInGroups = true
    await store.loadInlinePicksIfNeeded(stackID: 5)
    #expect(
      await transport.callCount(Operations.ListStackMembersApiStacksStackIdMembersGet.id) == 1)
  }

  @Test("ON reads ONE capped page, keeps only the picks, and makes none of them actionable")
  func onReadsOneCappedPageAndKeepsItOutOfTheActionableSet() async {
    let (store, transport, preferences) = await loadedSceneStore()
    preferences.picksInGroups = true
    let actionableBefore = store.actionableImages.map(\.id)

    await store.loadInlinePicksIfNeeded(stackID: 5)

    // Only the picks, in capture order, from the FIRST page — the read never follows the cursor
    // the fixture offers ("members-2"), because a card is a summary and a summary does not page.
    #expect(store.sceneInlinePicks[5]?.map(\.id) == [501, 503])
    #expect(
      await transport.callCount(Operations.ListStackMembersApiStacksStackIdMembersGet.id) == 1)

    // ADR-0005, and the reason these live in their own array: nothing about this read makes a
    // member of a collapsed scene reachable by a gesture.
    #expect(store.sceneMembers.isEmpty)
    #expect(store.actionableImages.map(\.id) == actionableBefore)
    #expect(store.actionableImages.map(\.id) == [10])
    #expect(store.sceneDisplayRows.map(\.id) == [.image(10), .stack(5)])
    #expect(store.tagTargetImageIDs.contains(501) == false)

    // Cached and single-flighted: a second card appearance reads nothing again.
    await store.loadInlinePicksIfNeeded(stackID: 5)
    #expect(
      await transport.callCount(Operations.ListStackMembersApiStacksStackIdMembersGet.id) == 1)
  }

  @Test("An OPEN scene draws its members for real, so the card summary is never read for it")
  func anOpenSceneReadsNoSummary() async {
    let (store, transport, preferences) = await loadedSceneStore()
    preferences.picksInGroups = true
    await store.toggleSceneExpanded(5)
    let afterExpansion = await transport.callCount(
      Operations.ListStackMembersApiStacksStackIdMembersGet.id)
    // Positive control: expanding really did read the membership.
    #expect(afterExpansion == 1)
    #expect(store.sceneMembers[5]?.map(\.id) == [501, 502, 503])

    await store.loadInlinePicksIfNeeded(stackID: 5)

    #expect(store.sceneInlinePicks[5] == nil)
    #expect(
      await transport.callCount(Operations.ListStackMembersApiStacksStackIdMembersGet.id)
        == afterExpansion)
  }

  /// The card summary describes state a WRITE can change, and until this test it was read once
  /// and kept forever: open a scene, judge a member, close it again, and the card went on drawing
  /// the picks it held before the reader touched anything — including a scene whose last pick had
  /// just been taken away. Both directions are exercised, because a strip that only ever grows is
  /// the easier half.
  @Test("A mark inside a scene drops its card summary — a collapsed card never shows stale picks")
  func aWriteInvalidatesTheCardSummary() async {
    let members = Operations.ListStackMembersApiStacksStackIdMembersGet.id
    let (store, transport, preferences) = await loadedSceneStore()
    preferences.picksInGroups = true

    await store.loadInlinePicksIfNeeded(stackID: 5)
    #expect(store.sceneInlinePicks[5]?.map(\.id) == [501, 503])
    #expect(await transport.callCount(members) == 1)

    // Open it and pick the one member that was not picked — an ordinary write on an expanded
    // member, which is the only kind this scene can receive.
    await store.toggleSceneExpanded(5)
    #expect(await transport.callCount(members) == 2)
    await transport.setMarkStateOutcome(
      .success(
        .init(applied: 1, requested: 1, revisions: [.init(imageId: 502, revision: "m-2")])))
    #expect(await store.applyMark(.pick, to: [502]))

    // The server now holds three picks. Nothing about the client's cached summary knows that.
    await transport.setStackMemberPage(
      .init(
        items: [
          makeImage(id: 501, mark: .pick), makeImage(id: 502, mark: .pick),
          makeImage(id: 503, mark: .pick),
        ], limit: 100, nextCursor: nil, stackId: 5),
      forStack: 5)

    await store.toggleSceneExpanded(5)  // collapse — the card is the summary again
    await store.loadInlinePicksIfNeeded(stackID: 5)

    #expect(store.sceneInlinePicks[5]?.map(\.id) == [501, 502, 503])
    // The re-read is the point: a cache that survived the write would answer from memory.
    #expect(await transport.callCount(members) == 3)

    // The other direction: a member that STOPS being a pick has to leave the strip.
    await store.toggleSceneExpanded(5)  // members are still in hand, so this fetches nothing
    #expect(await transport.callCount(members) == 3)
    await transport.setMarkStateOutcome(
      .success(
        .init(applied: 1, requested: 1, revisions: [.init(imageId: 501, revision: "m-3")])))
    #expect(await store.applyMark(MarkStateValue.none, to: [501]))
    await transport.setStackMemberPage(
      .init(
        items: [
          makeImage(id: 501), makeImage(id: 502, mark: .pick), makeImage(id: 503, mark: .pick),
        ], limit: 100, nextCursor: nil, stackId: 5),
      forStack: 5)

    await store.toggleSceneExpanded(5)  // collapse
    await store.loadInlinePicksIfNeeded(stackID: 5)

    #expect(store.sceneInlinePicks[5]?.map(\.id) == [502, 503])
    #expect(await transport.callCount(members) == 4)
    // Still display-only after all of it: the write path touched nothing a gesture can reach.
    #expect(store.actionableImages.map(\.id) == [10])
  }

  @Test("A scope change drops the summaries with the window they described")
  func aScopeChangeDropsTheSummaries() async {
    let (store, transport, preferences) = await loadedSceneStore()
    preferences.picksInGroups = true
    await store.loadInlinePicksIfNeeded(stackID: 5)
    #expect(store.sceneInlinePicks[5]?.isEmpty == false)

    await store.selectShoot(folderID: 2)

    #expect(store.sceneInlinePicks.isEmpty)
    // Positive control: the transport is still the one that served the summary a moment ago.
    #expect(
      await transport.callCount(Operations.ListStackMembersApiStacksStackIdMembersGet.id) == 1)
  }
}
