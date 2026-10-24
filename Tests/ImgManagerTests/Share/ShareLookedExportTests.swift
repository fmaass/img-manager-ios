import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-544: a photograph with a saved look shares the LOOKED preview, or refuses — never the
/// unlooked bytes in its place.
@MainActor
@Suite("Share the looked preview (IMGMGR-544)")
struct ShareLookedExportTests {
  static let lookedJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4C, 0xFF, 0xD9])
  static let warm = LookModel.Active(lookID: "warm-film", strength: 120)

  enum Failure: String, CaseIterable, Sendable {
    case refused, notFound, transport, notJPEG
  }

  private func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "share-looked-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func makeStore(_ transport: GridStubTransport, directory: URL) -> ShareExportStore {
    ShareExportStore(
      service: GridService(client: ImgManagerAPIClient.make(transport: transport)),
      master: UnavailableMasterDownloader(), masterAvailable: false, directory: directory)
  }

  private func image(hasEdit: Bool? = nil) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.5, ext: "nef", filename: "DSC_1234.NEF", folderId: 1, hasEdit: hasEdit,
      id: 1, lightroom: .init(sidecarPresent: false), mark: .init(revision: "r0"),
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  @Test("The looked preview's bytes are the exported file, asked at the saved strength")
  func shareExportsTheLookedPreview() async throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    await transport.setProxyOutcome(.ok(Data([0xFF, 0xD8, 0x00])))
    await transport.setLookedProxyOutcome(.ok(Self.lookedJPEG))
    let store = makeStore(transport, directory: directory)

    await store.prepare(.preview, for: image(), look: Self.warm)

    guard case .ready(let file) = store.state else {
      Issue.record("expected .ready, got \(store.state)")
      return
    }
    #expect(file.filename == "DSC_1234.jpg")
    #expect(try Data(contentsOf: file.url) == Self.lookedJPEG)
    let looked = await transport.recordedLookedProxyRequests
    #expect(looked.count == 1)
    #expect(looked.first?.contains("/proxy/preview/look/warm-film") == true)
    #expect(looked.first?.contains("strength=120") == true)
    #expect(await transport.recordedProxyRequests.isEmpty)
  }

  @Test(
    "A looked render that cannot be prepared refuses, writes nothing, asks no unlooked proxy",
    arguments: Failure.allCases)
  func lookedShareFailureRefuses(failure: Failure) async {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    await transport.setProxyOutcome(.ok(Data([0xFF, 0xD8, 0x00])))
    let expected: ShareRefusal
    switch failure {
    case .refused:
      await transport.setLookedProxyOutcome(.refused(code: "unknown_look"))
      expected = .lookUnavailable
    case .notFound:
      await transport.setLookedProxyOutcome(.notFound)
      expected = .noPreview
    case .transport:
      await transport.setLookedProxyShouldFail(true)
      expected = .notConnected
    case .notJPEG:
      await transport.setLookedProxyOutcome(.ok(Data("<html>".utf8)))
      expected = .lookUnavailable
    }
    let store = makeStore(transport, directory: directory)

    await store.prepare(.preview, for: image(), look: Self.warm)

    #expect(store.state == .refused(expected))
    #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    #expect(await transport.recordedProxyRequests.isEmpty)
    #expect(
      ShareRefusal.lookUnavailable.copy == "This photo's look couldn't be prepared for sharing.")
  }

  @Test("An edit supersedes the look: no saved render, and a master export asks no look")
  func supersededLookSharesTheMaster() async {
    let saved = Components.Schemas.ImageLookView(
      lookId: "warm-film", strength: 120, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(LookPersistence.savedRender(look: saved, hasEdit: true) == nil)
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    let store = makeStore(transport, directory: directory)

    await store.prepare(.master, for: image(hasEdit: true), look: Self.warm)

    #expect(await transport.recordedLookedProxyRequests.isEmpty)
  }

  @Test("Without a saved look the preview export is the unlooked proxy, as before")
  func noLookSharesTheUnlookedPreview() async {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    await transport.setProxyOutcome(.ok(Data([0xFF, 0xD8, 0x00])))
    let store = makeStore(transport, directory: directory)

    await store.prepare(.preview, for: image(), look: nil)

    #expect(await transport.recordedLookedProxyRequests.isEmpty)
    #expect(await transport.recordedProxyRequests.count == 1)
  }
}
