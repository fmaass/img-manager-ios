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
