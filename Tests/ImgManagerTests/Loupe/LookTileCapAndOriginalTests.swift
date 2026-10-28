import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// Polls `condition` on the main actor, giving the transport actor time to move, for at most
/// about five seconds.
@MainActor
private func settle(_ condition: () -> Bool) async {
  var tries = 0
  while !condition(), tries < 1_000 {
    try? await Task.sleep(for: .milliseconds(5))
    tries += 1
  }
}

/// The path of a recorded request, without its query.
private func route(_ path: String?) -> String {
  path.flatMap { URLComponents(string: $0)?.path } ?? ""
}

/// IMGMGR-650 (b): a pending strip tile shows the photograph's unlooked grid tile, and at most
/// four looked tile renders are on the wire at once.
@Suite("Looks strip placeholder and in-flight cap (IMGMGR-650)")
@MainActor
struct LookTileCapTests {

  /// Twelve looked tile renders asked at once, held at the wire.
  static func twelvePending(
    _ store: GridStore, _ transport: GridStubTransport
  ) async -> [Task<Data?, Never>] {
    await transport.holdEveryLookedProxyRequest(true)
    let renders = (0..<12).map { index in
      Task { await store.lookTile(imageID: 1, lookID: "look-\(index)", identityToken: nil) }
    }
    await transport.waitUntilLookedProxiesHeld(4)
    await settle { store.lookTileSlots.waitingCount == 8 }
    return renders
  }

  @Test("A pending tile's placeholder is the photograph's unlooked grid tile, None's bytes")
  func placeholderIsTheUnlookedGridTile() async throws {
    let (store, transport) = await LookStripTests.storeWithStrip()
    await transport.holdEveryLookedProxyRequest(true)
    let pending = Task {
      await store.lookTile(imageID: 1, lookID: "classic-mono", identityToken: nil)
    }
    await transport.waitUntilLookedProxiesHeld(1)

    let placeholder = try #require(
      await store.lookTilePlaceholder(imageID: 1, identityToken: nil))
    #expect(route(await transport.recordedProxyRequests.last).hasSuffix("/api/images/1/proxy/grid"))
    let none = await store.lookTile(imageID: 1, lookID: nil, identityToken: nil)
    #expect(placeholder == none)
    #expect(placeholder == LookFixtures.unlookedBytes)
    #expect(placeholder != LookFixtures.lookedBytes)
    // The placeholder asked for no look, and answered while the render was still held.
    #expect(await transport.recordedLookedProxyRequests.count == 1)
    #expect(await transport.heldLookedProxyCount == 1)

    await transport.releaseOneLookedProxy()
    #expect(await pending.value == LookFixtures.lookedBytes)
    // A strip that is gone has no placeholder either.
    store.looks.cancel()
    #expect(await store.lookTilePlaceholder(imageID: 1, identityToken: nil) == nil)
  }

  @Test("Twelve pending renders: at most four in flight, the rest start as slots free")
  func twelvePendingAtMostFourInFlight() async {
    let (store, transport) = await LookStripTests.storeWithStrip()
    let renders = await Self.twelvePending(store, transport)
    #expect(await transport.lookedProxyInFlight == 4)
    #expect(await transport.recordedLookedProxyRequests.count == 4)
    #expect(store.lookTileSlots.inFlight == 4)
    #expect(store.lookTileSlots.waitingCount == 8)

    // Each answer starts exactly one waiting render, never more.
    for remaining in stride(from: 7, through: 0, by: -1) {
      await transport.releaseOneLookedProxy()
      await transport.waitUntilLookedProxiesHeld(4)
      await settle { store.lookTileSlots.waitingCount == remaining }
      #expect(await transport.lookedProxyInFlight == 4)
      #expect(store.lookTileSlots.waitingCount == remaining)
    }
    for _ in 0..<4 { await transport.releaseOneLookedProxy() }
    for render in renders {
      #expect(await render.value == LookFixtures.lookedBytes)
    }
    #expect(await transport.lookedProxyPeakInFlight == 4)
    #expect(await transport.recordedLookedProxyRequests.count == 12)
    #expect(store.lookTileSlots.inFlight == 0)
  }

  @Test("Closing the strip frees every slot: waiters ask nothing, the next strip is served")
  func closingTheStripFreesEverySlot() async {
    let (store, transport) = await LookStripTests.storeWithStrip()
    let renders = await Self.twelvePending(store, transport)
    store.looks.cancel()
    for _ in 0..<4 { await transport.releaseOneLookedProxy() }
    for render in renders {
      #expect(await render.value == nil)
    }
    #expect(await transport.recordedLookedProxyRequests.count == 4)
    #expect(store.lookTileSlots.inFlight == 0)
    #expect(store.lookTileSlots.waitingCount == 0)

    await transport.holdEveryLookedProxyRequest(false)
    store.looks.openStrip(imageID: 1)
    let next = await store.lookTile(imageID: 1, lookID: "warm-film", identityToken: nil)
    #expect(next == LookFixtures.lookedBytes)
    #expect(await transport.recordedLookedProxyRequests.count == 5)
  }

  @Test("Cancelled renders leave the queue at once and hold no slot")
  func cancelledRendersHoldNoSlot() async {
    let (store, transport) = await LookStripTests.storeWithStrip()
    let renders = await Self.twelvePending(store, transport)
    for render in renders { render.cancel() }
    await settle { store.lookTileSlots.waitingCount == 0 }
    #expect(store.lookTileSlots.waitingCount == 0)
    #expect(store.lookTileSlots.inFlight == 4)
    for _ in 0..<4 { await transport.releaseOneLookedProxy() }
    for render in renders {
      #expect(await render.value == nil)
    }
    #expect(await transport.recordedLookedProxyRequests.count == 4)
    #expect(store.lookTileSlots.inFlight == 0)

    await transport.holdEveryLookedProxyRequest(false)
    let next = await store.lookTile(imageID: 1, lookID: "warm-film", identityToken: nil)
    #expect(next == LookFixtures.lookedBytes)
  }
}

/// IMGMGR-650 (c): hold-to-original — press-and-hold on the image, or `\` held on a hardware
/// keyboard, shows the unlooked preview labelled "Original" while held, and never sticks.
@Suite("Hold to original (IMGMGR-650)")
@MainActor
struct HoldToOriginalTests {

  /// Every way a hold can end without its own release, plus the release itself.
  enum Exit: String, CaseIterable, Sendable {
    case release
    case stripCancel
    case escape
    case loupeCloses
    case photographChanges
    case leavesForeground
  }

  @Test("Press-and-hold: showOriginal is true while held, false on release")
  func pressAndHold() async {
    let (store, transport) = await LookStripTests.storeWithStrip()
    #expect(store.looks.showOriginal == false)
    store.holdOriginal(.touch, isHeld: true)
    #expect(store.looks.showOriginal)
    store.holdOriginal(.touch, isHeld: false)
    #expect(store.looks.showOriginal == false)
    // The draft is untouched and nothing was saved.
    #expect(store.looks.draft?.lookID == "warm-film")
    #expect(store.looks.draft?.strength == 100)
    #expect(await transport.recordedLookWrites.isEmpty)
  }

  @Test("\\ press and release, through the key monitor: showOriginal while held, not after")
  func backslashPressAndRelease() async {
    let (store, _) = await LookStripTests.storeWithStrip()
    let monitor = OriginalKeyMonitor(listensToKeyboard: false)
    let token = monitor.attach { pressed in store.holdOriginal(.key, isHeld: pressed) }
    monitor.deliver(isPressed: true)
    #expect(store.looks.showOriginal)
    monitor.deliver(isPressed: false)
    #expect(store.looks.showOriginal == false)
    #expect(store.looks.draft?.lookID == "warm-film")
    // A loupe that goes away while \ is held releases it.
    monitor.deliver(isPressed: true)
    monitor.detach(token)
    #expect(store.looks.showOriginal == false)
    #expect(monitor.ownerCount == 0)
  }

  @Test("Key monitor: attach A, attach B, detach B — B's hold is released, the key goes to A")
  func departingOwnerIsReleasedAndTheRemainingOwnerReceives() {
    let monitor = OriginalKeyMonitor(listensToKeyboard: false)
    var toA: [Bool] = []
    var toB: [Bool] = []
    let tokenA = monitor.attach { toA.append($0) }
    let tokenB = monitor.attach { toB.append($0) }
    monitor.deliver(isPressed: true)
    #expect(toB == [true])
    #expect(toA.isEmpty)

    monitor.detach(tokenB)
    #expect(toB == [true, false])
    monitor.deliver(isPressed: true)
    monitor.deliver(isPressed: false)
    #expect(toA == [true, false])
    #expect(toB == [true, false])

    monitor.detach(tokenA)
    #expect(monitor.ownerCount == 0)
    monitor.deliver(isPressed: true)
    #expect(toA == [true, false])
  }

  @Test("Key monitor: a release goes to the owner that got the press, not a newer one")
  func releaseGoesToThePressedOwner() {
    let monitor = OriginalKeyMonitor(listensToKeyboard: false)
    var toA: [Bool] = []
    var toB: [Bool] = []
    let tokenA = monitor.attach { toA.append($0) }
    monitor.deliver(isPressed: true)
    let tokenB = monitor.attach { toB.append($0) }
    monitor.deliver(isPressed: false)
    #expect(toA == [true, false])
    #expect(toB.isEmpty)
    // Detaching an owner that holds nothing sends it nothing.
    monitor.detach(tokenA)
    #expect(toA == [true, false])
    monitor.detach(tokenB)
    #expect(toB.isEmpty)
  }

  @Test("Finger and key together: the original shows until the last of them lets go")
  func bothHolds() async {
    let (store, _) = await LookStripTests.storeWithStrip()
    store.holdOriginal(.touch, isHeld: true)
    store.holdOriginal(.key, isHeld: true)
    store.holdOriginal(.key, isHeld: false)
    #expect(store.looks.showOriginal)
    store.holdOriginal(.touch, isHeld: false)
    #expect(store.looks.showOriginal == false)
  }

  @Test("No hold without the strip, or under a sheet over it")
  func holdNeedsTheStripToOwnTheLoupe() async {
    let (store, _, _) = await LookFixtures.loadedStore()
    await store.looks.loadCatalogueIfNeeded()
    store.holdOriginal(.touch, isHeld: true)
    store.holdOriginal(.key, isHeld: true)
    #expect(store.looks.showOriginal == false)

    store.looks.openStrip(imageID: 1)
    store.isTagEntryPresented = true
    store.holdOriginal(.key, isHeld: true)
    #expect(store.looks.showOriginal == false)
    store.isTagEntryPresented = false
    store.holdOriginal(.key, isHeld: true)
    #expect(store.looks.showOriginal)
  }

  @Test("Every way out ends the hold", arguments: Exit.allCases)
  func everyWayOutEndsTheHold(_ exit: Exit) async {
    let (store, _) = await LookStripTests.storeWithStrip()
    store.holdOriginal(.touch, isHeld: true)
    store.holdOriginal(.key, isHeld: true)
    #expect(store.looks.showOriginal)
    switch exit {
    case .release:
      store.holdOriginal(.touch, isHeld: false)
      store.holdOriginal(.key, isHeld: false)
    case .stripCancel: store.looks.cancel()
    case .escape: store.handleEscape()
    case .loupeCloses: store.closeLoupe()
    case .photographChanges: store.loupeFocus(on: 2)
    case .leavesForeground: store.looks.endOriginalHolds()
    }
    #expect(store.looks.showOriginal == false)
    // A strip opened afterwards starts with nothing held.
    store.openLoupe(on: store.focusedImageID ?? 1)
    store.looks.openStrip(imageID: store.focusedImageID ?? 1)
    #expect(store.looks.showOriginal == false)
  }

  @Test("The held original is the CURRENT photograph's unlooked preview, labelled Original")
  func originalIsTheUnlookedPreviewLabelledOriginal() async throws {
    let (store, transport) = await LookStripTests.storeWithStrip()
    let looked = await store.loupePreviewBytes(imageID: 1, identityToken: nil)
    #expect(looked.rendering == .looked(lookID: "warm-film"))
    let lookedRequests = await transport.recordedLookedProxyRequests.count

    let bytes = try #require(await store.originalPreview(imageID: 1, identityToken: nil))
    #expect(bytes == LookFixtures.unlookedBytes)
    #expect(
      route(await transport.recordedProxyRequests.last).hasSuffix("/api/images/1/proxy/preview"))
    #expect(await transport.recordedLookedProxyRequests.count == lookedRequests)

    let original = (imageID: 1, image: bytes)
    store.holdOriginal(.touch, isHeld: true)
    #expect(
      LoupeOriginal.shown(
        showOriginal: store.looks.showOriginal, focusedImageID: store.focusedImageID,
        original: original) == LookFixtures.unlookedBytes)
    #expect(LoupeOriginal.label == "Original")
    #expect(LoupeOriginal.identifier == "loupeOriginalLabel")
    // Never another photograph's bytes, and nothing once released.
    #expect(
      LoupeOriginal.shown(showOriginal: true, focusedImageID: 2, original: original) == nil)
    store.holdOriginal(.touch, isHeld: false)
    #expect(
      LoupeOriginal.shown(
        showOriginal: store.looks.showOriginal, focusedImageID: store.focusedImageID,
        original: original) == nil)
    // Holding changed neither the draft nor the loupe's look.
    #expect(store.loupeLook(forImageID: 1)?.lookID == "warm-film")
  }
}
