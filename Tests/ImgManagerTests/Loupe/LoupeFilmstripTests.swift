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
              anchorTakenAt: Date(timeIntervalSince1970: 1_700_000_000), hasPick: false,
              kind: .stack, matchedCount: 2, memberCount: 2, pickedCount: 0,
              representative: cover, stackId: 5)),
        ], limit: 100, nextCursor: nil))
    await store.setDisplayMode(.scene)
    return (store, transport)
  }

  // MARK: - 1. The call site, and the projection behind it

  @Test("Compact renders the strip, over the same actionable projection")
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

    // Half 2 — the projection. Scene mode is the only place `images` and `actionableImages`
    // disagree, so it is the only place this assertion can be anything but a tautology.
    let (scene, sceneTransport) = await loadedSceneStore()
    let collapsed = FilmstripView(store: scene)
    #expect(scene.displayMode == .scene)
    #expect(scene.images.isEmpty)
    #expect(scene.actionableImages.map(\.id) == [10])
    #expect(collapsed.frames.map(\.id) == scene.actionableImages.map(\.id))
    // ...and the two really do disagree here, so the line above is a discriminating claim.
    #expect(collapsed.frames.map(\.id) != scene.images.map(\.id))
    // ADR-0005 decision 4: a collapsed card's cover is not a photograph the reader can act on,
    // so it is not a thumbnail either.
    #expect(collapsed.frames.contains(where: { $0.id == 900 }) == false)

    // Opening the scene splices its members in — the same rule, the other direction.
    await sceneTransport.setStackMemberPage(
      .init(
        items: [
          makeImage(id: 501, captured: Date(timeIntervalSince1970: 1_700_000_000)),
          makeImage(id: 502, captured: Date(timeIntervalSince1970: 1_700_000_060)),
        ], limit: 100, nextCursor: nil, stackId: 5), forStack: 5)
    await scene.toggleSceneExpanded(5)
    let opened = FilmstripView(store: scene)
    #expect(scene.actionableImages.map(\.id) == [10, 501, 502])
    #expect(opened.frames.map(\.id) == scene.actionableImages.map(\.id))
    #expect(opened.frames.contains(where: { $0.id == 900 }) == false)
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
  @Test("The strip never issues its own page request")
  func theStripNeverIssuesItsOwnPageRequest() async {
    let (store, transport) = makeStore()
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 1), makeImage(id: 2)], limit: 100, nextCursor: "c1"))
    await transport.setListImagesPage(
      .init(items: [makeImage(id: 3), makeImage(id: 4)], limit: 100, nextCursor: nil),
      forCursor: "c1")
    await store.selectShoot(folderID: 1)

    let strip = FilmstripView(store: store)
    #expect(strip.frames.map(\.id) == [1, 2])

    // Drive the strip's paging hook for EVERY frame it renders — exactly what each row's own
    // `.task` does when the strip scrolls past it.
    for image in strip.frames { await strip.pageIfNeeded(around: image) }

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
    for image in grown.frames { await grown.pageIfNeeded(around: image) }
    let listCalls = await transport.callCount(Operations.ListImagesApiImagesGet.id)
    #expect(listCalls == 2)

    // And no OTHER cursor-bearing endpoint was touched: a filmstrip-local page would have to
    // come from somewhere.
    let stackCalls = await transport.callCount(Operations.BrowseStacksApiBrowseStacksGet.id)
    let neighbourCalls = await transport.callCount(
      Operations.ImageNeighboursApiImagesImageIdNeighboursGet.id)
    #expect(stackCalls == 0)
    #expect(neighbourCalls == 0)
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
