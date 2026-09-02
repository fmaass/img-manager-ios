import Foundation
import ImgManagerAPI
import Testing
import UniformTypeIdentifiers

@testable import ImgManager

/// Step 3 of `ShareMasterSeam`'s activation list, under test: the ONE `MasterDownloading`
/// conformance on `GridService`, driven through the REAL generated `Client` over
/// `GridStubTransport` — the same discipline as `DownloadContractProbeTests`, and the reason
/// nothing here mocks `GridService` itself. The transport is the substituted dependency; the
/// unit under test is the downloader.
///
/// THE RAW INVARIANT IS TESTED FROM THE WIRE (IMGMGR-196, reaffirmed by the owner on
/// IMGMGR-348, 2026-09-02): `masterIsTheOnlyThingEverAskedFor` reads the query string the
/// generated client actually built, so a future edit that starts sending `rendition` — or
/// `content=original` — fails a named test instead of shipping a RAW original to the share
/// sheet.
@Suite("Master download — the seam's own byte source")
struct MasterDownloadTests {

  private func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "master-download-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func service(_ transport: GridStubTransport) -> GridService {
    GridService(client: ImgManagerAPIClient.make(transport: transport))
  }

  private let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])

  @Test("A delivered master lands on disk under the SERVER's name, with the server's type")
  func deliveredMasterIsWrittenUnderTheServersName() async throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    await transport.setDownloadOutcome(
      .ok(
        bytes, contentType: "image/jpeg",
        contentDisposition: "attachment; filename=\"DSC_1234-2.jpg\""))

    let outcome = await service(transport).downloadMaster(imageID: 7, into: directory)

    guard case .ok(let file) = outcome else {
      Issue.record("expected .ok, got \(outcome)")
      return
    }
    #expect(file.filename == "DSC_1234-2.jpg")
    #expect(file.contentType == .jpeg)
    #expect(file.url.lastPathComponent == "DSC_1234-2.jpg")
    #expect(try Data(contentsOf: file.url) == bytes)
  }

  @Test("The RFC 5987 form of the server's name is honoured too, and cannot escape the directory")
  func encodedServerNameIsHonouredAndSanitised() async throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    await transport.setDownloadOutcome(
      .ok(
        bytes, contentType: "image/jpeg",
        contentDisposition: "attachment; filename*=UTF-8''%2E%2E%2Fescape%2Dme.jpg"))

    let outcome = await service(transport).downloadMaster(imageID: 7, into: directory)

    guard case .ok(let file) = outcome else {
      Issue.record("expected .ok, got \(outcome)")
      return
    }
    #expect(file.filename == "escape-me.jpg")
    #expect(file.url.deletingLastPathComponent().path() == directory.path())
  }

  @Test("With no usable Content-Disposition the file still gets a real, typed name")
  func missingContentDispositionFallsBackToATypedName() async throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    await transport.setDownloadOutcome(
      .ok(bytes, contentType: "image/png", contentDisposition: nil))

    let outcome = await service(transport).downloadMaster(imageID: 42, into: directory)

    guard case .ok(let file) = outcome else {
      Issue.record("expected .ok, got \(outcome)")
      return
    }
    #expect(file.filename == ShareExportPlan.masterFilename(imageID: 42, contentType: .png))
    #expect(file.filename == "photo-42.png")
    #expect(file.contentType == .png)
  }

  /// All SEVEN bodies the `200` declares, each through the real generated client: the response's
  /// own `Content-Type` decides the case the client decodes into, and that case decides the
  /// `UTType` the share sheet registers the item under. A downloader that hard-coded `.jpeg`
  /// passes exactly one row of this table.
  @Test(
    "Every declared body type reaches the export as its own UTType",
    arguments: [
      ("application/octet-stream", UTType.data),
      ("image/heic", UTType.heic),
      ("image/heif", UTType.heif),
      ("image/jpeg", UTType.jpeg),
      ("image/png", UTType.png),
      ("image/tiff", UTType.tiff),
      ("image/webp", UTType.webP),
    ])
  func everyDeclaredBodyTypeSurvivesToTheExport(mimeType: String, expected: UTType) async throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    await transport.setDownloadOutcome(
      .ok(bytes, contentType: mimeType, contentDisposition: "attachment; filename=\"m.bin\""))

    let outcome = await service(transport).downloadMaster(imageID: 1, into: directory)

    guard case .ok(let file) = outcome else {
      Issue.record("expected .ok for \(mimeType), got \(outcome)")
      return
    }
    #expect(file.contentType == expected)
    #expect(try Data(contentsOf: file.url) == bytes)
  }

  @Test("The client asks for the MASTER and nothing else — never a rendition, never an original")
  func masterIsTheOnlyThingEverAskedFor() async {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    await transport.setDownloadOutcome(
      .ok(bytes, contentType: "image/jpeg", contentDisposition: nil))

    _ = await service(transport).downloadMaster(imageID: 3, into: directory)

    let query = await transport.lastDownloadQuery ?? ""
    #expect(query.contains("content=master"))
    #expect(!query.contains("rendition"))
    #expect(!query.contains("original"))
  }

  @Test("A policy 403 is the RAW refusal; a bare 403 is the connectivity one")
  func forbiddenSplitsOnThePolicyHeader() async {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()

    await transport.setDownloadOutcome(.rawOriginalPolicy)
    #expect(
      await service(transport).downloadMaster(imageID: 1, into: directory)
        == .refused(.rawOriginalPolicy))

    await transport.setDownloadOutcome(.sessionForbidden)
    #expect(
      await service(transport).downloadMaster(imageID: 1, into: directory)
        == .refused(.notConnected))
  }

  @Test("A 404 means this photograph has no master export — its own copy, not a failure")
  func notFoundIsTheNoMasterRefusal() async {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    await transport.setDownloadOutcome(.notFound)

    #expect(
      await service(transport).downloadMaster(imageID: 1, into: directory) == .refused(.noMaster))
  }

  @Test("An unreachable endpoint refuses with the connectivity copy and leaves no file behind")
  func unreachableEndpointRefusesWithoutAFile() async {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = GridStubTransport()
    await transport.setDownloadShouldFail(true)

    let outcome = await service(transport).downloadMaster(imageID: 1, into: directory)

    #expect(outcome == .refused(.notConnected))
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
    #expect(entries.isEmpty)
  }
}
