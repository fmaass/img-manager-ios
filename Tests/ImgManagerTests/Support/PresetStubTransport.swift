import Foundation
import HTTPTypes
import ImgManagerAPI
import OpenAPIRuntime

/// IMGMGR-658: the preset routes, routed by the real generated `operationID` like
/// `GridStubTransport`. Records every request path it is sent, so a test reads the exact URL the
/// generated client built (`?v=<render_hash>` included). The `/file` answer can be HELD until
/// the test releases it, to put a supersede between the request and its bytes — or, with
/// `holdEachFile()`, every `/file` request is held on its own and answered individually, so two
/// can be in flight at once (IMGMGR-676).
actor PresetStubTransport: ClientTransport {
  enum FileOutcome: Sendable {
    case ok(Data)
    case notFound
  }

  private(set) var recordedPaths: [String] = []
  private(set) var recordedOperations: [String] = []
  private var catalogueStatus: Int = 200
  private var catalogueJSON = "[]"
  private var renderStatus: Int = 200
  private var fileOutcome: FileOutcome = .ok(Data([0xFF, 0xD8, 0xFF, 0xD9]))

  private var holdsFile = false
  private var fileStarted: CheckedContinuation<Void, Never>?
  private var fileHasStarted = false
  private var fileRelease: CheckedContinuation<Void, Never>?

  private var holdsEachFile = false
  private var heldFiles: [(path: String, answer: CheckedContinuation<FileOutcome, Never>)] = []
  private var heldFileCount = 0
  private var heldFileWaiters: [(count: Int, ready: CheckedContinuation<Void, Never>)] = []

  func setCatalogue(status: Int, json: String = "[]") {
    catalogueStatus = status
    catalogueJSON = json
  }

  func setRenderStatus(_ status: Int) { renderStatus = status }

  func setFileOutcome(_ outcome: FileOutcome) { fileOutcome = outcome }

  /// Arms the hold: the next `/file` request suspends until `releaseFile()`.
  func holdFile() { holdsFile = true }

  func waitForFileStart() async {
    if fileHasStarted { return }
    await withCheckedContinuation { fileStarted = $0 }
  }

  func releaseFile() {
    holdsFile = false
    fileRelease?.resume()
    fileRelease = nil
  }

  /// Arms the per-request hold: every later `/file` request suspends, under its own path, until
  /// `answerFile(containing:with:)` answers it.
  func holdEachFile() { holdsEachFile = true }

  /// Returns once `count` `/file` requests in all have been held.
  func waitForHeldFiles(_ count: Int) async {
    if heldFileCount >= count { return }
    await withCheckedContinuation { heldFileWaiters.append((count, $0)) }
  }

  /// Answers the held `/file` request whose path contains `fragment`; false when none is held.
  @discardableResult
  func answerFile(containing fragment: String, with outcome: FileOutcome) -> Bool {
    guard let index = heldFiles.firstIndex(where: { $0.path.contains(fragment) }) else {
      return false
    }
    heldFiles.remove(at: index).answer.resume(returning: outcome)
    return true
  }

  var fileRequestPaths: [String] {
    zip(recordedOperations, recordedPaths)
      .filter { $0.0 == Operations.PresetRenderFileApiImagesImageIdPresetsPresetIdFileGet.id }
      .map(\.1)
  }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    recordedPaths.append(request.path ?? "")
    recordedOperations.append(operationID)
    switch operationID {
    case Operations.ListPresetsApiPresetsGet.id:
      return json(catalogueStatus, catalogueJSON)
    case Operations.RequestPresetRenderApiImagesImageIdPresetsPresetIdPost.id,
      Operations.GetPresetRenderApiImagesImageIdPresetsPresetIdGet.id:
      return json(
        renderStatus,
        """
        {"image_id": 1, "preset_id": "a1b2c3d4e5f6", "generation": 2, "status": "ok",
         "approximate": false, "engine_version": "e1", "render_hash": "h1", "size": 4,
         "requested_at": "2026-10-26T12:00:00Z"}
        """)
    case Operations.PresetRenderFileApiImagesImageIdPresetsPresetIdFileGet.id:
      if holdsEachFile {
        let path = request.path ?? ""
        let outcome: FileOutcome = await withCheckedContinuation { answer in
          heldFiles.append((path, answer))
          heldFileCount += 1
          let ready = heldFileWaiters.filter { $0.count <= heldFileCount }
          heldFileWaiters.removeAll { $0.count <= heldFileCount }
          for waiter in ready { waiter.ready.resume() }
        }
        return fileResponse(outcome)
      }
      if holdsFile {
        fileHasStarted = true
        fileStarted?.resume()
        fileStarted = nil
        await withCheckedContinuation { fileRelease = $0 }
      }
      return fileResponse(fileOutcome)
    default:
      return (HTTPResponse(status: .notFound), nil)
    }
  }

  private func fileResponse(_ outcome: FileOutcome) -> (HTTPResponse, HTTPBody?) {
    switch outcome {
    case .ok(let data):
      var response = HTTPResponse(status: .ok)
      response.headerFields[.contentType] = "image/jpeg"
      return (response, HTTPBody(data))
    case .notFound:
      return (HTTPResponse(status: .notFound), nil)
    }
  }

  private func json(_ status: Int, _ text: String) -> (HTTPResponse, HTTPBody?) {
    var response = HTTPResponse(status: .init(code: status))
    response.headerFields[.contentType] = "application/json"
    return (response, HTTPBody(Data(text.utf8)))
  }
}
