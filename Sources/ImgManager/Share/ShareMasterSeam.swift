import Foundation
import OpenAPIRuntime

/// THE MASTER SEAM — the one switch that turns on the edited-master half of the share lane.
///
/// FIRST-ACTION CONTRACT PROBE (IMGMGR-196, 2026-08-29), NOW PARTLY OVERTAKEN. The contract as
/// vendored at img-manager v0.9.2 declared `GET /api/images/{image_id}/download` with a `200`
/// that had NO `content` block at all — literally `{"description": "Successful Response"}` — so
/// swift-openapi-generator emitted an `Output.Ok` carrying no body and the master's BYTES were
/// unreachable through the generated client. The IMGMGR-249 re-vendor (img-manager `74203992`,
/// 2026-08-31) changed that: the operation declares binary content and `Ok` now carries a `Body`,
/// which is steps 1 and 2 of the activation list below, already done. There is still no
/// hand-built request here and there never will be: "never hand-write a client method: if
/// something will not generate, fix the contract"
/// (`Packages/ImgManagerAPI/Package.swift`). `DownloadContractProbeTests` records the position
/// as a passing test rather than a comment, and moved with the contract.
///
/// The pieces the downloader assembles were built and tested before it existed, each on its
/// own: streaming-with-a-cap (`ShareStreamWriter`), server-authored naming
/// (`ShareExportPlan.filename(fromContentDisposition:)`), refusal mapping
/// (`ShareExportPlan.refusal(status:policyHeader:)`), and the pre-flight state machine and
/// temp-file lifecycle around them (`ShareExportStore`). IMGMGR-279 added the one thing that was
/// missing — the request itself — as `GridService.downloadMaster`, which issues it, reads the
/// response's `Content-Disposition`, types the body through `ShareExportPlan.contentType(for:)`
/// and pulls `X-Img-Policy` off a 403. `MasterDownloadTests` drives all of that through the real
/// generated client over a stub transport.
///
/// ACTIVATION, in this order — ALL FOUR DONE (IMGMGR-279, 2026-09-02):
///  1. DONE (img-manager `74203992`): the operation declares binary `200` content.
///  2. DONE (WP14 lane A re-vendor): `DownloadContractProbeTests` asserts the body's presence
///     instead of recording its absence.
///  3. DONE (IMGMGR-279): `GridService` conforms to `MasterDownloading` — one added method that
///     streams the generated `HTTPBody` through `ShareStreamWriter` with `masterByteCap`, names
///     the file from the response's `Content-Disposition`, types it from the served body through
///     `ShareExportPlan.contentType(for:)`, and maps 403-with-`X-Img-Policy`, 404 and everything
///     else through `ShareExportPlan.refusal(status:policyHeader:)`.
///  4. DONE (IMGMGR-279): `isAvailable` is `true`, and `RootView` constructs `ShareExportStore`
///     with that conformance instead of `UnavailableMasterDownloader`.
///
/// Step 4 was the ONLY behavioural switch: the loupe's master entry, the streaming, the naming
/// and the refusal copy were already the paths the preview half ran through.
enum ShareMasterSeam {
  /// ON since IMGMGR-279: the contract carries a body, `GridService.downloadMaster` issues the
  /// request, and `RootView` hands that conformance to the store. Owner decision of 2026-09-02,
  /// verbatim — "we should always share the highest possible quality" — which is what made
  /// finishing the seam the requirement rather than retiring the flag.
  ///
  /// It stays a named constant rather than disappearing into the call sites: `ShareExportStore`
  /// still guards every master export behind it, so one edit turns the master lane off again if
  /// the endpoint ever has to be stood down, and `ShareMasterSeamTests` still pins what this
  /// build ships.
  static let isAvailable = true
}

/// The master lane's byte source, factored out so the pipeline above it can be tested against a
/// substituted downloader instead of the network. Conformances live wherever the generated
/// client does (`GridService`), never here.
protocol MasterDownloading: Sendable {
  func downloadMaster(imageID: Int, into directory: URL) async -> MasterDownloadOutcome
}

enum MasterDownloadOutcome: Sendable, Equatable {
  case ok(ShareExportFile)
  case refused(ShareRefusal)
}

/// The refusing implementation for a build with the seam CLOSED — the store's default, and what
/// the master lane falls back to if `isAvailable` is ever set false again. It refuses in the
/// same shape the real downloader would, so the state machine above it runs the identical path
/// either way.
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
/// Its production caller is `GridService.downloadMaster` (step 3 above).
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
