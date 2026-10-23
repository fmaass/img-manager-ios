import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

@Suite("HeroThumbnailLoader — cache, bounded concurrency, cancellation (Q6)")
struct HeroThumbnailLoaderTests {

  private func makeImage(id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.0, ext: "jpg", filename: "img\(id).jpg", folderId: 1, id: id,
      lightroom: .init(sidecarPresent: false), mark: .init(revision: "r0"),
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  /// Waits for a state the loader can actually be ASKED about, instead of sleeping and hoping.
  ///
  /// The cancellation tests below have to cancel a reader at one specific moment — after it has
  /// registered and its fetch is parked at the concurrency gate. A fixed sleep can land the
  /// cancellation before `hero`'s own preflight guard instead, where even a loader with no
  /// coalescing at all returns `.failure` with no network: the test would pass, and prove
  /// nothing. Returns whether the condition held before the deadline.
  private func waitUntil(
    within seconds: Double = 5, _ condition: () async -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if await condition() { return true }
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return false
  }

  private func makeLoader(maxConcurrent: Int) -> (HeroThumbnailLoader, GridStubTransport) {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    let service = GridService(client: client)
    return (HeroThumbnailLoader(service: service, maxConcurrent: maxConcurrent), transport)
  }

  @Test("Happy path: the two-step fetch (images then proxy) returns image bytes")
  func happyPath() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 1, nextCursor: nil))
    let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
    await transport.setProxyOutcome(.ok(bytes))

    let result = await loader.hero(folderID: 1, sourceTier: .local)
    #expect(result == .image(bytes))
  }

  @Test("A cached hero image is reused — no second network round trip")
  func cacheHit() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 1, nextCursor: nil))
    await transport.setProxyOutcome(.ok(Data([0xFF, 0xD8])))

    let first = await loader.hero(folderID: 1, sourceTier: .local)
    guard case .image = first else {
      Issue.record("expected .image, got \(first)")
      return
    }
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 1)
    #expect(await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 1)

    let second = await loader.hero(folderID: 1, sourceTier: .local)
    #expect(second == first)
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 1)  // unchanged
    #expect(await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 1)
  }

  @Test(".empty when the folder has no images at all")
  func emptyWhenNoImages() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    await transport.setListImagesPage(.init(items: [], limit: 1, nextCursor: nil))
    let result = await loader.hero(folderID: 1, sourceTier: nil)
    #expect(result == .empty)
  }

  @Test(".empty when the proxy 404s (existing empty placeholder path, never a crash)")
  func emptyWhenProxyNotFound() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 1, nextCursor: nil))
    await transport.setProxyOutcome(.notFound)
    let result = await loader.hero(folderID: 1, sourceTier: nil)
    #expect(result == .empty)
  }

  @Test(".failure when the images fetch is unreachable")
  func failureWhenUnreachable() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    await transport.setListImagesShouldFail(true)
    let result = await loader.hero(folderID: 1, sourceTier: nil)
    #expect(result == .failure)
  }

  @Test("A cancelled task never starts the network fetch")
  func cancellationSkipsNetwork() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    let task = Task {
      await loader.hero(folderID: 1, sourceTier: nil)
    }
    task.cancel()
    let result = await task.value
    #expect(result == .failure)
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 0)
  }

  @Test(
    "Single flight: two concurrent hero() calls for ONE key make one fetch and both get the image"
  )
  func concurrentCallsForOneKeyShareASingleFetch() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 1, nextCursor: nil))
    let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
    await transport.setProxyOutcome(.ok(bytes))
    await transport.holdNextListImagesRequest()

    let first = Task { await loader.hero(folderID: 1, sourceTier: .local) }
    await transport.waitUntilListImagesStarted()

    // The SAME key while the first fetch is suspended inside the transport — the shipped pair
    // this is about is the Queue card and the Folders-tree shoot row showing one shoot
    // (IMGMGR-332). The concurrency gate cannot be what stops the second fetch here: four slots,
    // one taken.
    let second = Task { await loader.hero(folderID: 1, sourceTier: .local) }
    // A real chance to start its own fetch: the transport's hold is single-slot and
    // self-disarming, so a second fetch would run straight through to a second call rather than
    // suspend beside the first.
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 1)

    await transport.releaseListImages()
    let firstResult = await first.value
    let secondResult = await second.value
    #expect(firstResult == .image(bytes))
    #expect(secondResult == .image(bytes))
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 1)
    #expect(await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 1)
  }

  @Test(
    "A SOLE reader cancelled while queued at the gate takes its fetch with it — no network, slot freed"
  )
  func soleReaderCancelledAtTheGateStartsNoNetwork() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 1)
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 1, nextCursor: nil))
    await transport.setProxyOutcome(.ok(Data([0xFF, 0xD8])))
    await transport.holdNextListImagesRequest()

    // Another key owns the single slot, so the reader below is parked in `acquire()` — the exact
    // position the shipped scroll-away hits.
    let blocker = Task { await loader.hero(folderID: 99, sourceTier: nil) }
    await transport.waitUntilListImagesStarted()

    let lone = Task { await loader.hero(folderID: 7, sourceTier: nil) }
    // DETERMINISTIC, not a sleep: cancel only once this reader has really registered its fetch
    // AND that fetch is really parked at the gate. Both are read off the loader itself.
    #expect(
      await waitUntil {
        let fetching = await loader.debugIsFetching(folderID: 7, sourceTier: nil)
        let queued = await loader.debugGateWaiterCount()
        return fetching && queued == 1
      }, "the lone reader's fetch never reached the concurrency gate")
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 1)

    lone.cancel()
    // Its departure is processed on the actor, so wait for the observable effect of it rather
    // than guessing at a delay: the abandoned fetch is dropped, entry and all.
    #expect(
      await waitUntil {
        await loader.debugIsFetching(folderID: 7, sourceTier: nil) == false
      }, "the abandoned fetch was still registered after its only reader was cancelled")

    await transport.releaseListImages()
    _ = await blocker.value
    #expect(await lone.value == .failure)
    // THE ASSERTION: the slot came free and the abandoned fetch did NOT use it. Without the
    // waiter count the shared task is still alive here and runs both of its network calls for a
    // reader that is gone.
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 1)
    #expect(await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 1)
  }

  @Test("One of TWO readers cancelling leaves the shared fetch intact for the other")
  func oneReaderLeavingDoesNotCancelTheSharedFetch() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 1, nextCursor: nil))
    let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
    await transport.setProxyOutcome(.ok(bytes))
    await transport.holdNextListImagesRequest()

    let leaver = Task { await loader.hero(folderID: 1, sourceTier: .local) }
    await transport.waitUntilListImagesStarted()
    let survivor = Task { await loader.hero(folderID: 1, sourceTier: .local) }
    // DETERMINISTIC, and on the right observable: the initiator may only leave once the survivor
    // has really JOINED this fetch. The entry's existence was already true before the survivor
    // was created, so waiting on that proved nothing — the READER COUNT is what a second reader
    // changes.
    #expect(
      await waitUntil {
        await loader.debugReaderCount(folderID: 1, sourceTier: .local) == 2
      }, "the survivor never joined the running fetch")

    leaver.cancel()
    #expect(
      await waitUntil {
        await loader.debugReaderCount(folderID: 1, sourceTier: .local) == 1
      }, "the leaver's departure was never processed")
    #expect(
      await loader.debugIsFetching(folderID: 1, sourceTier: .local),
      "the shared fetch was dropped even though a reader was still waiting on it")
    await transport.releaseListImages()

    // The guard against over-cancelling: "cancel the shared task whenever a reader leaves" would
    // fail exactly here, and the coalescing would take the surviving card's image away with it.
    #expect(await survivor.value == .image(bytes))
    #expect(await leaver.value == .failure)
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 1)
    #expect(await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 1)
    // Both readers are gone and the fetch is done, so its entry must be gone with them — a fetch
    // that outlived its readers is the wedge this whole mechanism exists to avoid.
    #expect(
      await waitUntil {
        await loader.debugIsFetching(folderID: 1, sourceTier: .local) == false
      }, "the completed fetch left its in-flight entry behind")
  }

  @Test("A key whose fetch was abandoned is not wedged: the next reader fetches it normally")
  func aCancelledKeyIsFetchableAgain() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 1)
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 1, nextCursor: nil))
    let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
    await transport.setProxyOutcome(.ok(bytes))
    await transport.holdNextListImagesRequest()

    let blocker = Task { await loader.hero(folderID: 99, sourceTier: nil) }
    await transport.waitUntilListImagesStarted()
    let lone = Task { await loader.hero(folderID: 7, sourceTier: nil) }
    #expect(
      await waitUntil {
        let fetching = await loader.debugIsFetching(folderID: 7, sourceTier: nil)
        let queued = await loader.debugGateWaiterCount()
        return fetching && queued == 1
      }, "the lone reader's fetch never reached the concurrency gate")
    lone.cancel()
    #expect(
      await waitUntil {
        await loader.debugIsFetching(folderID: 7, sourceTier: nil) == false
      }, "the abandoned fetch was still registered after its only reader was cancelled")
    await transport.releaseListImages()
    _ = await blocker.value
    #expect(await lone.value == .failure)

    // THE DISCRIMINATION. "It came back with the image" is true whether the fresh reader really
    // fetched or was served a cache the abandoned fetch had filled behind everyone's back — so
    // what is asserted is the DELTA: exactly one more images call and exactly one more proxy
    // call than before this line. A poisoned cache produces neither.
    let imagesBefore = await transport.callCount(Operations.ListImagesApiImagesGet.id)
    let proxyBefore = await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id)
    let again = await loader.hero(folderID: 7, sourceTier: nil)
    #expect(again == .image(bytes))
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == imagesBefore + 1)
    #expect(
      await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id)
        == proxyBefore + 1)
  }

  @Test(
    "Bounded concurrency: a second hero() call waits for a free slot before starting its OWN network call"
  )
  func boundedConcurrency() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 1)
    await transport.setListImagesPage(.init(items: [makeImage(id: 1)], limit: 1, nextCursor: nil))
    await transport.holdNextListImagesRequest()

    let taskA = Task { await loader.hero(folderID: 1, sourceTier: nil) }
    await transport.waitUntilListImagesStarted()

    let taskB = Task { await loader.hero(folderID: 2, sourceTier: nil) }
    // Task B must be blocked at the LOADER'S OWN concurrency gate (before ever reaching the
    // transport) while the single slot is held by task A — proven by the call count staying at
    // 1 after giving task B a real chance to run.
    try await Task.sleep(nanoseconds: 30_000_000)
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 1)

    await transport.releaseListImages()
    _ = await taskA.value
    _ = await taskB.value
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 2)
  }

  // MARK: - IMGMGR-622: the proxy identity token

  /// A hero image whose grid proxy carries identity token `token`, as the server reports it: in
  /// the `ProxyState.url` query (`ProxyIdentity.token(from:)` is what reads it back).
  private func makeImage(id: Int, gridToken token: String?) -> Components.Schemas.ImageSummary {
    var image = makeImage(id: id)
    let url = "/api/images/\(id)/proxy/grid" + (token.map { "?v=\($0)" } ?? "")
    image.proxies = .init(additionalProperties: [
      ProxyTier.grid.rawValue: Components.Schemas.ProxyState(
        height: 400, url: url, verdict: .ok, width: 400)
    ])
    return image
  }

  private func page(_ image: Components.Schemas.ImageSummary) -> Components.Schemas.ImagePage {
    .init(items: [image], limit: 1, nextCursor: nil)
  }

  /// One hero read of folder 1 (local tier) as of the folder-list fetch stamped `stamp`.
  private func hero(_ loader: HeroThumbnailLoader, at stamp: Date) async
    -> HeroThumbnailLoader.FetchResult
  {
    await loader.hero(folderID: 1, sourceTier: .local, listFetchedAt: stamp)
  }

  private let listFetch1 = Date(timeIntervalSince1970: 1_000)
  private let listFetch2 = Date(timeIntervalSince1970: 2_000)

  @Test("A token change seen on the next folder-list refresh fetches again and replaces the bytes")
  func tokenChangeAcrossARefreshRefetches() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    let old = Data([0xFF, 0xD8, 0x01])
    let new = Data([0xFF, 0xD8, 0x02])
    await transport.setListImagesPage(page(makeImage(id: 1, gridToken: "gen1")))
    await transport.setProxyOutcome(.ok(old))
    #expect(await hero(loader, at: listFetch1) == .image(old))

    // The backend flips ONLY the token (the v0.23.2 PROXY_RAW_ICC_GENERATION case): same image,
    // new identity, new bytes behind it.
    await transport.setListImagesPage(page(makeImage(id: 1, gridToken: "gen2")))
    await transport.setProxyOutcome(.ok(new))
    #expect(await hero(loader, at: listFetch2) == .image(new))
    #expect(await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 2)

    // And the replacement is what the cache now holds: a second reader of the same refresh gets
    // the new bytes with no further request.
    #expect(await hero(loader, at: listFetch2) == .image(new))
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 2)
    #expect(await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 2)
  }

  @Test("An unchanged token across a refresh re-checks the hero item but never re-fetches pixels")
  func unchangedTokenAcrossARefreshFetchesPixelsOnce() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    let bytes = Data([0xFF, 0xD8, 0x03])
    await transport.setListImagesPage(page(makeImage(id: 1, gridToken: "gen1")))
    await transport.setProxyOutcome(.ok(bytes))
    #expect(await hero(loader, at: listFetch1) == .image(bytes))
    // A different body would show up if the loader went to the proxy again.
    await transport.setProxyOutcome(.ok(Data([0xFF, 0xD8, 0x04])))

    #expect(await hero(loader, at: listFetch2) == .image(bytes))
    #expect(await hero(loader, at: listFetch2) == .image(bytes))
    #expect(await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 1)
    // One limit-1 re-check for the refresh, none for the second reader of that refresh.
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 2)
  }

  @Test("Within one folder-list fetch a token change is NOT looked for: zero extra requests")
  func sameListFetchServesTheCacheWithoutRequests() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    let bytes = Data([0xFF, 0xD8, 0x05])
    await transport.setListImagesPage(page(makeImage(id: 1, gridToken: "gen1")))
    await transport.setProxyOutcome(.ok(bytes))
    #expect(await hero(loader, at: listFetch1) == .image(bytes))
    await transport.setListImagesPage(page(makeImage(id: 1, gridToken: "gen2")))

    #expect(await hero(loader, at: listFetch1) == .image(bytes))
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 1)
    #expect(await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 1)
  }

  @Test("A different hero IMAGE under the same token string is a different identity: refetch")
  func heroImageChangeAcrossARefreshRefetches() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    let first = Data([0xFF, 0xD8, 0x06])
    let second = Data([0xFF, 0xD8, 0x07])
    await transport.setListImagesPage(page(makeImage(id: 1, gridToken: "same")))
    await transport.setProxyOutcome(.ok(first))
    _ = await hero(loader, at: listFetch1)

    await transport.setListImagesPage(page(makeImage(id: 2, gridToken: "same")))
    await transport.setProxyOutcome(.ok(second))
    #expect(await hero(loader, at: listFetch2) == .image(second))
    #expect(await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 2)
  }

  @Test("No token on either side (nil == nil) across a refresh counts as unchanged")
  func nilTokenOnBothSidesIsUnchanged() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    let bytes = Data([0xFF, 0xD8, 0x08])
    await transport.setListImagesPage(page(makeImage(id: 1, gridToken: nil)))
    await transport.setProxyOutcome(.ok(bytes))
    _ = await hero(loader, at: listFetch1)
    await transport.setProxyOutcome(.ok(Data([0xFF, 0xD8, 0x09])))

    #expect(await hero(loader, at: listFetch2) == .image(bytes))
    // The re-check DID run (a second limit-1 page); only the pixels were not fetched again.
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 2)
    #expect(await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 1)
  }

  @Test("A reader of a NEWER list fetch that finds an older fetch in flight re-checks after it")
  func newerStampReaderDoesNotSettleForAnOlderInFlightFetch() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    let old = Data([0xFF, 0xD8, 0x0E])
    let new = Data([0xFF, 0xD8, 0x0F])
    await transport.setListImagesPage(page(makeImage(id: 1, gridToken: "gen1")))
    await transport.setProxyOutcome(.ok(old))
    // The hold stays armed for the whole test, so each proxy request parks until released and
    // the test decides which body each one answers with.
    await transport.holdProxyRequests(true)

    // Reader A (list fetch 1) has read the OLD identity and is parked on its proxy request.
    let readerA = Task { await hero(loader, at: listFetch1) }
    let aParked = await waitUntil {
      await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 1
    }
    #expect(aParked)

    // Reader B carries list fetch 2, which happened after the server re-tokened the cover.
    await transport.setListImagesPage(page(makeImage(id: 1, gridToken: "gen2")))
    let readerB = Task { await hero(loader, at: listFetch2) }
    let bWaiting = await waitUntil {
      await loader.debugReaderCount(folderID: 1, sourceTier: .local) == 2
    }
    #expect(bWaiting)

    // A's request answers with the old bytes; B must then make its OWN re-check, which reaches
    // the proxy a second time and is answered with the new bytes.
    await transport.releaseProxy()
    #expect(await readerA.value == .image(old))
    let bRechecked = await waitUntil {
      await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 2
    }
    #expect(bRechecked)
    await transport.setProxyOutcome(.ok(new))
    await transport.holdProxyRequests(false)
    await transport.releaseProxy()

    #expect(await readerB.value == .image(new))
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 2)
    // What B stored is checked against list fetch 2: the next reader of it costs nothing.
    #expect(await hero(loader, at: listFetch2) == .image(new))
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 2)
    #expect(await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 2)
  }

  @Test("A re-check that fails keeps serving the cached cover instead of failing the reader")
  func failedRecheckServesTheCachedCover() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    let bytes = Data([0xFF, 0xD8, 0x0A])
    await transport.setListImagesPage(page(makeImage(id: 1, gridToken: "gen1")))
    await transport.setProxyOutcome(.ok(bytes))
    _ = await hero(loader, at: listFetch1)

    await transport.setListImagesShouldFail(true)
    #expect(await hero(loader, at: listFetch2) == .image(bytes))
    // The failed re-check did not mark the entry checked: the next reader of that refresh tries
    // again, and this time the token change it finds is honoured.
    await transport.setListImagesPage(page(makeImage(id: 1, gridToken: "gen2")))
    let new = Data([0xFF, 0xD8, 0x0B])
    await transport.setProxyOutcome(.ok(new))
    #expect(await hero(loader, at: listFetch2) == .image(new))
  }

  @Test("Two readers of one refresh share ONE re-check and get the new bytes from ONE proxy fetch")
  func twoReadersOfOneRefreshShareOneRecheck() async throws {
    let (loader, transport) = makeLoader(maxConcurrent: 4)
    await transport.setListImagesPage(page(makeImage(id: 1, gridToken: "gen1")))
    await transport.setProxyOutcome(.ok(Data([0xFF, 0xD8, 0x0C])))
    _ = await hero(loader, at: listFetch1)

    let new = Data([0xFF, 0xD8, 0x0D])
    await transport.setListImagesPage(page(makeImage(id: 1, gridToken: "gen2")))
    await transport.setProxyOutcome(.ok(new))
    await transport.holdProxyRequests(true)
    let first = Task { await hero(loader, at: listFetch2) }
    // A bounded wait, never `waitUntilProxyStarted()`: a loader that serves the stale cache never
    // reaches the proxy, and the unbounded wait would hang the run instead of failing it.
    let refetching = await waitUntil {
      await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 2
    }
    #expect(refetching)
    let second = Task { await hero(loader, at: listFetch2) }
    let joined = await waitUntil {
      await loader.debugReaderCount(folderID: 1, sourceTier: .local) == 2
    }
    #expect(joined)
    await transport.holdProxyRequests(false)
    await transport.releaseProxy()

    #expect(await first.value == .image(new))
    #expect(await second.value == .image(new))
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 2)
    #expect(await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 2)
  }
}
