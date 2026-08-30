import Foundation
import OpenAPIRuntime

/// THE MASTER SEAM — the one switch that turns on the edited-master half of the share lane.
///
/// FIRST-ACTION CONTRACT PROBE (IMGMGR-196, 2026-08-29). The vendored contract
/// (`Packages/ImgManagerAPI/Sources/ImgManagerAPI/openapi.json`, img-manager v0.9.2) declares
/// `GET /api/images/{image_id}/download` with a `200` that has NO `content` block at all —
/// literally `{"description": "Successful Response"}`. swift-openapi-generator therefore emits
/// an `Output.Ok` carrying no body, so the master's BYTES are unreachable through the generated
/// client. There is no hand-built request here and there never will be: "never hand-write a
/// client method: if something will not generate, fix the contract"
/// (`Packages/ImgManagerAPI/Package.swift`). `DownloadContractProbeTests` records that finding
/// as a passing test rather than a comment.
///
/// What IS built and tested today are the PIECES a real downloader will assemble, each on its
/// own: streaming-with-a-cap (`ShareStreamWriter`), server-authored naming
/// (`ShareExportPlan.filename(fromContentDisposition:)`), refusal mapping
/// (`ShareExportPlan.refusal(status:policyHeader:)`), and the pre-flight state machine and
/// temp-file lifecycle around them (`ShareExportStore`, exercised end to end against a
/// substituted downloader).
///
/// What is NOT built is the downloader itself: nothing yet issues the request, reads the
/// response's `Content-Disposition`, or pulls `X-Img-Policy` off a real 403 — those three reads
/// are written for the first time in step 3 below, and only the contract probe currently touches
/// that operation at all. Treat this as assembled parts, not a finished lane behind a switch.
///
/// TO ACTIVATE, in this order:
///  1. img-manager declares `200: {content: {application/octet-stream: {schema: {type: string,
///     format: binary}}}}` on that operation. The backend ALREADY sends a `FileResponse` with a
///     `Content-Disposition`; only the declaration is missing.
///  2. `scripts/sync-openapi.sh` re-vendors, and `DownloadContractProbeTests` flips from
///     recording the body's absence to asserting the body.
///  3. One `MasterDownloading` conformance lands on `GridService` — a single added method that
///     streams the generated `HTTPBody` through `ShareStreamWriter` with `masterByteCap`, names
///     the file from the response's `Content-Disposition`, and maps 403-with-`X-Img-Policy`,
///     404 and everything else through `ShareExportPlan.refusal(status:policyHeader:)`.
///  4. `isAvailable` becomes `true`, and `ShareExportStore` is constructed with that
///     conformance instead of `UnavailableMasterDownloader`.
///
/// Step 4 is the ONLY behavioural switch: the loupe's master entry, the streaming, the naming
/// and the refusal copy are already the paths the preview half runs through today.
enum ShareMasterSeam {
  /// OFF, deliberately, until the contract above carries a body. `ShareMasterSeamTests` is the
  /// named test that turns RED the moment this is flipped, so activation cannot happen as a
  /// side effect of an unrelated edit — it has to be a decision someone makes with the
  /// re-vendored contract in front of them.
  static let isAvailable = false
}

/// The master lane's byte source, factored out so the whole pipeline above it is real and
/// tested while only this one call is parked. Conformances live wherever the generated client
/// does (`GridService`), never here.
protocol MasterDownloading: Sendable {
  func downloadMaster(imageID: Int, into directory: URL) async -> MasterDownloadOutcome
}

enum MasterDownloadOutcome: Sendable, Equatable {
  case ok(ShareExportFile)
  case refused(ShareRefusal)
}

/// The seam's standing implementation while `ShareMasterSeam.isAvailable` is false: it refuses
/// in the same shape a real downloader would, so the state machine above it runs the identical
/// path either way.
struct UnavailableMasterDownloader: MasterDownloading {
  func downloadMaster(imageID: Int, into directory: URL) async -> MasterDownloadOutcome {
    .refused(.masterContractUnavailable)
  }
}

/// Streams a response body straight to a file instead of materialising it as one `Data` (gate
/// correction 4). A 60 MP master export is far larger than any proxy, and a client that buffers
/// whatever the server sends has no bound at all. Past `cap` the partial file is deleted and the
/// write refuses, so an over-cap response costs a bounded amount of disk and nothing is shared.
///
/// Written and tested NOW even though its only production caller arrives with the re-vendored
/// contract: the cap and the delete-on-abort are the parts that must not be improvised later,
/// under time pressure, against a live endpoint.
enum ShareStreamWriter {
  enum Failure: Error, Equatable {
    case tooLarge
    case writeFailed
  }

  /// Returns the number of bytes written. `cap` is a hard ceiling on the TOTAL, checked as
  /// chunks arrive — never after the fact, which would mean the buffer already happened.
  @discardableResult
  static func write(_ body: HTTPBody, to url: URL, cap: Int) async throws -> Int {
    let manager = FileManager.default
    try? manager.removeItem(at: url)
    guard manager.createFile(atPath: url.path(percentEncoded: false), contents: nil),
      let handle = try? FileHandle(forWritingTo: url)
    else {
      throw Failure.writeFailed
    }
    var written = 0
    do {
      for try await chunk in body {
        written += chunk.count
        if written > cap {
          try? handle.close()
          try? manager.removeItem(at: url)
          throw Failure.tooLarge
        }
        try handle.write(contentsOf: Data(chunk))
      }
    } catch let failure as Failure {
      throw failure
    } catch {
      try? handle.close()
      try? manager.removeItem(at: url)
      throw Failure.writeFailed
    }
    try? handle.close()
    return written
  }
}
