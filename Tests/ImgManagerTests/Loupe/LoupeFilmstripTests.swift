import Foundation
import ImgManagerAPI
import SwiftUI
import Testing

@testable import ImgManager

/// Records every filmstrip `LoupeView.body` builds — and WHICH store it was handed — while still
/// returning a real view so the body under test evaluates normally. Same spy shape
/// `LoupeZoomControlsSpy` uses, and for the same reason: the phase's claim is about a call site
/// that exists only inside a `body`.
@MainActor
final class LoupeFilmstripSpy {
  private(set) var builtFor: [ObjectIdentifier] = []

  var surface: LoupeFilmstripSurface {
    LoupeFilmstripSurface { store in
      MainActor.assumeIsolated { self.builtFor.append(ObjectIdentifier(store)) }
      return AnyView(EmptyView())
    }
  }
}

/// Records every id the strip asked to bring into view.
@MainActor
final class FilmstripScrollSpy {
  private(set) var revealed: [Int] = []

  var scroller: FilmstripFocusScroller {
    FilmstripFocusScroller { _, id in
      MainActor.assumeIsolated { self.revealed.append(id) }
    }
  }
}

/// WP13 P9 (IMGMGR-218): the Compact loupe's thumb bar.
///
/// The phase ships no new component — it removes a layout-mode exclusion and makes the SAME strip
/// follow the focused frame. So these tests pin exactly three things: that `LoupeView.body`
/// reaches the strip at Compact, that the strip walks the shared actionable projection (never
/// `images`, never a collapsed card's cover), and that it pages through the ONE shared cursor.
@MainActor
@Suite("LoupeView — the Compact thumb bar, its projection and its one paging path")
struct LoupeFilmstripTests {

  // MARK: - Fixtures

  private func makeImage(
    id: Int, revision: String = "r0", captured: Date? = nil
  ) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.5, capturedAt: captured, ext: "raf", filename: "DSCF\(id).raf", folderId: 1,
      hasEdit: false, id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(revision: revision, state: .none, tags: []), missing: false,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func makeStore() -> (GridStore, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    return (GridStore(service: GridService(client: client)), transport)
  }

  /// A store holding its OWN `UserDefaults` suite — the advance-on-mark cadence is
  /// preference-driven and must neither read nor leave state in the simulator's shared domain.
  private func makeStoreWithOwnPreferences() -> (GridStore, GridStubTransport, GridPreferences) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let preferences = GridPreferences(defaults: makeEphemeralDefaults())
    return (
      GridStore(service: GridService(client: client), preferences: preferences), transport,
      preferences
    )
  }

  /// One flat shoot loaded, the loupe open on the first frame, the cadence explicitly on/off.
  private func loupeAtFirstOfThree(autoAdvance: Bool) async -> (GridStore, GridStubTransport) {
    let (store, transport, preferences) = makeStoreWithOwnPreferences()
    await transport.setListImagesPage(
      .init(items: (1...3).map { makeImage(id: $0) }, limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    store.openLoupe(on: 1)
    preferences.autoAdvanceOnMark = autoAdvance
    return (store, transport)
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

  /// A Scene page holding one loose photograph and one COLLAPSED scene. Cover id 900 appears
  /// nowhere else, so a strip row naming 900 can only have come from the card — which is the
  /// whole point of walking `actionableImages` rather than the rows.
  private func loadedSceneStore() async -> (GridStore, GridStubTransport) {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    let cover = makeImage(id: 900, revision: "cover-rev")
    await transport.setBrowseStacksPage(
      .init(
        items: [
          imageRow(makeImage(id: 10)),
          stackRowItem(
            Components.Schemas.StackBrowseStackRow(
              anchorTakenAt: Date(timeIntervalSince1970: 1_700_000_000), editedCount: 0,
              hasPick: false,
              kind: .stack, matchedCount: 2, memberCount: 2, pickedCount: 0,
              representative: cover, stackId: 5)),
        ], limit: 100, nextCursor: nil))
    await store.setDisplayMode(.scene)
    return (store, transport)
  }

  // MARK: - 1. The call site, and the projection behind it

  @Test("Compact renders the strip; in Scene mode it is the open scene's band alone")
  func compactRendersTheStripOverTheSameActionableProjection() async {
    // Half 1 — the call site. `LoupeView.body` at Compact builds the strip, over the SAME store
    // the loupe itself is showing (not a fresh one, which would page and focus independently).
    let (store, transport) = await loupeAtFirstOfThree(autoAdvance: false)
    let spy = LoupeFilmstripSpy()
    var compact = LoupeView(
      store: store, layoutMode: .compact, share: LoupeZoomFixtures.makeShare(transport))
    compact.filmstrip = spy.surface
    _ = compact.body
    #expect(spy.builtFor == [ObjectIdentifier(store)])

    // Positive control: the phase ADDS a layout mode, it does not move the strip out of the ones
    // that already had it — so the identical body at Regular-2 still builds exactly one strip.
    let regularSpy = LoupeFilmstripSpy()
    var regular = LoupeView(
      store: store, layoutMode: .regular2, share: LoupeZoomFixtures.makeShare(transport))
    regular.filmstrip = regularSpy.surface
    _ = regular.body
    #expect(regularSpy.builtFor == [ObjectIdentifier(store)])

    // Half 2 — the projection, and IMGMGR-406's scope over it. Scene mode is the only place
    // `images` and `actionableImages` disagree, and the only place the strip narrows at all.
    let (scene, sceneTransport) = await loadedSceneStore()
    #expect(scene.displayMode == .scene)
    #expect(scene.images.isEmpty)
    // The grid still shows the loose photograph 10 beside the collapsed card...
    #expect(scene.actionableImages.map(\.id) == [10])
    // ...but no scene is open, so there is no band for a strip to be (option (a)).
    let collapsed = FilmstripView(store: scene)
    #expect(collapsed.scope == .hidden)
    #expect(collapsed.frames.isEmpty)
    // ADR-0005 decision 4 still holds by construction: a collapsed card's cover is not a
    // photograph the reader can act on, so it is not a thumbnail either.
    #expect(collapsed.frames.contains(where: { $0.id == 900 }) == false)

    // Opening the scene and focusing a MEMBER: the strip is that scene, and only that scene.
    await sceneTransport.setStackMemberPage(
      .init(
        items: [
          makeImage(id: 501, captured: Date(timeIntervalSince1970: 1_700_000_000)),
          makeImage(id: 502, captured: Date(timeIntervalSince1970: 1_700_000_060)),
        ], limit: 100, nextCursor: nil, stackId: 5), forStack: 5)
    await scene.enterScene(5)
    scene.openLoupe(on: 501)
    let opened = FilmstripView(store: scene)
    // WP442 P12: the projection the grid walks inside the scene is the scene...
    #expect(scene.actionableImages.map(\.id) == [501, 502])
    // ...and so is the strip — never the loose photograph or the cover.
    #expect(opened.frames.map(\.id) == [501, 502])
    #expect(opened.frames.contains(where: { $0.id == 10 }) == false)
    #expect(opened.frames.contains(where: { $0.id == 900 }) == false)

    // And on the loose photograph itself (Back in the stream) there is no strip at all.
    scene.leaveScene()
    scene.openLoupe(on: 10)
    let loose = FilmstripView(store: scene)
    #expect(loose.scope == .hidden)
    #expect(loose.frames.isEmpty)
  }

  // MARK: - 2. Following P8's advance

  @Test("The strip follows the focused frame after an auto-advance")
  func theStripFollowsTheFocusedFrameAfterAnAutoAdvance() async {
    let (store, transport) = await loupeAtFirstOfThree(autoAdvance: true)
    await transport.setMarkStateOutcome(
      .success(.init(applied: 1, requested: 1, revisions: [.init(imageId: 1, revision: "r1")])))

    // Before the mark the strip sits on the frame being judged.
    #expect(FilmstripView(store: store).revealTarget == 1)

    // The REAL P8 path: a COMMITTED loupe mark, whose cadence moves the frame.
    let committed = await store.applyLoupeMark(.pick)
    #expect(committed)
    // Positive control: the advance actually happened. Without this the assertion below could
    // pass on a store that never moved.
    #expect(store.focusedImageID == 2)

    #expect(FilmstripView(store: store).revealTarget == 2)

    // ...and the seam really carries it — `reveal` is the one function `body`'s `onChange` calls.
    let spy = FilmstripScrollSpy()
    var scrolling = FilmstripView(store: store)
    scrolling.scroller = spy.scroller
    scrolling.reveal(scrolling.revealTarget, through: nil)
    #expect(spy.revealed == [2])

    // A focus the strip has no row for asks for nothing: `scrollTo` on an absent id would read
    // as a scroll that happened.
    store.focusedImageID = 999
    let absent = FilmstripView(store: store)
    #expect(absent.revealTarget == nil)
    scrolling.reveal(absent.revealTarget, through: nil)
    #expect(spy.revealed == [2])
  }

  // MARK: - 3. One paging path

  /// An absence assertion in the shape `theLoupeNeverRequestsAnythingButThePreviewTier` already
  /// uses in this repo: the positive control is the realness proof — the recorder is shown to
  /// have seen the grid's own page before anything is claimed about what it did NOT see.
  @Test("Neither the strip nor the loupe issues a page request of its own")
  func theStripNeverIssuesItsOwnPageRequest() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1), makeImage(id: 2)], limit: 100, nextCursor: "c1"))
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 3), makeImage(id: 4)], limit: 100, nextCursor: nil),
      forCursor: "c1")
    await store.selectShoot(folderID: 1)
    // IMGMGR-557: opening the folder asks `/api/browse/stacks` once (its scene probe); the claim
    // below is about the requests that follow the open.
    let stackCallsAtOpen = await transport.callCount(Operations.BrowseStacksApiBrowseStacksGet.id)

    let strip = FilmstripView(store: store)
    #expect(strip.frames.map(\.id) == [1, 2])

    // Drive the LOUPE's paging hook for every frame the reader can walk to — exactly what the
    // focus-driven trigger does as they step through them (IMGMGR-406 moved it off the strip's
    // rows; the store's three pagers behind it are unchanged). The loupe is OPEN: the hook asks
    // for nothing once `isLoupeOpen` is false, which is the round-5 close guard.
    store.openLoupe(on: 1)
    for image in strip.frames {
      store.loupeFocus(on: image.id)
      await LoupeView(
        store: store, layoutMode: .compact, share: LoupeZoomFixtures.makeShare(transport)
      ).pageIfNeeded()
    }

    let queries = await transport.recordedListImagesQueries
    // Positive control: the recorder saw real `/api/images` traffic, first page included.
    #expect(queries.count == 2)
    #expect(queries.first?["cursor"] == nil)
    // The claim: exactly ONE paged request, and it is the shared cursor's.
    #expect(queries.compactMap({ $0["cursor"] }) == ["c1"])
    // ...whose page landed in the SHARED array. That is what "one paging path" means: the strip
    // has no pool of its own to page into.
    #expect(store.images.map(\.id) == [1, 2, 3, 4])
    #expect(store.nextCursor == nil)

    // Driving the hook again across the now-longer strip adds nothing — the shared cursor is
    // spent, and the strip has no second one to fall back on.
    let grown = FilmstripView(store: store)
    #expect(grown.frames.map(\.id) == [1, 2, 3, 4])
    for image in grown.frames {
      store.loupeFocus(on: image.id)
      await LoupeView(
        store: store, layoutMode: .compact, share: LoupeZoomFixtures.makeShare(transport)
      ).pageIfNeeded()
    }
    let listCalls = await transport.callCount(Operations.ListImagesApiImagesGet.id)
    #expect(listCalls == 2)

    // And no OTHER cursor-bearing endpoint was touched: a filmstrip-local page would have to
    // come from somewhere.
    let stackCalls = await transport.callCount(Operations.BrowseStacksApiBrowseStacksGet.id)
    let neighbourCalls = await transport.callCount(
      Operations.ImageNeighboursApiImagesImageIdNeighboursGet.id)
    #expect(stackCalls == stackCallsAtOpen)
    #expect(neighbourCalls == 0)
  }

  // MARK: - 4. The same one paging path, in Scene mode (IMGMGR-267)

  /// The strip walks PHOTOGRAPHS; the grid walks DISPLAY ROWS. In Scene mode those two sequences
  /// have different tails — a stream ending in a collapsed card ends, for the strip, at the last
  /// member before it — so a strip that only ever named the display tail could never extend the
  /// pool at all. This is that case, deliberately: the last display row IS a card, and after
  /// IMGMGR-406 the strip's own last frame is the open scene's last member.
  @Test("In Scene mode the strip extends the pool through the ONE scene pager")
  func theStripPagesTheSceneStreamThroughTheOnePager() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    // IMGMGR-557: opening the folder asks `/api/browse/stacks` once (its scene probe); the claim
    // below is about the requests that follow the open.
    let probesAtOpen = await transport.recordedBrowseStacksQueries.count
    func card(_ stackID: Int) -> Components.Schemas.StackBrowseStackRow {
      Components.Schemas.StackBrowseStackRow(
        anchorTakenAt: Date(timeIntervalSince1970: 1_700_000_000), editedCount: 0, hasPick: false,
        kind: .stack,
        matchedCount: 2, memberCount: 2, pickedCount: 0,
        representative: makeImage(id: 900, revision: "cover-rev"), stackId: stackID)
    }
    await transport.setBrowseStacksPage(
      .init(
        items: [imageRow(makeImage(id: 10)), stackRowItem(card(5)), stackRowItem(card(6))],
        limit: 100, nextCursor: "scene-2"))
    await transport.setBrowseStacksPage(
      .init(items: [imageRow(makeImage(id: 11))], limit: 100, nextCursor: nil),
      forCursor: "scene-2")
    await transport.setStackMemberPage(
      .init(
        items: [
          makeImage(id: 501, captured: Date(timeIntervalSince1970: 1_700_000_000)),
          makeImage(id: 502, captured: Date(timeIntervalSince1970: 1_700_000_060)),
        ], limit: 100, nextCursor: nil, stackId: 5), forStack: 5)
    await store.setDisplayMode(.scene)
    await store.enterScene(5)
    store.openLoupe(on: 501)

    let strip = FilmstripView(store: store)
    // The premise this test rests on: the two tails really do disagree.
    #expect(strip.frames.map(\.id) == [501, 502])
    #expect(store.sceneDisplayRows.last?.id == .stack(6))

    for image in strip.frames {
      store.loupeFocus(on: image.id)
      await LoupeView(
        store: store, layoutMode: .compact, share: LoupeZoomFixtures.makeShare(transport)
      ).pageIfNeeded()
    }

    #expect(
      store.sceneRows.map(\.displayID) == [.image(10), .stack(5), .stack(6), .image(11)])
    #expect(store.sceneNextCursor == nil)
    let queries = Array(await transport.recordedBrowseStacksQueries.dropFirst(probesAtOpen))
    // Positive control: the recorder saw the FIRST page too, so a zero-cursor claim below is
    // about what the strip did, not about a recorder that never ran.
    #expect(queries.count == 2)
    #expect(queries.first?["cursor"] == nil)
    // The claim: exactly ONE paged request, through the scene cursor — no second pager.
    #expect(queries.compactMap({ $0["cursor"] }) == ["scene-2"])
    // And the flat pool is untouched: Scene mode's photographs never land in `images`.
    #expect(store.images.isEmpty)
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 1)
  }

  // MARK: - 5. ONE trigger, on the focused photograph (IMGMGR-406)

  /// The trigger moved off the strip's rows for a reason the strip cannot fix: under option (a)
  /// there IS no strip on a loose photograph in Scene mode, and the loupe's own forward
  /// prefetch is flat-only — so a walk toward the tail of the loaded window used to page and now
  /// would simply stop. This is that case, on the real store: it pins that the loupe's hook
  /// reaches the scene pager with no strip on screen. It calls the hook directly, so it does not
  /// (and cannot, headlessly) prove the `onChange` that drives it — see the ledger's round-2 note.
  @Test("A loose photograph in Scene mode has no strip and still pages the scene stream")
  func theLoupePagesTheSceneStreamWithNoStripOnScreen() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    // IMGMGR-557: opening the folder asks `/api/browse/stacks` once (its scene probe); the claim
    // below is about the requests that follow the open.
    let probesAtOpen = await transport.recordedBrowseStacksQueries.count
    let card = Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: Date(timeIntervalSince1970: 1_700_000_000), editedCount: 0, hasPick: false,
      kind: .stack, matchedCount: 2, memberCount: 2, pickedCount: 0,
      representative: makeImage(id: 900, revision: "cover-rev"), stackId: 5)
    await transport.setBrowseStacksPage(
      .init(
        items: [stackRowItem(card), imageRow(makeImage(id: 10))], limit: 100,
        nextCursor: "scene-2"))
    await transport.setBrowseStacksPage(
      .init(items: [imageRow(makeImage(id: 11))], limit: 100, nextCursor: nil),
      forCursor: "scene-2")
    await store.setDisplayMode(.scene)
    store.openLoupe(on: 10)

    // The premise: this photograph is loose, no scene is open, and there is no strip at all —
    // so nothing on screen carries a per-thumbnail `.task` to page from.
    #expect(FilmstripScope.resolve(for: store) == .hidden)
    #expect(FilmstripView(store: store).frames.isEmpty)

    let loupe = LoupeView(
      store: store, layoutMode: .compact, share: LoupeZoomFixtures.makeShare(transport))
    await loupe.pageIfNeeded()

    let queries = Array(await transport.recordedBrowseStacksQueries.dropFirst(probesAtOpen))
    // Positive control: the recorder saw the first page, so the cursor claim below is about what
    // the loupe asked for and not about a recorder that never ran.
    #expect(queries.count == 2)
    #expect(queries.first?["cursor"] == nil)
    #expect(queries.compactMap({ $0["cursor"] }) == ["scene-2"])
    #expect(store.sceneRows.map(\.displayID) == [.stack(5), .image(10), .image(11)])
  }

  /// What this proves is the STORE's dedup, not the trigger: it calls `pageIfNeeded()` by hand,
  /// so it would stay green if the `onChange` that drives it were deleted (the lifecycle claim is
  /// a UI-test question — see the ledger's round-2 note). What it does pin is that one ask per
  /// focus is enough and a repeated ask on the SAME focus costs nothing: the membership pager
  /// answers once for a band however many thumbnails are drawn, where the pre-IMGMGR-406 strip
  /// asked once per rendered thumbnail.
  @Test("A repeated ask on the same focused photograph adds no request (the store's own dedup)")
  func aRepeatedAskOnTheSameFocusAddsNoRequest() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    let card = Components.Schemas.StackBrowseStackRow(
      anchorTakenAt: Date(timeIntervalSince1970: 1_700_000_000), editedCount: 0, hasPick: false,
      kind: .stack, matchedCount: 3, memberCount: 3, pickedCount: 0,
      representative: makeImage(id: 900, revision: "cover-rev"), stackId: 5)
    await transport.setBrowseStacksPage(
      .init(items: [stackRowItem(card)], limit: 100, nextCursor: nil))
    await transport.setStackMemberPage(
      .init(
        items: [makeImage(id: 501), makeImage(id: 502)], limit: 100, nextCursor: "mem-2",
        stackId: 5), forStack: 5)
    await transport.setStackMemberPage(
      .init(items: [makeImage(id: 503)], limit: 100, nextCursor: nil, stackId: 5),
      forCursor: "mem-2")
    await store.setDisplayMode(.scene)
    await store.enterScene(5)
    store.openLoupe(on: 502)

    let loupe = LoupeView(
      store: store, layoutMode: .compact, share: LoupeZoomFixtures.makeShare(transport))
    // The premise: the strip is drawing two thumbnails right now. Before IMGMGR-406 each of them
    // carried its own `.task`, so this frame would have asked twice.
    #expect(FilmstripView(store: store).frames.map(\.id) == [501, 502])
    let afterExpansion = await transport.callCount(
      Operations.ListStackMembersApiStacksStackIdMembersGet.id)
    // Positive control: opening the scene really did fetch page one.
    #expect(afterExpansion == 1)

    await loupe.pageIfNeeded()

    #expect(store.sceneMembers[5]?.map(\.id) == [501, 502, 503])
    #expect(
      await transport.callCount(Operations.ListStackMembersApiStacksStackIdMembersGet.id) == 2)

    // The same focus asks for nothing more: 502 is no longer the loaded tail of that band, and
    // the membership cursor behind it is spent. The loupe has no second one to fall back on.
    await loupe.pageIfNeeded()
    #expect(
      await transport.callCount(Operations.ListStackMembersApiStacksStackIdMembersGet.id) == 2)
  }

  // MARK: - 6. The paging Task outlives the loupe, but its NEXT ask does not (Codex round 4)

  /// The trigger is an unstructured `Task` so a focus change cannot cancel a page in flight —
  /// which also means the continuation after an `await` survives `closeLoupe()`. Without the
  /// lifetime guard it would then start the NEXT pager's request for a loupe that is gone.
  ///
  /// Driven through the stub's own hold seam (`holdStackMembersRequests`), so the loupe is
  /// genuinely suspended INSIDE the second pager when it is stopped — not after a sleep and a
  /// hope. The third pager (the scene stream) is the observable one: the fixture leaves a scene
  /// cursor unspent, so "was it asked" is a recorded query, not an inference.
  ///
  /// Both stops are exercised because they close different windows: `closeLoupe()` is synchronous
  /// on the main actor (round 5 — a completion landing before the view's own `onDisappear` runs
  /// still has to be stopped), the lifetime is the view's own end.
  @Test("A loupe stopped mid-flight asks no further pager, and nothing is cancelled")
  func endingTheLifetimeMidFlightStopsTheNextPager() async {
    for interruption in LoupePagingInterruption.allCases {
      let (store, transport) = makeStore()
      await transport.setListImagesPage(
        .init(items: [makeImage(id: 1)], limit: 100, nextCursor: nil))
      await store.selectShoot(folderID: 1)
      let card = Components.Schemas.StackBrowseStackRow(
        anchorTakenAt: Date(timeIntervalSince1970: 1_700_000_000), editedCount: 0, hasPick: false,
        kind: .stack, matchedCount: 3, memberCount: 3, pickedCount: 0,
        representative: makeImage(id: 900, revision: "cover-rev"), stackId: 5)
      await transport.setBrowseStacksPage(
        .init(items: [stackRowItem(card)], limit: 100, nextCursor: "scene-2"))
      await transport.setBrowseStacksPage(
        .init(items: [imageRow(makeImage(id: 11))], limit: 100, nextCursor: nil),
        forCursor: "scene-2")
      await transport.setStackMemberPage(
        .init(
          items: [makeImage(id: 501), makeImage(id: 502)], limit: 100, nextCursor: "mem-2",
          stackId: 5), forStack: 5)
      // The second membership page comes back EMPTY — the scene ended exactly on the page
      // boundary. That keeps 502 the band's last member, so the third pager's question ("is this
      // the window's tail?") still answers yes after the second pager's request lands, and the
      // two branches below differ in the lifetime alone.
      await transport.setStackMemberPage(
        .init(items: [], limit: 100, nextCursor: nil, stackId: 5), forCursor: "mem-2")
      await store.setDisplayMode(.scene)
      await store.enterScene(5)
      store.openLoupe(on: 502)
      #expect(store.sceneMemberCursors[5] == .more("mem-2"))

      let lifetime = LoupePagingLifetime()
      let loupe = LoupeView(
        store: store, layoutMode: .compact, share: LoupeZoomFixtures.makeShare(transport),
        pagingLifetime: lifetime)

      // Suspend the run INSIDE the membership pager, exactly where a close can land.
      await transport.holdStackMembersRequests(true)
      let paging = Task { await loupe.pageIfNeeded() }
      await transport.waitUntilStackMembersStarted()
      switch interruption {
      case .none: break
      case .lifetimeEnded: lifetime.end()
      case .loupeClosed: store.closeLoupe()
      }
      await transport.releaseStackMembers()
      await paging.value
      await transport.holdStackMembersRequests(false)

      // The in-flight request is NEVER torn down: it completes and is applied (the cursor moves
      // to `.exhausted`), and no error is recorded — the whole point of not using a cancellable
      // `.task(id:)`. This holds in BOTH branches, which is what "no cancellation" means.
      #expect(store.sceneMemberCursors[5] == .exhausted)
      #expect(store.sceneMembers[5]?.map(\.id) == [501, 502])
      #expect(store.lastPageLoadError == nil)

      let cursors = await transport.recordedBrowseStacksQueries.compactMap { $0["cursor"] }
      switch interruption {
      case .none:
        // Control, same fixture and same seam: with the loupe still open the third pager runs.
        #expect(cursors == ["scene-2"])
        #expect(store.sceneRows.map(\.displayID) == [.stack(5), .image(11)])
      case .lifetimeEnded, .loupeClosed:
        // The ask AFTER the stop never happens, whichever way the loupe went away.
        #expect(cursors.isEmpty, "\(interruption) still let the next pager run")
        #expect(store.sceneRows.map(\.displayID) == [.stack(5)])
      }
    }
  }
}

/// IMGMGR-268: the strip's thumbnails became real controls, so what they ANNOUNCE is now a
/// contract rather than an accident of whatever SwiftUI derived from an image.
@Suite("Filmstrip thumbnail accessibility — a control has to name what it activates")
struct FilmstripThumbnailAccessibilityTests {

  private func image(
    id: Int, state: Components.Schemas.MarkView.StatePayload
  ) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.5, ext: "raf", filename: "DSCF\(id).raf", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: state, tags: []), missing: false,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  @Test("An unmarked thumbnail announces the photograph; a marked one announces its verdict too")
  func theLabelNamesThePhotographAndItsVerdict() {
    let none = Components.Schemas.MarkView.StatePayload.none
    #expect(
      FilmstripThumbnailAccessibility.label(for: image(id: 1, state: none)) == "DSCF1.raf")
    #expect(
      FilmstripThumbnailAccessibility.label(for: image(id: 2, state: .pick))
        == "DSCF2.raf, picked")
    #expect(
      FilmstripThumbnailAccessibility.label(for: image(id: 3, state: .dislike))
        == "DSCF3.raf, disliked")
  }
}

/// IMGMGR-406 (owner decision 2026-09-05, option (a), iPad and iPhone alike): inside a scene the
/// loupe's strip is THAT SCENE's members; on a loose photograph there is no strip at all and the
/// main image takes the height. Flat browse keeps the whole sequence.
///
/// The rule is a pure value (`FilmstripScope`), so most of this suite needs neither a store nor a
/// view; the two that do use the real store and the real `LoupeView.body`, because "no frames" and
/// "no strip in the layout" are two different claims and the owner decision makes both.
/// The three ways a paging run can end while it is suspended inside one of the store's pagers:
/// not at all, the view's own lifetime ending, or the reader closing the loupe.
private enum LoupePagingInterruption: CaseIterable {
  case none
  case lifetimeEnded
  case loupeClosed
}

@MainActor
@Suite("Filmstrip scope — the strip is the scene being culled, or it is not drawn")
struct FilmstripScopeTests {

  private func image(_ id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.5, ext: "raf", filename: "DSCF\(id).raf", folderId: 1, hasEdit: false, id: id,
      lightroom: .init(sidecarPresent: false), mark: .init(revision: "r0", state: .none, tags: []),
      missing: false, proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  // MARK: - The pure rule

  @Test("Flat browse is the whole sequence, whatever the scene state says")
  func flatBrowseIsTheWholeSequence() {
    let sequence = [image(1), image(2), image(3)]
    let scope = FilmstripScope.resolve(
      displayMode: .flat, focusedImageID: 2, openSceneMembers: nil, actionableImages: sequence)
    #expect(scope == .sequence(sequence))
    #expect(scope.frames.map(\.id) == [1, 2, 3])
    #expect(scope.isRendered)

    // A membership answer cannot narrow FLAT browse — there are no scenes there to be inside of,
    // and a stray band must never shorten the sequence the reader is walking.
    let withBand = FilmstripScope.resolve(
      displayMode: .flat, focusedImageID: 2, openSceneMembers: [image(2)],
      actionableImages: sequence)
    #expect(withBand.frames.map(\.id) == [1, 2, 3])
  }

  @Test("Inside an open scene the strip is that scene's band, in display order")
  func insideASceneTheStripIsTheBand() {
    let band = [image(501), image(502), image(503)]
    let scope = FilmstripScope.resolve(
      displayMode: .scene, focusedImageID: 502, openSceneMembers: band,
      actionableImages: [image(10)] + band + [image(11)])
    #expect(scope == .members(band))
    #expect(scope.frames.map(\.id) == [501, 502, 503])
    // The discriminating half: the loose photographs the grid still shows are NOT in the strip.
    #expect(scope.frames.contains(where: { $0.id == 10 }) == false)
    #expect(scope.frames.contains(where: { $0.id == 11 }) == false)
    #expect(scope.isRendered)
  }

  @Test("On a loose photograph there is no strip — and none for an unopened or empty scene")
  func onALoosePhotographThereIsNoStrip() {
    let sequence = [image(10), image(11)]
    let loose = FilmstripScope.resolve(
      displayMode: .scene, focusedImageID: 10, openSceneMembers: nil,
      actionableImages: sequence)
    #expect(loose == .hidden)
    #expect(loose.frames.isEmpty)
    #expect(loose.isRendered == false)

    // Nothing focused answers the same way: there is no scene to show.
    #expect(
      FilmstripScope.resolve(
        displayMode: .scene, focusedImageID: nil, openSceneMembers: nil,
        actionableImages: sequence) == .hidden)

    // A scene whose membership has not arrived yet draws no empty bar either.
    #expect(
      FilmstripScope.resolve(
        displayMode: .scene, focusedImageID: 501, openSceneMembers: [],
        actionableImages: sequence) == .hidden)
  }

  @Test("A CLOSED scene's cached members are not a band")
  func aClosedScenesCachedMembersAreNotABand() {
    let band = [image(501), image(502)]
    // `GridStore.leaveScene` keeps a left scene's members in hand on purpose (they are not
    // re-fetched on re-entry), so the fence that matters is `expanded`, not `members`.
    #expect(
      SceneRowBuilder.openSceneMembers(containing: 501, expanded: [], members: [5: band]) == nil)
    // Positive control: the same state with the scene OPEN answers with the band.
    #expect(
      SceneRowBuilder.openSceneMembers(containing: 501, expanded: [5], members: [5: band])?
        .map(\.id) == [501, 502])
    // A photograph in no band at all is loose.
    #expect(
      SceneRowBuilder.openSceneMembers(containing: 10, expanded: [5], members: [5: band]) == nil)
  }

  // MARK: - Over the real store: focus moves flip the scope, with no stale frames

  /// One loose photograph, one scene of two members, both loaded — the store fixture the shipped
  /// Scene-mode paths use.
  private func openedSceneStore() async -> GridStore {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let store = GridStore(service: GridService(client: client))
    await transport.setListImagesPage(
      .init(items: [image(1)], limit: 100, nextCursor: nil))
    await store.selectShoot(folderID: 1)
    await transport.setBrowseStacksPage(
      .init(
        items: [
          .init(value1: .init(image: image(10), kind: .image), value2: nil),
          .init(
            value1: nil,
            value2: Components.Schemas.StackBrowseStackRow(
              anchorTakenAt: Date(timeIntervalSince1970: 1_700_000_000), editedCount: 0,
              hasPick: false, kind: .stack, matchedCount: 2, memberCount: 2, pickedCount: 0,
              representative: image(900), stackId: 5)),
        ], limit: 100, nextCursor: nil))
    await transport.setStackMemberPage(
      .init(items: [image(501), image(502)], limit: 100, nextCursor: nil, stackId: 5), forStack: 5)
    await store.setDisplayMode(.scene)
    await store.enterScene(5)
    return store
  }

  @Test("Focus member -> loose -> member gives band, no strip, band again")
  func focusMovesFlipTheScopeWithNoStaleFrames() async {
    let store = await openedSceneStore()
    // Premise: the grid's own projection (WP442 P12: the entered scene) holds the same members
    // the whole way through, so every change below is the STRIP's scope moving and nothing else.
    #expect(store.actionableImages.map(\.id) == [501, 502])

    store.openLoupe(on: 501)
    #expect(FilmstripScope.resolve(for: store).frames.map(\.id) == [501, 502])

    store.loupeFocus(on: 10)
    #expect(FilmstripScope.resolve(for: store) == .hidden)
    #expect(FilmstripView(store: store).frames.isEmpty)

    store.loupeFocus(on: 502)
    #expect(FilmstripScope.resolve(for: store).frames.map(\.id) == [501, 502])

    // Leaving the scene takes the band away with it — the store drops focus on a photograph
    // nobody can see, and the strip has nothing left to be.
    store.leaveScene()
    #expect(store.focusedImageID == nil)
    #expect(FilmstripScope.resolve(for: store) == .hidden)
  }

  @Test("LoupeView builds no strip on a loose photograph, in either size class")
  func loupeViewBuildsNoStripOnALoosePhotograph() async {
    let store = await openedSceneStore()
    let share = ShareExportStore(
      service: GridService(client: ImgManagerAPIClient.make(transport: GridStubTransport())))

    for layout in [LayoutMode.compact, .regular3] {
      store.openLoupe(on: 10)
      let looseSpy = LoupeFilmstripSpy()
      var loose = LoupeView(store: store, layoutMode: layout, share: share)
      loose.filmstrip = looseSpy.surface
      _ = loose.body
      #expect(looseSpy.builtFor.isEmpty, "A loose photograph must leave no strip in the stack.")

      // Positive control on the SAME store and the SAME layout: a member still gets one, so the
      // assertion above is about the photograph in the loupe and not about a body that stopped
      // building strips altogether.
      store.loupeFocus(on: 501)
      let memberSpy = LoupeFilmstripSpy()
      var member = LoupeView(store: store, layoutMode: layout, share: share)
      member.filmstrip = memberSpy.surface
      _ = member.body
      #expect(memberSpy.builtFor == [ObjectIdentifier(store)])
    }
  }
}
