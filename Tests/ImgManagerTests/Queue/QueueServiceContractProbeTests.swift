import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// P7's own generated-contract probe (mirrors `GridServiceContractProbeTests`'s own FIRST-ACTION
/// posture) — `GET /api/folder-summaries` decoded through the REAL generated `Client`, over the
/// shared `GridStubTransport`, keyed on the real `operationID`.
@Suite("P7 QueueService generated-contract probe")
struct QueueServiceContractProbeTests {

  private func makeService(_ transport: GridStubTransport) -> QueueService {
    QueueService(client: ImgManagerAPIClient.make(transport: transport))
  }

  @Test("Folder summaries: decodes through the real generated FolderSummaryList")
  func summariesProbe() async throws {
    let transport = GridStubTransport()
    let summary = Components.Schemas.FolderSummary(
      cameraPreviewOnly: 1, decided: 0, disliked: 0, edited: 0, folderId: 7, kind: "dated",
      lastTouched: nil, nothingLeftUnmarked: false, path: "p/7", picked: 0, previewOutstanding: 0,
      readiness: .init(rawValue: "ready_to_review")!, sourceTier: "local", sync: nil, total: 1,
      unmarked: 1, untouched: false, withMasters: 0)
    await transport.setFolderSummariesResult([summary])
    let service = makeService(transport)
    let items = try await service.summaries()
    #expect(items.map(\.folderId) == [7])
    #expect(items.first?.readiness.rawValue == "ready_to_review")
    #expect(items.first?.sync == nil)  // optional field, absent in this fixture
  }

  @Test("Unreachable (transport failure) maps to QueueServiceError.unreachable")
  func summariesUnreachable() async {
    let transport = GridStubTransport()
    await transport.setFolderSummariesShouldFail(true)
    let service = makeService(transport)
    do {
      _ = try await service.summaries()
      Issue.record("expected QueueServiceError.unreachable")
    } catch QueueServiceError.unreachable {
      // expected
    } catch {
      Issue.record("expected .unreachable, got \(error)")
    }
  }

  @Test("Empty response decodes to an empty array, not an error")
  func summariesEmpty() async throws {
    let transport = GridStubTransport()
    let service = makeService(transport)
    let items = try await service.summaries()
    #expect(items.isEmpty)
  }
}
