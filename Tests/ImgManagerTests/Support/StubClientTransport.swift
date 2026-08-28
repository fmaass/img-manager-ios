import Foundation
import HTTPTypes
import ImgManagerAPI
import OpenAPIRuntime

/// Test-only stub proving every state transition P3 fold item 2 names — success, empty,
/// readiness-degraded, transport-failure, retry, recovery — with no real networking. It
/// implements the REAL `OpenAPIRuntime.ClientTransport` seam (diff-gate blocker 1 fold), so
/// every test decodes through the REAL generated types via the REAL generated `Client` —
/// nothing hand-written stands between this stub and `ImgManagerAPIService`.
///
/// Routing is keyed on `operationID`, the literal OpenAPI `operationId` string the
/// generated `Client` passes to `send(...)` for every call (`Operations.*.id`, the same
/// constant the generated method dispatches under) — so a renamed or removed backend
/// operation breaks these tests at the `default` branch below, not silently.
///
/// An `actor` because `ClientTransport` is `Sendable` and this stub's mutable outcome must
/// be safely reconfigurable mid-test (retry/recovery both reconfigure a stub mid-flight).
actor StubClientTransport: ClientTransport {
  enum Outcome: Sendable {
    case success
    case empty
    case degraded
    case transportFailure(raw: String)
  }

  private var outcome: Outcome
  private(set) var callCount = 0
  private(set) var lastRequestPath: String?

  init(outcome: Outcome) {
    self.outcome = outcome
  }

  func setOutcome(_ newOutcome: Outcome) {
    outcome = newOutcome
  }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    callCount += 1
    lastRequestPath = request.path

    // Transport failure plants a SENTINEL (see SentinelTransportError.swift) — a FOREIGN
    // test error never imported into application source — proving fold item 4's
    // suppression end to end rather than merely asserting it in prose.
    if case .transportFailure(let raw) = outcome {
      throw SentinelTransportError(raw: raw)
    }

    switch operationID {
    case Operations.ApiHealthApiHealthGet.id:
      return try healthResponse()
    case Operations.StatusApiStatusGet.id:
      return try statusResponse()
    case Operations.FolderTreeApiFoldersGet.id:
      return try foldersResponse()
    default:
      // Any operation outside fold item 2's allow-list (or a renamed one this stub was
      // never updated for) fails loudly instead of silently succeeding.
      throw SentinelTransportError(raw: "unexpected operationID: \(operationID)")
    }
  }

  private func jsonResponse<T: Encodable>(
    _ status: HTTPResponse.Status, _ body: T
  ) throws -> (HTTPResponse, HTTPBody?) {
    var response = HTTPResponse(status: status)
    response.headerFields[.contentType] = "application/json"
    let data = try JSONEncoder().encode(body)
    return (response, HTTPBody(data))
  }

  private func healthResponse() throws -> (HTTPResponse, HTTPBody?) {
    switch outcome {
    case .success, .empty:
      return try jsonResponse(
        .ok, Components.Schemas.ApiHealthResponse(db: "ok", status: "ok", version: "0.9.0"))
    case .degraded:
      // The real backend returns 503 for a degraded /api/health (app/main.py
      // api_health()) and 503 is not a documented response for this operation, so this
      // faithfully exercises the generated client's `.undocumented` fallback —
      // ImgManagerAPIService treats anything other than `.ok` as unreachable, this case
      // included, which is what degradedMapsToUnreachable in TransportStateTests proves.
      return try jsonResponse(
        .serviceUnavailable,
        Components.Schemas.ApiHealthResponse(
          db: "unreachable", status: "degraded", version: "0.9.0"))
    case .transportFailure:
      preconditionFailure(
        "transportFailure is handled before dispatch in send(_:body:baseURL:operationID:)")
    }
  }

  private func statusResponse() throws -> (HTTPResponse, HTTPBody?) {
    let body = Components.Schemas.StatusResponse(
      coverage: .init(imagesActive: 0, imagesMissing: 0, tiers: []),
      maintenance: .init(enabled: false),
      runs: []
    )
    return try jsonResponse(.ok, body)
  }

  private func foldersResponse() throws -> (HTTPResponse, HTTPBody?) {
    switch outcome {
    case .success:
      // "dated" is the LIVE vocabulary (IMGMGR-173) — fixtures must use kinds the API
      // actually emits.
      let node = Components.Schemas.FolderNode(
        id: 1, kind: "dated", name: "2026-08-01", path: "2026-08-01")
      return try jsonResponse(.ok, Components.Schemas.FolderTree(items: [node]))
    case .empty, .degraded:
      return try jsonResponse(.ok, Components.Schemas.FolderTree(items: []))
    case .transportFailure:
      preconditionFailure(
        "transportFailure is handled before dispatch in send(_:body:baseURL:operationID:)")
    }
  }
}
