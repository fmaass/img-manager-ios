import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// IMGMGR-658: the preset calls against the real generated client — the URL the client builds,
/// the 404 that hides the row, the refusals' mapping and the bounded file read.
@Suite("GridService preset calls (IMGMGR-658)")
struct GridServicePresetTests {
  private func service(_ transport: PresetStubTransport) -> GridService {
    GridService(client: ImgManagerAPIClient.make(transport: transport))
  }

  @Test("URL freshness: two render hashes ask two different URLs, each carrying ?v=<hash>")
  func twoHashesTwoURLs() async throws {
    let transport = PresetStubTransport()
    let service = service(transport)
    _ = try await service.presetRenderFile(imageID: 7, presetID: "a1b2c3d4e5f6", renderHash: "h1")
    _ = try await service.presetRenderFile(imageID: 7, presetID: "a1b2c3d4e5f6", renderHash: "h2")
    let paths = await transport.fileRequestPaths
    #expect(paths.count == 2)
    #expect(paths.first?.hasSuffix("/api/images/7/presets/a1b2c3d4e5f6/file?v=h1") == true)
    #expect(paths.last?.hasSuffix("/api/images/7/presets/a1b2c3d4e5f6/file?v=h2") == true)
    #expect(Set(paths).count == 2)
  }

  @Test("A 404 or [] from /api/presets is an empty catalogue; a listing decodes")
  func catalogueHiddenOn404() async throws {
    let transport = PresetStubTransport()
    let service = service(transport)
    await transport.setCatalogue(status: 404)
    #expect(try await service.presets().isEmpty)
    await transport.setCatalogue(status: 200, json: "[]")
    #expect(try await service.presets().isEmpty)
    await transport.setCatalogue(
      status: 200,
      json: """
        [{"id": "a1b2c3d4e5f6", "name": "Warm", "group": null, "approximate": true,
          "approximate_reasons": ["look_table"], "favourite_rank": 1, "use_count": 3}]
        """)
    let listed = try await service.presets()
    #expect(listed.map(\.id) == ["a1b2c3d4e5f6"])
    #expect(listed.first?.favouriteRank == 1)
    #expect(listed.first?.approximateReasons == ["look_table"])
    await transport.setCatalogue(status: 500)
    await #expect(throws: GridServiceError.unreachable) { try await service.presets() }
  }

  @Test(
    "The request route's refusals map to the client's own vocabulary",
    arguments: [
      (404, PresetRenderError.gone), (409, .sourceUnavailable), (422, .unsupported),
      (500, .unreachable),
    ])
  func requestRefusals(status: Int, error: PresetRenderError) async {
    let transport = PresetStubTransport()
    await transport.setRenderStatus(status)
    let service = service(transport)
    await #expect(throws: error) {
      try await service.requestPresetRender(imageID: 1, presetID: "a1b2c3d4e5f6")
    }
  }

  @Test("An ok row decodes with its hash; the request is a POST to the preset's own route")
  func requestDecodes() async throws {
    let transport = PresetStubTransport()
    let snapshot = try await service(transport).requestPresetRender(
      imageID: 1, presetID: "a1b2c3d4e5f6")
    #expect(snapshot.status == .ok)
    #expect(snapshot.renderHash == "h1")
    let paths = await transport.recordedPaths
    #expect(paths.count == 1)
    #expect(paths.first?.hasSuffix("/api/images/1/presets/a1b2c3d4e5f6") == true)
  }

  @Test("Bounded full-size transfer: a body past the cap is .tooLarge, at the cap is .ok")
  func boundedTransfer() async throws {
    let transport = PresetStubTransport()
    let service = service(transport)
    let body = Data([0xFF, 0xD8] + Array(repeating: 0, count: 30))
    await transport.setFileOutcome(.ok(body))
    let over = try await service.presetRenderFile(
      imageID: 1, presetID: "p", renderHash: "h", byteCap: body.count - 1)
    #expect(over == .tooLarge)
    let exact = try await service.presetRenderFile(
      imageID: 1, presetID: "p", renderHash: "h", byteCap: body.count)
    #expect(exact == .ok(body))
    #expect(PresetRenderPlan.fileByteCap == 64 * 1024 * 1024)
  }

  @Test("A stale hash's 404 is .notFound, never another render's bytes")
  func staleHashNotFound() async throws {
    let transport = PresetStubTransport()
    await transport.setFileOutcome(.notFound)
    let result = try await service(transport).presetRenderFile(
      imageID: 1, presetID: "p", renderHash: "old")
    #expect(result == .notFound)
  }
}
