import Foundation
import OpenAPIRuntime
import Testing

@testable import ImgManager

/// The master lane's byte path, tested NOW even though its production caller waits on the
/// re-vendored contract (`ShareMasterSeam`). The cap and the delete-on-abort are the parts that
/// must not be improvised later against a live endpoint.
@Suite("Share stream writer — streamed to disk, hard-capped")
struct ShareStreamWriterTests {

  private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "share-writer-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("Chunks land on disk in order, and the byte count is what actually arrived")
  func streamsChunksToDisk() async throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "export.jpg", directoryHint: .notDirectory)

    let stream = AsyncStream<ArraySlice<UInt8>> { continuation in
      continuation.yield(ArraySlice([0xFF, 0xD8]))
      continuation.yield(ArraySlice([0xFF, 0xD9]))
      continuation.finish()
    }
    let written = try await ShareStreamWriter.write(
      HTTPBody(stream, length: .unknown), to: url, cap: 1024)

    #expect(written == 4)
    #expect(try Data(contentsOf: url) == Data([0xFF, 0xD8, 0xFF, 0xD9]))
  }

  @Test("Past the cap the partial file is DELETED — an over-cap response shares nothing")
  func refusesAndCleansUpPastTheCap() async throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "big.jpg", directoryHint: .notDirectory)

    await #expect(throws: ShareStreamWriter.Failure.tooLarge) {
      try await ShareStreamWriter.write(
        HTTPBody(Data(repeating: 0xAB, count: 4096)), to: url, cap: 1024)
    }
    #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
  }

  @Test("A body exactly at the cap is accepted — the ceiling is inclusive, not off by one")
  func acceptsExactlyTheCap() async throws {
    let directory = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "exact.jpg", directoryHint: .notDirectory)

    let written = try await ShareStreamWriter.write(
      HTTPBody(Data(repeating: 0x01, count: 1024)), to: url, cap: 1024)

    #expect(written == 1024)
    #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
  }
}
