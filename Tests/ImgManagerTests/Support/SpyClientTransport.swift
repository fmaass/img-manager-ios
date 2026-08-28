import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Test-only spy: records the LAST request it was asked to send (headers included) and answers
/// with a canned, empty 200. Used to prove `AuthenticatedClientTransport` injects (or omits)
/// the `Authorization` header without needing a real network call or a real generated
/// operation — the header is a transport-level concern, beneath the generated `Client`.
actor SpyClientTransport: ClientTransport {
  private(set) var lastRequest: HTTPRequest?
  private(set) var callCount = 0

  func send(
    _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
  ) async throws -> (HTTPResponse, HTTPBody?) {
    callCount += 1
    lastRequest = request
    return (HTTPResponse(status: .ok), nil)
  }
}
