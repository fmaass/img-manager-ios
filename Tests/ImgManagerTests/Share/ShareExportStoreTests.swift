import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// The pre-flight itself (gate correction 3): the file exists BEFORE anything could be
/// presented, and every refusal leaves the state somewhere no sheet can be opened from.
/// `ShareStatusBar` offers the share control for exactly one state — `.ready` — so "no sheet"
/// is provable here as "never reached `.ready`", not as a UI-snapshot claim.
@MainActor
@Suite("Share export pre-flight — file first, sheet second")
struct ShareExportStoreTests {

  private func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "share-store-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func makeStore(
    _ transport: GridStubTransport,
    directory: URL,
    master: any MasterDownloading = UnavailableMasterDownloader(),
    masterAvailable: Bool = false
  ) -> ShareExportStore {
    ShareExportStore(
      service: GridService(client: ImgManagerAPIClient.make(transport: transport)),
      master: master, masterAvailable: masterAvailable, directory: directory)
  }

  private func image(
    id: Int = 1, filename: String = "DSC_1234.NEF", hasEdit: Bool? = nil
  ) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.5, ext: "nef", filename: filename, folderId: 1, hasEdit: hasEdit, id: id,
      lightroom: .init(sidecarPresent: false), mark: .init(revision: "r0"),
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  @Test("Preview: proxy bytes become a real temp file, named from the stem, before .ready")
  func previewBytesBecomeAFileBeforeReady() async throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])
    await transport.setProxyOutcome(.ok(bytes))
    let store = makeStore(transport, directory: directory)
    #expect(store.state == .idle)

    await store.prepare(.preview, for: image())

    guard case .ready(let file) = store.state else {
      Issue.record("expected .ready, got \(store.state)")
      return
    }
    // Named from the STEM and the proxy's own type — never `ext`, which says "nef".
    #expect(file.filename == "DSC_1234.jpg")
    #expect(file.contentType == ShareExportPlan.previewContentType)
    #expect(FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)))
    #expect(try Data(contentsOf: file.url) == bytes)
  }

  @Test("Offline: the connectivity copy, and no file — .ready is never reached, so no sheet")
  func offlineRefusesWithNoFile() async {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    await transport.setProxyShouldFail(true)
    let store = makeStore(transport, directory: directory)

    await store.prepare(.preview, for: image())

    #expect(store.state == .refused(.notConnected))
    #expect(ShareRefusal.notConnected.copy == DegradedStateCopy.notConnected)
    #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
  }

  @Test("No preview on the tier gets its OWN copy, never the offline one")
  func missingPreviewIsNotReportedAsOffline() async {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    await transport.setProxyOutcome(.notFound)
    let store = makeStore(transport, directory: directory)

    await store.prepare(.preview, for: image())

    #expect(store.state == .refused(.noPreview))
  }

  @Test("THE SEAM, at its production default: the guard alone stops a real network attempt")
  func productionDefaultSeamIsOffAndMakesNoRequest() async {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    // A downloader that genuinely WOULD reach the transport — so `calls == 0` below is evidence
    // about the seam guard, not about a stub that never tries. `masterAvailable` is not passed:
    // it takes `ShareMasterSeam.isAvailable` exactly as the app ships it.
    let store = ShareExportStore(
      service: GridService(client: client),
      master: TransportTouchingMasterDownloader(client: client), directory: directory)

    await store.prepare(.master, for: image(hasEdit: true))

    #expect(store.state == .refused(.masterContractUnavailable))
    let calls = await transport.callCount(
      Operations.DownloadImageApiImagesImageIdDownloadGet.id)
    #expect(calls == 0)
  }

  @Test("The control for that guard: with the seam OPEN the same downloader does reach the wire")
  func seamOpenLetsTheSameDownloaderThrough() async {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    await transport.setDownloadOutcome(.notFound)
    let store = ShareExportStore(
      service: GridService(client: client),
      master: TransportTouchingMasterDownloader(client: client), masterAvailable: true,
      directory: directory)

    await store.prepare(.master, for: image(hasEdit: true))

    // Same store, same downloader, same image — the ONLY difference from the test above is the
    // guard, so deleting the guard makes that test fail rather than silently still pass.
    let calls = await transport.callCount(
      Operations.DownloadImageApiImagesImageIdDownloadGet.id)
    #expect(calls == 1)
    #expect(store.state == .refused(.noMaster))
  }

  @Test("A stale export never lands: focus moves mid-fetch, so the result is dropped and deleted")
  func staleExportIsDiscardedWhenFocusMoves() async throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    await transport.setProxyOutcome(.ok(Data([0xFF, 0xD8])))
    await transport.holdProxyRequests(true)
    let store = makeStore(transport, directory: directory)

    let inFlight = Task { await store.prepare(.preview, for: image(id: 1, filename: "A.NEF")) }
    await transport.waitUntilProxyStarted()
    // Exactly what `LoupeView`'s `.task(id: store.focusedImageID)` does when focus moves to B.
    store.finish()
    await transport.releaseProxy()
    await inFlight.value

    // Never `.ready(A)` — the bar must not offer the previous photograph under B's chrome.
    #expect(store.state == .idle)
    // A's whole generation directory is gone, so nothing of A is left anywhere under the root.
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
    #expect(entries.isEmpty)
  }

  @Test("Two exports with the SAME filename: the stale one cannot touch the live one's file")
  func sameNameOverlapLeavesTheLiveExportIntact() async throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    let bytes = Data([0xFF, 0xD8, 0xAB, 0xCD])
    await transport.setProxyOutcome(.ok(bytes))
    await transport.holdProxyRequests(true)
    let store = makeStore(transport, directory: directory)

    // A: the same photograph, held mid-fetch.
    let first = Task {
      await store.prepare(.preview, for: image(id: 1, filename: "DSC_1234.NEF"))
    }
    await transport.waitUntilProxyStarted()
    store.finish()  // focus moved — this is what frees the lane for a second export

    // B: a DIFFERENT export whose filename sanitizes to exactly the same name as A's. Under a
    // single flat directory these two resolve to one URL, which is the collision.
    await transport.holdProxyRequests(false)
    await store.prepare(.preview, for: image(id: 2, filename: "DSC_1234.dng"))
    guard case .ready(let live) = store.state else {
      Issue.record("expected .ready for B, got \(store.state)")
      return
    }
    #expect(live.filename == "DSC_1234.jpg")

    // Now let the stale A finish and clean itself up.
    await transport.releaseProxy()
    await first.value

    // B survives untouched: same state, same file, same bytes. Before the per-generation
    // directories, A's cleanup deleted exactly this URL and left `.ready` pointing at nothing.
    #expect(store.state == .ready(live))
    #expect(FileManager.default.fileExists(atPath: live.url.path(percentEncoded: false)))
    #expect(try Data(contentsOf: live.url) == bytes)
    // And only B's generation directory remains under the root.
    let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path())
    #expect(entries.count == 1)
  }

  @Test("With the seam on, a policy 403 refuses INLINE with the policy copy and no file")
  func masterPolicyRefusalRunsTheWholePipeline() async {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    let store = makeStore(
      transport, directory: directory,
      master: StubMasterDownloader(outcome: .refused(.rawOriginalPolicy)),
      masterAvailable: true)

    await store.prepare(.master, for: image(hasEdit: true))

    #expect(store.state == .refused(.rawOriginalPolicy))
    #expect(
      ShareRefusal.rawOriginalPolicy.copy
        == "RAW originals can't be exported — share the preview or the edited master instead.")
  }

  @Test("With the seam on, a delivered master becomes a ready file under the SERVER's name")
  func masterReadyUsesTheServersName() async throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    let bytes = Data([0x01, 0x02, 0x03])
    // The name the server would have sent in `Content-Disposition` — NOT the RAW's own.
    let serverName = ShareExportPlan.filename(
      fromContentDisposition: "attachment; filename=\"DSC_1234-2.jpg\"")
    let file = ShareExportFile(
      url: directory.appending(path: serverName ?? "x", directoryHint: .notDirectory),
      filename: serverName ?? "x", contentType: .jpeg)
    let store = makeStore(
      transport, directory: directory,
      master: StubMasterDownloader(outcome: .ok(file), bytes: bytes), masterAvailable: true)

    await store.prepare(.master, for: image(hasEdit: true))

    guard case .ready(let ready) = store.state else {
      Issue.record("expected .ready, got \(store.state)")
      return
    }
    #expect(ready.filename == "DSC_1234-2.jpg")
    #expect(try Data(contentsOf: ready.url) == bytes)
  }

  @Test("finish() deletes the prepared file — nothing outlives the sheet that needed it")
  func finishDeletesThePreparedFile() async throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    await transport.setProxyOutcome(.ok(Data([0xFF, 0xD8])))
    let store = makeStore(transport, directory: directory)
    await store.prepare(.preview, for: image())
    guard case .ready(let file) = store.state else {
      Issue.record("expected .ready, got \(store.state)")
      return
    }
    #expect(FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)))

    store.finish()

    #expect(store.state == .idle)
    #expect(!FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)))
  }

  @Test("A second export replaces the first — one prepared file on disk at a time")
  func aSecondExportClearsTheFirst() async throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    await transport.setProxyOutcome(.ok(Data([0xFF, 0xD8])))
    let store = makeStore(transport, directory: directory)

    await store.prepare(.preview, for: image(id: 1, filename: "FIRST.NEF"))
    await store.prepare(.preview, for: image(id: 2, filename: "SECOND.NEF"))

    guard case .ready(let file) = store.state else {
      Issue.record("expected .ready, got \(store.state)")
      return
    }
    #expect(file.filename == "SECOND.jpg")
    #expect(try Data(contentsOf: file.url) == Data([0xFF, 0xD8]))
    // One export on disk at a time: the root holds exactly the current generation's directory.
    let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path())
    #expect(contents.count == 1)
  }
}

/// Deliberately reaches the transport, exactly as the real conformance will once the contract
/// carries a body. Its whole purpose is to make "no request was made" a claim about the seam
/// guard: with a downloader that never tries, that assertion passes with or without the guard.
private struct TransportTouchingMasterDownloader: MasterDownloading {
  let client: any APIProtocol

  func downloadMaster(imageID: Int, into directory: URL) async -> MasterDownloadOutcome {
    _ = try? await client.downloadImageApiImagesImageIdDownloadGet(
      .init(path: .init(imageId: imageID), query: .init(content: .master)))
    // The outcome is beside the point — the CALL is what the guard is supposed to prevent.
    return .refused(.noMaster)
  }
}

/// Stands in for the `GridService` conformance that lands with the re-vendored contract, so the
/// state machine, the naming and the refusal copy above it all run for real today.
private struct StubMasterDownloader: MasterDownloading {
  let outcome: MasterDownloadOutcome
  var bytes: Data?

  func downloadMaster(imageID: Int, into directory: URL) async -> MasterDownloadOutcome {
    if case .ok(let file) = outcome, let bytes {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? bytes.write(to: file.url)
    }
    return outcome
  }
}
