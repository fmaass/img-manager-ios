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
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 1)

    lone.cancel()
    // The cancellation handler hops back onto the actor to do its bookkeeping; give it that hop
    // before the slot is handed over.
    try await Task.sleep(nanoseconds: 50_000_000)

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
    // Long enough for the survivor to have joined the fetch before the other reader goes.
    try await Task.sleep(nanoseconds: 50_000_000)

    leaver.cancel()
    try await Task.sleep(nanoseconds: 50_000_000)
    await transport.releaseListImages()

    // The guard against over-cancelling: "cancel the shared task whenever a reader leaves" would
    // fail exactly here, and the coalescing would take the surviving card's image away with it.
    #expect(await survivor.value == .image(bytes))
    #expect(await leaver.value == .failure)
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 1)
    #expect(await transport.callCount(Operations.GetProxyApiImagesImageIdProxyTierGet.id) == 1)
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
    try await Task.sleep(nanoseconds: 50_000_000)
    lone.cancel()
    try await Task.sleep(nanoseconds: 50_000_000)
    await transport.releaseListImages()
    _ = await blocker.value
    #expect(await lone.value == .failure)

    // A fresh reader of the SAME key: it must neither join a dead task nor be served a cached
    // answer the abandoned fetch never produced.
    let again = await loader.hero(folderID: 7, sourceTier: nil)
    #expect(again == .image(bytes))
    #expect(await transport.callCount(Operations.ListImagesApiImagesGet.id) == 2)
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
}
