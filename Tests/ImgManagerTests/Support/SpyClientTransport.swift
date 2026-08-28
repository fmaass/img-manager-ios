import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Test-only spy: records the LAST request it was asked to send (headers included) and answers
/// with a canned, empty response — 200 by default, or the configured `responseStatus` (diff-
/// gate round 1, blocker 3's terminal-401 pinning needs a controllable 401). Used to prove
/// `AuthenticatedClientTransport` injects (or omits) the `Authorization` header and classifies
/// terminal 401s without needing a real network call or a real generated operation — both are
/// transport-level concerns, beneath the generated `Client`.
actor SpyClientTransport: ClientTransport {
  private(set) var lastRequest: HTTPRequest?
  private(set) var callCount = 0
  private let responseStatus: HTTPResponse.Status

  init(responseStatus: HTTPResponse.Status = .ok) {
    self.responseStatus = responseStatus
  }

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    callCount += 1
    lastRequest = request
    return (HTTPResponse(status: responseStatus), nil)
  }
}
