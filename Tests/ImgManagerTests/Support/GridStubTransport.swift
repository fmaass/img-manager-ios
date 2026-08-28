import Foundation
import HTTPTypes
import ImgManagerAPI
import OpenAPIRuntime

/// P4's own test-only stub transport — a sibling of `StubClientTransport` (P3's own, confined
/// to its three read-only operations by design), routing P4's seven operations by the real
/// generated `operationID` strings, so every test decodes through the REAL generated `Client`
/// exactly as production does (same discipline as `StubClientTransport`'s own doc comment).
actor GridStubTransport: ClientTransport {
  enum MarkMutationOutcome: Sendable {
    case success(Components.Schemas.MarksApplied)
    case conflict
  }

  /// Always what a `cursor == nil` (first-page / restart) request receives.
  var listImagesPage = Components.Schemas.ImagePage(items: [], limit: 100, nextCursor: nil)
  /// When true, a request that DOES carry a non-empty `cursor` gets the undocumented
  /// cursor-fingerprint 400 instead of `listImagesPage` — modeling the real backend
  /// (`app/api/cursor.py`): a fresh page-one request always succeeds; only a stale/mismatched
  /// cursor is refused. This lets a single test prove both the refusal AND that the restart
  /// (which resends with `cursor == nil`) actually lands on real data again.
  var listImagesRejectNonNilCursor = false
  var facetsResult = Components.Schemas.ImageFacets(total: 0)
  var detailResult: Components.Schemas.ImageDetail?
  var proxyOutcome: ProxyOutcome = .ok(Data([0xFF, 0xD8, 0xFF, 0xD9]))
  var markStateOutcome: MarkMutationOutcome = .success(
    Components.Schemas.MarksApplied(applied: 0, requested: 0, revisions: []))
  var tagsOutcome: MarkMutationOutcome = .success(
    Components.Schemas.MarksApplied(applied: 0, requested: 0, revisions: []))

  enum ProxyOutcome: Sendable {
    case ok(Data)
    case notModified
    case notFound
  }

  private(set) var lastMarkStateRequest: Components.Schemas.MarkStateRequest?
  private(set) var lastTagsRequest: Components.Schemas.MarkTagsRequest?
  private(set) var callCounts: [String: Int] = [:]

  func setListImagesPage(_ page: Components.Schemas.ImagePage) { listImagesPage = page }
  func setListImagesRejectNonNilCursor(_ reject: Bool) { listImagesRejectNonNilCursor = reject }
  func setFacetsResult(_ result: Components.Schemas.ImageFacets) { facetsResult = result }
  func setDetailResult(_ result: Components.Schemas.ImageDetail) { detailResult = result }
  func setProxyOutcome(_ outcome: ProxyOutcome) { proxyOutcome = outcome }
  func setMarkStateOutcome(_ outcome: MarkMutationOutcome) { markStateOutcome = outcome }
  func setTagsOutcome(_ outcome: MarkMutationOutcome) { tagsOutcome = outcome }
  func callCount(_ operationID: String) -> Int { callCounts[operationID] ?? 0 }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    callCounts[operationID, default: 0] += 1

    switch operationID {
    case Operations.FolderTreeApiFoldersGet.id:
      return try jsonResponse(.ok, Components.Schemas.FolderTree(items: []))

    case Operations.ListImagesApiImagesGet.id:
      let cursorValue = request.path.flatMap(URLComponents.init(string:))?
        .queryItems?.first(where: { $0.name == "cursor" })?.value
      if listImagesRejectNonNilCursor, let cursorValue, !cursorValue.isEmpty {
        // No declared content for this status in the vendored schema (see GridService's own
        // doc comment) — the real backend's actual 400 body is irrelevant to what the
        // generated client can express; only the STATUS CODE is what `.undocumented` exposes.
        return (HTTPResponse(status: .badRequest), nil)
      }
      return try jsonResponse(.ok, listImagesPage)

    case Operations.ImageFacetsApiFacetsGet.id:
      return try jsonResponse(.ok, facetsResult)

    case Operations.GetImageApiImagesImageIdGet.id:
      guard let detailResult else {
        throw SentinelTransportError(raw: "GridStubTransport: no detailResult configured")
      }
      return try jsonResponse(.ok, detailResult)

    case Operations.GetProxyApiImagesImageIdProxyTierGet.id:
      switch proxyOutcome {
      case .ok(let data):
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "image/jpeg"
        return (response, HTTPBody(data))
      case .notModified:
        return (HTTPResponse(status: .notModified), nil)
      case .notFound:
        return (HTTPResponse(status: .notFound), nil)
      }

    case Operations.SetMarkStateApiMarksStatePost.id:
      if let body {
        let data = try await Data(collecting: body, upTo: 1024 * 1024)
        lastMarkStateRequest = try? JSONDecoder.grid.decode(
          Components.Schemas.MarkStateRequest.self, from: data)
      }
      switch markStateOutcome {
      case .success(let applied): return try jsonResponse(.ok, applied)
      case .conflict: return (HTTPResponse(status: .conflict), nil)
      }

    case Operations.EditMarkTagsApiMarksTagsPost.id:
      if let body {
        let data = try await Data(collecting: body, upTo: 1024 * 1024)
        lastTagsRequest = try? JSONDecoder.grid.decode(
          Components.Schemas.MarkTagsRequest.self, from: data)
      }
      switch tagsOutcome {
      case .success(let applied): return try jsonResponse(.ok, applied)
      case .conflict: return (HTTPResponse(status: .conflict), nil)
      }

    default:
      throw SentinelTransportError(raw: "GridStubTransport: unexpected operationID: \(operationID)")
    }
  }

  private func jsonResponse<T: Encodable>(
    _ status: HTTPResponse.Status, _ body: T
  ) throws -> (HTTPResponse, HTTPBody?) {
    var response = HTTPResponse(status: status)
    response.headerFields[.contentType] = "application/json"
    let data = try JSONEncoder.grid.encode(body)
    return (response, HTTPBody(data))
  }
}

extension JSONEncoder {
  /// The generated types decode/encode `Date` fields via ISO-8601 — mirrored here so a
  /// request-body round-trip (`lastMarkStateRequest`, etc.) never mismatches the generated
  /// `Client`'s own encoder configuration.
  fileprivate static let grid: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()
}

extension JSONDecoder {
  fileprivate static let grid: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
