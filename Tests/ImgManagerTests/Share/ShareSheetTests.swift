import Foundation
import ImgManagerAPI
import Testing
import UniformTypeIdentifiers

@testable import ImgManager

/// The presentation path, through the SAME factory the view uses (`ShareSheet.makeController`
/// is what `makeUIViewController` calls — it is split out only because a SwiftUI `Context`
/// cannot be built in a test, not to create a second code path).
///
/// Two things are proven here that a `ShareLink` could not give us: the sheet reports its own
/// dismissal, and the item declares the export's type instead of leaving the receiving app to
/// guess from a file extension.
@MainActor
@Suite("Share sheet — declared type, and dismissal that cleans up")
struct ShareSheetTests {

  private func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "share-sheet-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func image() -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.5, ext: "nef", filename: "DSC_1234.NEF", folderId: 1, id: 1,
      lightroom: .init(sidecarPresent: false), mark: .init(revision: "r0"),
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  private func readyStore(directory: URL) async -> (ShareExportStore, ShareExportFile)? {
    let transport = GridStubTransport()
    await transport.setProxyOutcome(.ok(Data([0xFF, 0xD8, 0xFF, 0xD9])))
    let store = ShareExportStore(
      service: GridService(client: ImgManagerAPIClient.make(transport: transport)),
      directory: directory)
    await store.prepare(.preview, for: image())
    guard case .ready(let file) = store.state else { return nil }
    return (store, file)
  }

  @Test("The item declares the EXPORT's type and name — never inferred from the URL")
  func itemProviderDeclaresTheExportsType() throws {
    let file = ShareExportFile(
      url: URL(filePath: "/tmp/does-not-need-to-exist/DSC_1234.jpg"), filename: "DSC_1234.jpg",
      contentType: .jpeg)

    let provider = ShareSheet.makeItemProvider(for: file)

    #expect(provider.registeredTypeIdentifiers == [UTType.jpeg.identifier])
    #expect(provider.suggestedName == "DSC_1234.jpg")
  }

  @Test("A master's server-declared type flows through unchanged once the seam opens")
  func itemProviderCarriesWhateverTypeTheExportHas() {
    let file = ShareExportFile(
      url: URL(filePath: "/tmp/does-not-need-to-exist/master.tiff"), filename: "master.tiff",
      contentType: .tiff)

    let provider = ShareSheet.makeItemProvider(for: file)

    #expect(provider.registeredTypeIdentifiers == [UTType.tiff.identifier])
  }

  @Test("Dismissing the sheet finishes the export: state resets and the temp file is deleted")
  func dismissalCleansUpTheTempFile() async throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    guard let (store, file) = await readyStore(directory: directory) else {
      Issue.record("expected the store to reach .ready")
      return
    }
    #expect(FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)))

    let controller = ShareSheet.makeController(file: file, share: store)
    // Exactly what UIKit invokes when the sheet goes away, shared or cancelled alike.
    controller.completionWithItemsHandler?(nil, false, nil, nil)

    #expect(store.state == .idle)
    #expect(!FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)))
  }

  @Test("The controller really does carry a completion handler — the wiring is not optional")
  func theControllerReportsDismissal() async throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    guard let (store, file) = await readyStore(directory: directory) else {
      Issue.record("expected the store to reach .ready")
      return
    }

    let controller = ShareSheet.makeController(file: file, share: store)

    // Without this, dismissal is silent and the file outlives the sheet — the defect this
    // whole presentation path exists to close.
    #expect(controller.completionWithItemsHandler != nil)
  }
}
